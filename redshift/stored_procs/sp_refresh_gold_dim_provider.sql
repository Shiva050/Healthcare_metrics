-- Stored procedure: full rebuild of gold.dim_provider (monthly snapshot with
-- SCD Type 2 version metadata) from silver.nh_provider_info.
--
-- Strategy: TRUNCATE + INSERT, not incremental — and unlike a typical SCD2
-- (which needs incremental "what changed since last run" state), this can
-- still be a full rebuild every time: silver.nh_provider_info's own load
-- proc only ever deletes+inserts the *current* month, so silver already
-- holds every month's history forever. That means effective_from/
-- effective_to/is_current can be recomputed from scratch on every run. See
-- 05_gold_dim_provider.sql for the full grain/column contract.
--
-- Build:
--   1. tmp_dim_flagged — one row per silver row, with month_key derived and
--      a `changed` flag (1 if any tracked attribute differs from the prior
--      month for that provnum, via IS DISTINCT FROM so NULLs compare
--      correctly; always 1 for a provider's first-ever row since LAG is
--      NULL there), then a running SUM(changed) OVER (... ROWS UNBOUNDED
--      PRECEDING) turning those flags into a version_group id — classic
--      "gaps and islands": every time changed=1, the running sum
--      increments, so all the unchanged months that follow share the same
--      group id as the row that started that run.
--   2. Final insert reads tmp_dim_flagged directly, one row per month
--      (grain is unchanged — no collapsing GROUP BY). Per row:
--        effective_from = MIN(month_key) OVER (PARTITION BY provnum, version_group)
--        effective_to   = NULL if version_group is this provnum's latest
--                          (MAX(version_group) OVER (PARTITION BY provnum)),
--                          else MAX(month_key) OVER (PARTITION BY provnum, version_group)
--        is_current     = version_group equals that same provnum-level max
--
-- Error classification (for the gold state machine's DLQ routing), same
-- convention as the silver merge/load procs:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; state machine retries

CREATE OR REPLACE PROCEDURE gold.sp_refresh_gold_dim_provider()
LANGUAGE plpgsql
AS $$
BEGIN

    CREATE TEMP TABLE IF NOT EXISTS tmp_dim_flagged (
        provnum                VARCHAR(20),
        snapshot_date_key       INTEGER,
        month_key               INTEGER,
        provider_name           VARCHAR(255),
        provider_address        VARCHAR(255),
        city                    VARCHAR(100),
        state                   VARCHAR(2),
        zip_code                INTEGER,
        county_name             VARCHAR(100),
        ownership_type          VARCHAR(100),
        provider_type           VARCHAR(100),
        certified_beds          SMALLINT,
        changed                 SMALLINT,
        version_group           BIGINT
    );
    DELETE FROM tmp_dim_flagged;

    INSERT INTO tmp_dim_flagged
    SELECT
        y.*,
        SUM(y.changed) OVER (
            PARTITION BY y.provnum ORDER BY y.snapshot_date_key
            ROWS UNBOUNDED PRECEDING
        )                                                    AS version_group
    FROM (
        SELECT
            x.provnum, x.snapshot_date_key, x.month_key,
            x.provider_name, x.provider_address, x.city, x.state, x.zip_code,
            x.county_name, x.ownership_type, x.provider_type, x.certified_beds,
            CASE WHEN
                   x.provider_name    IS DISTINCT FROM LAG(x.provider_name)    OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.provider_address IS DISTINCT FROM LAG(x.provider_address) OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.city             IS DISTINCT FROM LAG(x.city)             OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.state            IS DISTINCT FROM LAG(x.state)            OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.zip_code         IS DISTINCT FROM LAG(x.zip_code)         OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.county_name      IS DISTINCT FROM LAG(x.county_name)      OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.ownership_type   IS DISTINCT FROM LAG(x.ownership_type)   OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.provider_type    IS DISTINCT FROM LAG(x.provider_type)    OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                OR x.certified_beds   IS DISTINCT FROM LAG(x.certified_beds)   OVER (PARTITION BY x.provnum ORDER BY x.snapshot_date_key)
                 THEN 1 ELSE 0
            END                                                AS changed
        FROM (
            SELECT
                provnum, snapshot_date_key, snapshot_date_key / 100 AS month_key,
                provider_name, provider_address, city, state, zip_code,
                county_name, ownership_type, provider_type, certified_beds
            FROM silver.nh_provider_info
            WHERE provnum IS NOT NULL AND snapshot_date_key IS NOT NULL
        ) x
    ) y;

    TRUNCATE TABLE gold.dim_provider;

    INSERT INTO gold.dim_provider (
        provider_key, provnum, month_key, effective_from, effective_to, is_current,
        provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds, _refreshed_at
    )
    SELECT
        FNV_HASH(provnum || '_' || month_key::VARCHAR)                             AS provider_key,
        provnum,
        month_key,
        MIN(month_key) OVER (PARTITION BY provnum, version_group)                  AS effective_from,
        CASE WHEN version_group = MAX(version_group) OVER (PARTITION BY provnum)
             THEN NULL
             ELSE MAX(month_key) OVER (PARTITION BY provnum, version_group)
        END                                                                        AS effective_to,
        (version_group = MAX(version_group) OVER (PARTITION BY provnum))           AS is_current,
        provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds,
        SYSDATE
    FROM tmp_dim_flagged;

    -- Unknown member: a single sentinel row (provider_key = -1) so fact rows
    -- whose provnum/month has no real dim_provider version still resolve to a
    -- dimension member instead of a NULL key. gold.fact_daily_staffing_metrics
    -- COALESCEs its looked-up provider_key to -1 to point missing providers
    -- here. -1 is used deliberately (never produced by FNV_HASH for a real
    -- key in practice); provnum 'UNKNOWN' / month_key 0 are sentinels, and the
    -- descriptive attributes are 'Unknown'/NULL. is_current = TRUE so it isn't
    -- filtered out by a "current only" predicate.
    INSERT INTO gold.dim_provider (
        provider_key, provnum, month_key, effective_from, effective_to, is_current,
        provider_name, provider_address, city, state, zip_code,
        county_name, ownership_type, provider_type, certified_beds, _refreshed_at
    )
    VALUES (
        -1, 'UNKNOWN', 0, 0, NULL, TRUE,
        'Unknown', NULL, NULL, NULL, NULL,
        NULL, NULL, NULL, NULL, SYSDATE
    );

    DROP TABLE tmp_dim_flagged;

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
