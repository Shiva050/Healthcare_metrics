-- Stored procedure: full rebuild of gold.dim_provider (monthly snapshot)
-- from silver.nh_provider_info.
--
-- Strategy: TRUNCATE + INSERT, not incremental — same idempotency
-- philosophy as the other two gold refresh procs. A plain reshape, not an
-- aggregation: silver.nh_provider_info is already at (provnum,
-- snapshot_date_key) grain, so this just carries the descriptive columns
-- across and derives month_key = snapshot_date_key / 100. No dedup guard
-- needed here (unlike gold.sp_refresh_gold_fact_provider_quality_metrics'
-- comment on the same point): silver's own load proc already enforces
-- exactly one row per (provnum, snapshot_date_key) before it ever lands in
-- silver.nh_provider_info.
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_dim_provider()
LANGUAGE plpgsql
AS $$
BEGIN

    TRUNCATE TABLE gold.dim_provider;

    INSERT INTO gold.dim_provider (
        provider_key, provnum, month_key,
        provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds,
        _refreshed_at
    )
    SELECT
        FNV_HASH(provnum || '_' || (snapshot_date_key / 100)::VARCHAR)  AS provider_key,
        provnum,
        snapshot_date_key / 100                                          AS month_key,
        provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds,
        SYSDATE
    FROM silver.nh_provider_info
    WHERE provnum IS NOT NULL AND snapshot_date_key IS NOT NULL;

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
