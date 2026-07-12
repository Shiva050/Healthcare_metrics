-- Stored procedure: full rebuild of gold.fact_monthly_staffing_metrics from
-- daily silver.pbj_daily_nurse_staffing.
--
-- Strategy: TRUNCATE + INSERT, not incremental — same reasoning as
-- sp_refresh_gold_dim_provider: silver is small enough that a full rebuild
-- every run is simpler than tracking which months changed, and it's
-- trivially idempotent.
--
-- month_key : INTEGER YYYYMM01, derived from workdate (INTEGER YYYYMMDD) as
--             (workdate / 100) * 100 + 1 — integer division truncates the
--             day, so e.g. 20240615 -> 202406 -> 20240601.
--
-- Two intermediate temp tables because the weekend HPRD figure needs a
-- differently-filtered aggregation (Sat/Sun rows only) than every other
-- column in this table (all rows) — computing both in one GROUP BY would
-- need a FILTER/CASE inside every aggregate, which is harder to read than
-- just aggregating twice and joining. Same temp-table-staging style already
-- used in sp_merge_pbj_staffing / sp_load_nh_provider_info.
--
-- HPRD scope: direct-care hours only (hrs_rn/hrs_lpn/hrs_cna), excluding
-- admin/director hours (hrs_rndon/hrs_rnadmin/hrs_lpnadmin) — see
-- 06_gold_fact_monthly_staffing_metrics.sql for why (matches what CMS's own
-- reported_*_hprd figures cover). NULLIF guards every HPRD division since a
-- month with zero reported resident-days would otherwise error rather than
-- just yielding NULL.
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_fact_monthly_staffing_metrics()
LANGUAGE plpgsql
AS $$
BEGIN

    CREATE TEMP TABLE IF NOT EXISTS tmp_gold_monthly_agg (
        provnum                VARCHAR(20),
        month_key               INTEGER,
        avg_daily_census         DECIMAL(7,2),
        total_resident_days      INTEGER,
        days_reported            SMALLINT,
        rn_hours                 DECIMAL(9,2),
        lpn_hours                DECIMAL(9,2),
        cna_hours                DECIMAL(9,2),
        admin_director_hours     DECIMAL(9,2),
        contract_nurse_hours     DECIMAL(9,2)
    );
    DELETE FROM tmp_gold_monthly_agg;

    INSERT INTO tmp_gold_monthly_agg
    SELECT
        provnum,
        (workdate / 100) * 100 + 1                                   AS month_key,
        AVG(mdscensus)                                                AS avg_daily_census,
        SUM(mdscensus)                                                AS total_resident_days,
        COUNT(DISTINCT workdate)                                      AS days_reported,
        SUM(hrs_rn)                                                   AS rn_hours,
        SUM(hrs_lpn)                                                  AS lpn_hours,
        SUM(hrs_cna)                                                  AS cna_hours,
        SUM(hrs_rndon) + SUM(hrs_rnadmin) + SUM(hrs_lpnadmin)         AS admin_director_hours,
        SUM(hrs_rn_ctr) + SUM(hrs_lpn_ctr) + SUM(hrs_cna_ctr)         AS contract_nurse_hours
    FROM silver.pbj_daily_nurse_staffing
    WHERE provnum IS NOT NULL AND workdate IS NOT NULL
    GROUP BY provnum, (workdate / 100) * 100 + 1;

    CREATE TEMP TABLE IF NOT EXISTS tmp_gold_weekend_agg (
        provnum                VARCHAR(20),
        month_key               INTEGER,
        weekend_nurse_hours      DECIMAL(9,2),
        weekend_resident_days    INTEGER
    );
    DELETE FROM tmp_gold_weekend_agg;

    INSERT INTO tmp_gold_weekend_agg
    SELECT
        provnum,
        (workdate / 100) * 100 + 1                                   AS month_key,
        SUM(hrs_rn) + SUM(hrs_lpn) + SUM(hrs_cna)                     AS weekend_nurse_hours,
        SUM(mdscensus)                                                AS weekend_resident_days
    FROM silver.pbj_daily_nurse_staffing
    WHERE provnum IS NOT NULL
      AND workdate IS NOT NULL
      AND DATE_PART(dow, TO_DATE(workdate::VARCHAR, 'YYYYMMDD')) IN (0, 6)  -- Sun=0, Sat=6
    GROUP BY provnum, (workdate / 100) * 100 + 1;

    TRUNCATE TABLE gold.fact_monthly_staffing_metrics;

    INSERT INTO gold.fact_monthly_staffing_metrics (
        provnum, month_key, avg_daily_census, total_resident_days, days_reported,
        rn_hours, lpn_hours, cna_hours, total_nurse_hours, admin_director_hours,
        rn_hprd, lpn_hprd, cna_hprd, total_nurse_hprd, weekend_total_nurse_hprd,
        contract_hours_pct, _refreshed_at
    )
    SELECT
        m.provnum,
        m.month_key,
        m.avg_daily_census,
        m.total_resident_days,
        m.days_reported,
        m.rn_hours,
        m.lpn_hours,
        m.cna_hours,
        m.rn_hours + m.lpn_hours + m.cna_hours                                          AS total_nurse_hours,
        m.admin_director_hours,
        m.rn_hours  / NULLIF(m.total_resident_days, 0)                                  AS rn_hprd,
        m.lpn_hours / NULLIF(m.total_resident_days, 0)                                  AS lpn_hprd,
        m.cna_hours / NULLIF(m.total_resident_days, 0)                                  AS cna_hprd,
        (m.rn_hours + m.lpn_hours + m.cna_hours) / NULLIF(m.total_resident_days, 0)      AS total_nurse_hprd,
        w.weekend_nurse_hours / NULLIF(w.weekend_resident_days, 0)                       AS weekend_total_nurse_hprd,
        100.0 * m.contract_nurse_hours / NULLIF(m.rn_hours + m.lpn_hours + m.cna_hours, 0) AS contract_hours_pct,
        SYSDATE
    FROM tmp_gold_monthly_agg m
    LEFT JOIN tmp_gold_weekend_agg w
           ON w.provnum = m.provnum
          AND w.month_key = m.month_key;

    DROP TABLE tmp_gold_monthly_agg;
    DROP TABLE tmp_gold_weekend_agg;

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
