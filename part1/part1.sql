-- Part 1: Semantic Views Don't Fix Bad Modeling. They Hide It.
-- Run load_bronze.sql first. Then run this file top to bottom.
-- The last two queries print PASS or FAIL for every number quoted in the article.

USE DATABASE sv_series;

-- 1. The naive view, straight over bronze -------------------------------------
CREATE OR REPLACE SEMANTIC VIEW semantic.sales_naive
  TABLES (
    subscriptions AS bronze.subscriptions PRIMARY KEY (subscription_id),
    accounts      AS bronze.accounts      PRIMARY KEY (account_id)
  )
  RELATIONSHIPS (
    sub_to_account AS subscriptions(account_id) REFERENCES accounts(account_id)
  )
  DIMENSIONS (
    accounts.account_name    AS account_name,
    accounts.segment         AS segment,
    subscriptions.start_month AS start_month,
    subscriptions.end_month   AS end_month
  )
  METRICS (
    subscriptions.mrr AS SUM(subscriptions.amount)
      COMMENT = 'Monthly recurring revenue'
  );

-- 2. The curated fact table -----------------------------------------------------
CREATE OR REPLACE TABLE silver.fct_mrr_monthly AS
SELECT
  d.month_start,
  COALESCE(a.parent_account_id, a.account_id) AS reporting_account_id,
  -- normalize legacy annual rows to monthly
  SUM(CASE WHEN s.source_system = 'legacy_billing'
           THEN s.amount / 12
           ELSE s.amount END)                  AS mrr
FROM bronze.subscriptions s
JOIN bronze.accounts a  ON a.account_id = s.account_id
-- end_month is the last billed month, so the range is inclusive
JOIN silver.dim_month d ON d.month_start BETWEEN s.start_month AND COALESCE(s.end_month, '9999-12-31')
WHERE a.account_type NOT IN ('internal', 'reseller')
GROUP BY 1, 2;

-- 3. The certified view ---------------------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW semantic.sales_finance
  TABLES (
    mrr_month AS silver.fct_mrr_monthly PRIMARY KEY (month_start, reporting_account_id),
    accounts  AS bronze.accounts        PRIMARY KEY (account_id)
  )
  RELATIONSHIPS (
    mrr_to_account AS mrr_month(reporting_account_id) REFERENCES accounts(account_id)
  )
  FACTS (
    mrr_month.mrr_amount AS mrr
  )
  DIMENSIONS (
    mrr_month.month  AS month_start,
    accounts.name    AS account_name,
    accounts.segment AS segment
  )
  METRICS (
    mrr_month.total_mrr
      NON ADDITIVE BY (month)
      AS SUM(mrr_month.mrr_amount)
      WITH SYNONYMS = ('mrr', 'monthly recurring revenue', 'recurring revenue')
      COMMENT = 'Finance-certified MRR at the parent account level. Excludes internal and reseller accounts. Legacy annual contracts normalized to monthly. Do not sum across months.',
    mrr_month.paying_accounts AS COUNT(DISTINCT mrr_month.reporting_account_id)
      COMMENT = 'External parent accounts with MRR in the month. Filter to one month.'
  )
  AI_SQL_GENERATION 'MRR is a point-in-time balance. When a user asks for MRR over a period, return the value for the last month in the period, never a sum across months.';

-- 4. Check: naive vs. certified, September 2026 ----------------------------------
WITH naive AS (
  SELECT * FROM SEMANTIC_VIEW(
    semantic.sales_naive
    DIMENSIONS accounts.segment
    METRICS subscriptions.mrr
    WHERE subscriptions.start_month <= '2026-09-01'
      AND COALESCE(subscriptions.end_month, '9999-12-31') >= '2026-09-01'
  )
),
cert AS (
  SELECT * FROM SEMANTIC_VIEW(
    semantic.sales_finance
    DIMENSIONS accounts.segment
    METRICS mrr_month.total_mrr, mrr_month.paying_accounts
    WHERE mrr_month.month = '2026-09-01'
  )
),
expected AS (
  SELECT * FROM VALUES
    ('Enterprise', 638484, 144267,  8),
    ('Mid-Market', 166432,  27344, 10),
    ('SMB',          6362,   1874, 13)
  AS v(segment, naive_mrr, certified_mrr, paying_accounts)
)
SELECT e.segment,
       n.mrr             AS naive_mrr,
       c.total_mrr       AS certified_mrr,
       c.paying_accounts,
       IFF(ROUND(n.mrr) = e.naive_mrr
           AND ROUND(c.total_mrr) = e.certified_mrr
           AND c.paying_accounts = e.paying_accounts, 'PASS', 'FAIL') AS check_result
FROM expected e
LEFT JOIN naive n ON n.segment = e.segment
LEFT JOIN cert  c ON c.segment = e.segment
ORDER BY e.segment;

-- 5. Check: the grain mistake (naive MRR added up across Q3 2026) -----------------
SELECT SUM(s.amount) AS naive_q3_sum,
       IFF(SUM(s.amount) = 2434382, 'PASS', 'FAIL') AS check_result
FROM bronze.subscriptions s
JOIN silver.dim_month d
  ON d.month_start BETWEEN s.start_month AND COALESCE(s.end_month, '9999-12-31')
WHERE d.month_start BETWEEN '2026-07-01' AND '2026-09-01';
