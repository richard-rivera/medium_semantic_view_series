# Semantic views series: sample data and code

Companion repo for the "Semantic Views" article series on Medium. The data is synthetic.
Every number quoted in the articles comes from it, so you can reproduce them in a Snowflake
trial account.

## Layout

| Path | Purpose |
| --- | --- |
| `data/*.csv` | Bronze tables as CSVs: `accounts`, `products`, `subscriptions`, plus `dim_month`. Same data as `load_bronze.sql`. |
| `load_bronze.sql` | Paste-and-run script that creates the `sv_series` database and loads the data. Run this first. |
| `part1/part1.sql` | Part 1: the naive view, the curated fact table, the certified view, and PASS/FAIL checks. |

More part folders get added as the series publishes. Each one lists what it needs at the top
and ends with checks that print PASS or FAIL.

## Bronze data is frozen

The CSVs in `data/` are the source of every number in the articles. They don't change.
Later parts add new tables. They never modify existing ones.

## The four quirks, planted on purpose

1. **Two billing systems.** Subscriptions that started before 2023 came from `legacy_billing`,
   which stored the full annual amount in one row. Everything after is `new_billing`, monthly.
2. **Parent and child accounts.** Each enterprise customer is a parent with 2 to 3 child accounts.
   Subscriptions attach to the children. Some children are tagged `Mid-Market`.
3. **Internal and reseller accounts.** Four accounts with `account_type` of `internal` or `reseller`.
   Finance excludes them from MRR.
4. **Grain.** Subscriptions run for many months. Summing MRR across months is meaningless.

## MRR for September 2026, naive vs. certified

| Segment | Naive MRR | Certified MRR | Paying accounts |
| --- | ---: | ---: | ---: |
| Enterprise | 638,484 | 144,267 | 8 |
| Mid-Market | 166,432 | 27,344 | 10 |
| SMB | 6,362 | 1,874 | 13 |

Naive = `SUM(amount)` over active subscriptions, grouped by the segment of the account the
subscription is attached to, nothing excluded. Certified = legacy rows divided by 12, rolled up
to the parent account, internal and reseller excluded.

Summing the naive number across July, August, and September gives 2,434,382. That number
means nothing.

## Running it in Snowflake

1. Paste `load_bronze.sql` into a Snowsight worksheet and run it.
2. Paste `part1/part1.sql` and run it. The last two queries should print PASS on every row.
