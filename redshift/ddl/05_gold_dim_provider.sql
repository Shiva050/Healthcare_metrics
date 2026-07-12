-- Gold dimension: one row per provider, current descriptive attributes only.
--
-- Grain      : provnum
-- Source     : silver.nh_provider_info, most recent snapshot_date_key per
--              provnum — this is a "current state" dimension, not an SCD.
--              Rating/turnover/deficiency history that changes month to
--              month lives in gold.fact_provider_quality_metrics, not here;
--              this table is limited to attributes that are slowly-changing
--              descriptive facts about the facility itself (name, address,
--              ownership, bed count), keeping the star-schema split clean.
-- Refresh    : full TRUNCATE + INSERT by gold.sp_refresh_gold_dim_provider,
--              on every run — see that proc for why (small data, always
--              idempotent, matches the delete/insert philosophy already
--              used for silver.nh_provider_info).
-- DISTKEY    : provnum (joins to both gold fact tables on this column)

CREATE TABLE IF NOT EXISTS gold.dim_provider (

    provnum                     VARCHAR(20)     NOT NULL,

    provider_name               VARCHAR(255),
    provider_address            VARCHAR(255),
    city                        VARCHAR(100),
    state                       VARCHAR(2),
    zip_code                    INTEGER,
    county_name                 VARCHAR(100),
    ownership_type              VARCHAR(100),
    provider_type               VARCHAR(100),
    certified_beds              SMALLINT,
    date_first_approved         DATE,
    resides_in_hospital         BOOLEAN,
    ccrc_status                 BOOLEAN,
    latitude                    DECIMAL(6,4),
    longitude                   DECIMAL(6,3),

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _source_snapshot_date_key   INTEGER,        -- which nh_provider_info snapshot this row came from
    _refreshed_at               TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
SORTKEY (provnum);
