-- Part 2: Semantic Views Belong Between Silver and Gold
-- Needs: load_bronze.sql. Doesn't need Part 1.
-- Run top to bottom. The last two queries print PASS or FAIL.

USE DATABASE sv_series;

-- 1. Silver: dimensions ------------------------------------------------------------
CREATE OR REPLACE TABLE silver.dim_account AS
SELECT account_id, account_name, segment, region, account_type, parent_account_id
FROM bronze.accounts;

CREATE OR REPLACE TABLE silver.dim_product AS
SELECT product_id, product_name
FROM bronze.products;

-- 2. Silver: the fact, with business rules applied -------------------------------------
CREATE OR REPLACE TABLE silver.fct_subscription_month AS
SELECT
  d.month_start,
  COALESCE(a.parent_account_id, a.account_id) AS reporting_account_id,
  s.product_id,
  SUM(CASE WHEN s.source_system = 'legacy_billing'
           THEN s.amount / 12 ELSE s.amount END) AS mrr,
  COUNT(DISTINCT s.subscription_id)             AS active_subscriptions
FROM bronze.subscriptions s
JOIN bronze.accounts a ON a.account_id = s.account_id
-- end_month is the last billed month, so the range is inclusive
JOIN silver.dim_month d
  ON d.month_start BETWEEN s.start_month AND COALESCE(s.end_month, '9999-12-31')
WHERE a.account_type NOT IN ('internal', 'reseller')
GROUP BY 1, 2, 3;

-- 3. Semantic view: the revenue topic area -------------------------------------------
CREATE OR REPLACE SEMANTIC VIEW semantic.sv_revenue
  TABLES (
    sub_month AS silver.fct_subscription_month
      PRIMARY KEY (month_start, reporting_account_id, product_id),
    accounts  AS silver.dim_account PRIMARY KEY (account_id),
    products  AS silver.dim_product PRIMARY KEY (product_id)
  )
  RELATIONSHIPS (
    to_account AS sub_month(reporting_account_id) REFERENCES accounts(account_id),
    to_product AS sub_month(product_id)           REFERENCES products(product_id)
  )
  FACTS (
    sub_month.mrr_amount AS mrr
  )
  DIMENSIONS (
    sub_month.month     AS month_start,
    accounts.name       AS account_name,
    accounts.segment    AS segment,
    accounts.region     AS region,
    products.name       AS product_name
  )
  METRICS (
    sub_month.total_mrr
      NON ADDITIVE BY (month)
      AS SUM(sub_month.mrr_amount)
      WITH SYNONYMS = ('mrr', 'monthly recurring revenue', 'recurring revenue')
      COMMENT = 'Finance-certified MRR. Point-in-time balance; do not sum across months.',
    sub_month.total_arr
      NON ADDITIVE BY (month)
      AS SUM(sub_month.mrr_amount) * 12
      WITH SYNONYMS = ('arr', 'annual recurring revenue')
      COMMENT = 'Annualized MRR.',
    sub_month.active_accounts AS COUNT(DISTINCT sub_month.reporting_account_id)
      COMMENT = 'Paying external accounts with at least one active subscription.'
  )
  COMMENT = 'Revenue topic area. Owner: Finance Data. Use for MRR, ARR, and account counts.';

-- 4. Gold: built from the semantic view, not from silver ---------------------------------
CREATE OR REPLACE TABLE gold.finance_mrr_by_segment AS
SELECT *
FROM SEMANTIC_VIEW(
  semantic.sv_revenue
  DIMENSIONS sub_month.month, accounts.segment, accounts.region
  METRICS    sub_month.total_mrr, sub_month.total_arr, sub_month.active_accounts
);

-- 5. Check: sv_revenue matches the certified numbers from Part 1, September 2026 ----------
WITH sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    semantic.sv_revenue
    DIMENSIONS accounts.segment
    METRICS sub_month.total_mrr, sub_month.total_arr, sub_month.active_accounts
    WHERE sub_month.month = '2026-09-01'
  )
),
expected AS (
  SELECT * FROM VALUES
    ('Enterprise', 144267,  8),
    ('Mid-Market',  27344, 10),
    ('SMB',          1874, 13)
  AS v(segment, mrr, accts)
)
SELECT e.segment, sv.total_mrr, sv.total_arr, sv.active_accounts,
       IFF(ROUND(sv.total_mrr) = e.mrr
           AND ROUND(sv.total_arr) = e.mrr * 12
           AND sv.active_accounts = e.accts, 'PASS', 'FAIL') AS check_result
FROM expected e
LEFT JOIN sv ON sv.segment = e.segment
ORDER BY e.segment;

-- 6. Check: gold agrees with the semantic view, September 2026 ---------------------------
-- Each parent account sits in one region, so region rows add up to the segment total.
WITH g AS (
  SELECT segment,
         SUM(total_mrr)       AS total_mrr,
         SUM(active_accounts) AS active_accounts
  FROM gold.finance_mrr_by_segment
  WHERE month = '2026-09-01'
  GROUP BY segment
),
sv AS (
  SELECT * FROM SEMANTIC_VIEW(
    semantic.sv_revenue
    DIMENSIONS accounts.segment
    METRICS sub_month.total_mrr, sub_month.active_accounts
    WHERE sub_month.month = '2026-09-01'
  )
)
SELECT sv.segment, sv.total_mrr AS sv_mrr, g.total_mrr AS gold_mrr,
       IFF(ROUND(g.total_mrr) = ROUND(sv.total_mrr)
           AND g.active_accounts = sv.active_accounts, 'PASS', 'FAIL') AS check_result
FROM sv
LEFT JOIN g ON g.segment = sv.segment
ORDER BY sv.segment;
