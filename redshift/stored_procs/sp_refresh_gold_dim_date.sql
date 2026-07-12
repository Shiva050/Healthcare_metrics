-- Stored procedure: full rebuild of gold.dim_date over [p_start_date, p_end_date].
--
-- p_start_date / p_end_date have no defaults: Redshift's CREATE PROCEDURE
-- doesn't support DEFAULT values on parameters at all (same constraint
-- already documented in sp_copy_pbj_staffing.sql) — callers must pass both
-- explicitly, e.g. CALL gold.sp_refresh_gold_dim_date('2015-01-01','2035-12-31').
--
-- Date-spine generation: a cross join of five 0-9 "digit" inline views
-- produces every integer 0-99999, which added to p_start_date as days
-- covers a ~273-year range — deliberately not GENERATE_SERIES or a
-- recursive CTE. Both exist in modern Postgres and newer Redshift releases,
-- but this codebase has repeatedly hit Redshift version-specific gaps the
-- hard way elsewhere (see sp_copy_pbj_staffing's COPY-parameter-binding
-- comment) and a plain FROM-clause cross join of literal values is
-- unambiguous SQL-92, guaranteed to work on any Redshift version without
-- needing to check feature availability first.
--
-- day_of_week uses Redshift's EXTRACT(DOW ...) convention (0=Sunday..
-- 6=Saturday) — matching the same convention already used for the weekend
-- HPRD split in sp_refresh_gold_fact_monthly_staffing_metrics, so "is
-- Sat/Sun" logic stays consistent across the gold layer.
--
-- TO_CHAR's 'Day'/'Month' format codes pad their output to a fixed width
-- unless prefixed with 'FM' (fill mode) — using 'FMDay'/'FMMonth' here to
-- avoid trailing blanks in day_name/month_name.
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_dim_date(
    p_start_date DATE,
    p_end_date   DATE
)
LANGUAGE plpgsql
AS $$
BEGIN

    CREATE TEMP TABLE IF NOT EXISTS tmp_dim_date_spine (full_date DATE);
    DELETE FROM tmp_dim_date_spine;

    INSERT INTO tmp_dim_date_spine
    SELECT (p_start_date + (d4.d*10000 + d3.d*1000 + d2.d*100 + d1.d*10 + d0.d))::DATE AS full_date
    FROM (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d0,
         (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1,
         (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2,
         (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3,
         (SELECT 0 AS d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
          UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4
    WHERE (p_start_date + (d4.d*10000 + d3.d*1000 + d2.d*100 + d1.d*10 + d0.d)) <= p_end_date;

    TRUNCATE TABLE gold.dim_date;

    INSERT INTO gold.dim_date (
        date_key, full_date, month_key,
        day_of_month, day_of_week, day_name, is_weekend, week_of_year,
        month_number, month_name, quarter, quarter_name, year, is_leap_year,
        _refreshed_at
    )
    SELECT
        CAST(TO_CHAR(full_date, 'YYYYMMDD') AS INTEGER)                          AS date_key,
        full_date,
        CAST(TO_CHAR(full_date, 'YYYYMM')   AS INTEGER)                          AS month_key,
        EXTRACT(DAY   FROM full_date)::SMALLINT                                  AS day_of_month,
        EXTRACT(DOW   FROM full_date)::SMALLINT                                  AS day_of_week,
        TRIM(TO_CHAR(full_date, 'FMDay'))                                        AS day_name,
        EXTRACT(DOW FROM full_date) IN (0, 6)                                    AS is_weekend,
        EXTRACT(WEEK  FROM full_date)::SMALLINT                                  AS week_of_year,
        EXTRACT(MONTH FROM full_date)::SMALLINT                                  AS month_number,
        TRIM(TO_CHAR(full_date, 'FMMonth'))                                      AS month_name,
        EXTRACT(QUARTER FROM full_date)::SMALLINT                                AS quarter,
        'Q' || EXTRACT(QUARTER FROM full_date)::VARCHAR                         AS quarter_name,
        EXTRACT(YEAR FROM full_date)::SMALLINT                                   AS year,
        (   EXTRACT(YEAR FROM full_date)::INT % 400 = 0
         OR (EXTRACT(YEAR FROM full_date)::INT % 4 = 0 AND EXTRACT(YEAR FROM full_date)::INT % 100 <> 0)
        )                                                                        AS is_leap_year,
        SYSDATE
    FROM tmp_dim_date_spine;

    DROP TABLE tmp_dim_date_spine;

EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%invalid%'
       OR SQLERRM ILIKE '%out of range%'
       OR SQLERRM ILIKE '%type mismatch%'
       OR SQLERRM ILIKE '%conversion%'
       OR SQLERRM ILIKE '%constraint%'
       OR SQLERRM ILIKE '%violat%'
       OR SQLERRM ILIKE '%numeric%' THEN
        RAISE EXCEPTION 'DATA_ERROR | %', SQLERRM;
    ELSE
        -- Bare RAISE (re-raise as-is) needs NONATOMIC mode in Redshift;
        -- this procedure runs atomic, so re-raise explicitly instead.
        RAISE EXCEPTION '%', SQLERRM;
    END IF;
END;
$$;
