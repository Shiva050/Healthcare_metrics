/* ----------------------------------------------------------------------------
   SECTION 0 — INVENTORY: what did I actually load?
   Run these ONCE to get the lay of the land across all 20 tables.
   ---------------------------------------------------------------------------- */
 
-- 0a. Every table with its row count and size (spot empty or oversized loads)
SELECT table_name, row_count
FROM INFORMATION_SCHEMA.TABLES
WHERE table_schema = 'PUBLIC'
ORDER BY row_count DESC;
 
-- 0b. Every column across every table (starting data dictionary)
SELECT table_name, ordinal_position, column_name, data_type, is_nullable
FROM INFORMATION_SCHEMA.COLUMNS
WHERE table_schema = 'PUBLIC'
ORDER BY table_name, ordinal_position;

// Eye ball the master table
SELECT TOP 100 * FROM PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024

/* ----------------------------------------------------------------------------
   SECTION 2 — COLUMN PROFILE (the workhorse)
   Nulls, fill rate, and cardinality for a single column.
   ---------------------------------------------------------------------------- */
SELECT
    COUNT(*)                                                    AS total_rows,
    COUNT(PROVNUM)                                                AS non_null,
    COUNT(*) - COUNT(PROVNUM)                                     AS nulls,
    ROUND(100.0 * (COUNT(*) - COUNT(PROVNUM)) / COUNT(*), 2)      AS null_pct,
    COUNT(DISTINCT PROVNUM)                                       AS distinct_vals,
    ROUND(100.0 * COUNT(DISTINCT PROVNUM) / COUNT(*), 2)          AS distinct_pct
FROM PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024
-- Reading it: null_pct high = missing data problem.
-- distinct_pct ~100% = likely an ID/key.  distinct_vals low = categorical.

/* ----------------------------------------------------------------------------
   SECTION 6 — DUPLICATES
   ---------------------------------------------------------------------------- */
 
-- 6a. Fully-duplicated rows (HASH(*) fingerprints the whole row)
SELECT COUNT(*) - COUNT(DISTINCT HASH(*)) AS full_dup_rows FROM PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024
 
-- 6b. Duplicates on a supposed key/business-key
SELECT PROVNUM, COUNT(*) AS cnt
FROM PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024
GROUP BY PROVNUM
HAVING COUNT(*) > 1
ORDER BY cnt DESC

/* ----------------------------------------------------------------------------
   SECTION 7 — IDENTIFYING THE GRAIN
   ---------------------------------------------------------------------------- */

--7a. Since the count for every PROVNUM is 91, assuming its spanned across all dates. Checking how many dates we have
SELECT DATEDIFF('day', MIN(TO_DATE(WORKDATE::VARCHAR, 'YYYYMMDD')), MAX(TO_DATE(WORKDATE::VARCHAR, 'YYYYMMDD')))
FROM
PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024

--7b. Checking the duplicates across PROVNUM and WORKDATE
SELECT PROVNUM,WORKDATE,COUNT(*)
FROM PUBLIC.PBJ_DAILY_NURSE_STAFFING_Q2_2024
GROUP BY PROVNUM,WORKDATE HAVING COUNT(*) > 1
-- Got 0 results confirms the grain -> PROVNUM + WORKDATE

