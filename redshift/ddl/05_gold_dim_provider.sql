-- Gold dimension: monthly snapshot of provider descriptive attributes, with
-- SCD Type 2 version metadata carried on every row.
--
-- Grain      : provnum + month_key — one row per month present in
--              silver.nh_provider_info for that provider (not collapsed
--              into one row per version). Kept at this grain deliberately
--              so fact tables join with a plain equi-join on (provnum,
--              month_key) — no date-range join required. effective_from/
--              effective_to/is_current below describe which contiguous run
--              of unchanged attributes ("version") each row belongs to;
--              they're metadata about the row, not the join key.
--
-- month_key    : INTEGER YYYYMM (e.g. 202410), derived from silver's
--                snapshot_date_key (YYYYMMDD, always first-of-month) as
--                snapshot_date_key / 100.
-- provider_key : surrogate key = FNV_HASH(provnum || '_' || month_key),
--                Redshift's built-in hash function returning a native
--                BIGINT — cheaper to join/sort/distribute on than a VARCHAR,
--                and deterministic (a pure function of its input, unlike
--                IDENTITY, which assigns by insertion order and would hand
--                the same logical row a different key on every refresh
--                under this table's full TRUNCATE+INSERT rebuild strategy).
--                Collision risk is negligible at this table's scale
--                (thousands of providers x low hundreds of months, against
--                a 64-bit hash space).
--
-- effective_from : YYYYMM month this row's attribute values first appeared
--                   (identical across every consecutive month sharing them).
-- effective_to   : YYYYMM month this version was last active (inclusive);
--                   NULL means it's still active (is_current = TRUE). Only
--                   ever non-NULL for a version that a later, different
--                   version has since superseded.
-- is_current     : TRUE for every row belonging to the version that's still
--                   active as of the latest month present in silver — i.e.
--                   every month in that run, not just the newest one.
--
-- Why a full TRUNCATE+INSERT rebuild can still produce correct SCD2
-- metadata: silver.nh_provider_info's own load proc only ever deletes+
-- inserts the *current* month, never touching prior months, so silver
-- already holds every month's history forever. gold.sp_refresh_gold_dim_provider
-- recomputes effective_from/effective_to/is_current from scratch each run
-- by comparing every month's attributes to the prior month's (LAG, per
-- provnum) — no incremental "what changed since last run" state needed.
--
-- Unknown member: the refresh proc also seeds one sentinel row with
-- provider_key = -1 (provnum 'UNKNOWN', month_key 0, attributes 'Unknown'/
-- NULL). Fact tables COALESCE a missed provider_key lookup to -1 so orphaned
-- providers (staffing reported for a month with no NH snapshot) roll into an
-- explicit Unknown bucket instead of a NULL key. -1 is safe as a sentinel —
-- real keys come from FNV_HASH and don't collide with it in practice.
--
-- Refresh : gold.sp_refresh_gold_dim_provider, full TRUNCATE + INSERT.
-- DISTKEY : provnum (joins to both gold fact tables on this column)
-- SORTKEY : provnum, month_key (per-provider time-series scans; matches the
--           fact tables' own sort convention)

CREATE TABLE IF NOT EXISTS gold.dim_provider (

    provider_key                BIGINT          NOT NULL,   -- FNV_HASH(provnum || '_' || month_key)
    provnum                     VARCHAR(20)     NOT NULL,
    month_key                   INTEGER         NOT NULL,   -- YYYYMM — fact-table join key

    effective_from               INTEGER         NOT NULL,   -- YYYYMM this version began
    effective_to                 INTEGER,                    -- YYYYMM this version ended, NULL = current
    is_current                   BOOLEAN         NOT NULL,

    provider_name                VARCHAR(255),
    provider_address              VARCHAR(255),
    city                          VARCHAR(100),
    state                         VARCHAR(2),
    zip_code                      INTEGER,
    county_name                   VARCHAR(100),
    ownership_type                VARCHAR(100),
    provider_type                 VARCHAR(100),
    certified_beds                SMALLINT,

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at                 TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (provnum, month_key);
