-- Gold dimension: monthly snapshot of provider descriptive attributes.
--
-- Grain      : provnum + month_key — one row per month present in
--              silver.nh_provider_info for that provider. Full history is
--              preserved by grain alone (every month gets its own row); no
--              separate version/current tracking metadata is kept — if you
--              need "what changed" or "what's current", compare adjacent
--              month_key rows or filter to MAX(month_key) per provnum at
--              query time.
--
-- month_key    : INTEGER YYYYMM (e.g. 202410), derived from silver's
--                snapshot_date_key (YYYYMMDD, always first-of-month) as
--                snapshot_date_key / 100. This is the fact-table join key —
--                a plain equi-join on (provnum, month_key), no date-range
--                join needed.
-- provider_key : surrogate key = FNV_HASH(provnum || '_' || month_key),
--                Redshift's built-in hash function returning a native
--                BIGINT — cheaper to join/sort/distribute on than a VARCHAR,
--                and deterministic (a pure function of its input, unlike
--                IDENTITY). Deliberately not a Redshift IDENTITY column:
--                IDENTITY assigns values by insertion order, not by the
--                row's natural key, so the same logical row would get a
--                *different* surrogate key on every refresh under this
--                table's full TRUNCATE+INSERT rebuild strategy (see
--                sp_refresh_gold_dim_provider) — FNV_HASH always reproduces
--                the same BIGINT for the same (provnum, month_key), which is
--                what a rebuild-every-run refresh actually needs. Collision
--                risk is negligible at this table's scale (thousands of
--                providers x low hundreds of months, against a 64-bit hash
--                space).
--
-- Refresh : gold.sp_refresh_gold_dim_provider, full TRUNCATE + INSERT.
-- DISTKEY : provnum (joins to both gold fact tables on this column)
-- SORTKEY : provnum, month_key (per-provider time-series scans; matches the
--           fact tables' own sort convention)

CREATE TABLE IF NOT EXISTS gold.dim_provider (

    provider_key                BIGINT          NOT NULL,   -- FNV_HASH(provnum || '_' || month_key)
    provnum                     VARCHAR(20)     NOT NULL,
    month_key                   INTEGER         NOT NULL,   -- YYYYMM — fact-table join key

    provider_name               VARCHAR(255),
    provider_address            VARCHAR(255),
    city                        VARCHAR(100),
    state                       VARCHAR(2),
    zip_code                    INTEGER,
    county_name                 VARCHAR(100),
    ownership_type              VARCHAR(100),
    provider_type               VARCHAR(100),
    certified_beds              SMALLINT,

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at                TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (provnum, month_key);
