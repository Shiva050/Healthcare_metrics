-- Stored procedure: full rebuild of gold.fact_provider_quality_metrics from
-- silver.nh_provider_info.
--
-- Strategy: TRUNCATE + INSERT, not incremental — same reasoning as the other
-- two gold refresh procs.
--
-- No dedup guard here (unlike the silver load proc it reads from): silver's
-- own sp_load_nh_provider_info already enforces exactly one row per
-- (provnum, snapshot_date_key) before it ever lands in
-- silver.nh_provider_info, so this proc can trust that grain rather than
-- re-guarding against something silver has already ruled out.
--
-- This is a reshape, not an aggregation — silver.nh_provider_info is already
-- at (provnum, snapshot_date_key) grain — aside from total_deficiencies_3yr,
-- which sums the three health-survey cycles' total_health_deficiencies into
-- one reporting-friendly figure.
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_fact_provider_quality_metrics()
LANGUAGE plpgsql
AS $$
BEGIN

    TRUNCATE TABLE gold.fact_provider_quality_metrics;

    INSERT INTO gold.fact_provider_quality_metrics (
        provnum, snapshot_date_key,
        overall_rating, health_inspection_rating, qm_rating,
        longstay_qm_rating, shortstay_qm_rating, staffing_rating,
        total_nurse_turnover_pct, rn_turnover_pct, administrators_left_count,
        total_deficiencies_3yr, facility_reported_incidents,
        substantiated_complaints, infection_control_citations,
        num_fines, total_fines_amount, payment_denials, total_penalties,
        certified_beds, avg_residents_per_day, ownership_type,
        special_focus_status, abuse_icon, _refreshed_at
    )
    SELECT
        provnum, snapshot_date_key,
        overall_rating, health_inspection_rating, qm_rating,
        longstay_qm_rating, shortstay_qm_rating, staffing_rating,
        total_nurse_turnover_pct, rn_turnover_pct, administrators_left_count,
        COALESCE(cycle1_total_health_deficiencies, 0)
            + COALESCE(cycle2_total_health_deficiencies, 0)
            + COALESCE(cycle3_total_health_deficiencies, 0)          AS total_deficiencies_3yr,
        facility_reported_incidents,
        substantiated_complaints, infection_control_citations,
        num_fines, total_fines_amount, payment_denials, total_penalties,
        certified_beds, avg_residents_per_day, ownership_type,
        special_focus_status, abuse_icon, SYSDATE
    FROM silver.nh_provider_info;

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
