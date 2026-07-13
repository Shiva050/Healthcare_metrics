-- Stored procedure: full rebuild of gold.fact_daily_staffing_metrics from
-- silver.pbj_daily_nurse_staffing.
--
-- Strategy: TRUNCATE + INSERT, not incremental — same idempotency philosophy
-- as the other gold refresh procs. A day-grain projection, not an
-- aggregation: silver.pbj_daily_nurse_staffing is already one row per
-- (provnum, workdate), so this carries each day's row across with the two
-- direct-care-hour totals summed row-wise and the dimension key looked up.
--
-- date_key   : silver's workdate as-is (INTEGER YYYYMMDD), a 1:1 FK to
--              gold.dim_date.date_key.
-- month_key  : workdate / 100 (INTEGER YYYYMM) — integer division drops the
--              day, e.g. 20240615 -> 202406. Used for the dim_provider join
--              and cross-fact joins.
--
-- provider_key : looked up from gold.dim_provider via a LEFT JOIN on
--                (provnum, month_key), then COALESCEd to -1. LEFT (not INNER)
--                so a day whose provider has no NH snapshot for that month
--                (no dim_provider row) still lands here; the COALESCE points
--                those misses at the -1 "Unknown" member gold.dim_provider
--                seeds (see sp_refresh_gold_dim_provider), so they aggregate
--                into an explicit Unknown bucket rather than a NULL key.
--                dim_provider is one row per (provnum, month_key), so the join
--                matches at most one dim row per staffing day — no fan-out.
--
-- total_direct_care_hours / contract_direct_care_hours: RN/LPN/CNA only
-- (admin/director excluded). Each component is COALESCEd to 0 so a NULL in
-- one role doesn't null the whole day's total. No ratios computed here —
-- HPRD and contract-mix are left to the BI layer.
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_fact_daily_staffing_metrics()
LANGUAGE plpgsql
AS $$
BEGIN

    TRUNCATE TABLE gold.fact_daily_staffing_metrics;

    INSERT INTO gold.fact_daily_staffing_metrics (
        provider_key, provnum, date_key, month_key,
        mdscensus, total_direct_care_hours, contract_direct_care_hours,
        _refreshed_at
    )
    SELECT
        COALESCE(d.provider_key, -1)                                                  AS provider_key,
        s.provnum,
        s.workdate                                                                    AS date_key,
        s.workdate / 100                                                              AS month_key,
        s.mdscensus,
        COALESCE(s.hrs_rn, 0)     + COALESCE(s.hrs_lpn, 0)     + COALESCE(s.hrs_cna, 0)      AS total_direct_care_hours,
        COALESCE(s.hrs_rn_ctr, 0) + COALESCE(s.hrs_lpn_ctr, 0) + COALESCE(s.hrs_cna_ctr, 0)  AS contract_direct_care_hours,
        SYSDATE
    FROM silver.pbj_daily_nurse_staffing s
    LEFT JOIN gold.dim_provider d
           ON d.provnum   = s.provnum
          AND d.month_key = s.workdate / 100
    WHERE s.provnum IS NOT NULL AND s.workdate IS NOT NULL;

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
