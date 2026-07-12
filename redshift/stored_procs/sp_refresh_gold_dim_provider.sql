-- Stored procedure: full rebuild of gold.dim_provider from silver.nh_provider_info.
--
-- Strategy: TRUNCATE + INSERT, not incremental — same idempotency philosophy
-- already used for silver.nh_provider_info's own delete-then-insert: silver
-- is small enough (thousands of providers) that a full rebuild every run is
-- simpler and safer than tracking what changed, and a rerun after a failure
-- just reproduces the same result.
--
-- One row per provnum: the most recent snapshot_date_key only, since this is
-- a "current state" dimension (name/address/ownership/bed count), not a
-- history table — rating/turnover/deficiency history lives in
-- gold.fact_provider_quality_metrics instead.
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
        provnum, provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds,
        date_first_approved, resides_in_hospital, ccrc_status,
        latitude, longitude, _source_snapshot_date_key, _refreshed_at
    )
    SELECT
        provnum, provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds,
        date_first_approved, resides_in_hospital, ccrc_status,
        latitude, longitude, snapshot_date_key, SYSDATE
    FROM (
        SELECT s.*,
               ROW_NUMBER() OVER (
                   PARTITION BY provnum
                   ORDER BY snapshot_date_key DESC
               ) AS rn
        FROM silver.nh_provider_info s
    ) s
    WHERE rn = 1;

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
