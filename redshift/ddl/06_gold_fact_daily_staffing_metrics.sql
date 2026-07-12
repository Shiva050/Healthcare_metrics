-- Gold fact: daily staffing measures per provider, from silver PBJ data.
--
-- Grain      : provnum + workdate (one row per provider per calendar day) —
--              the same grain as silver.pbj_daily_nurse_staffing, which the
--              ingestion pipeline already dedups to exactly one row per
--              (provnum, workdate). So this is a curated day-grain projection
--              of silver, not an aggregation.
--
-- date_key   : INTEGER YYYYMMDD = silver's workdate as-is. Day grain, so it's
--              a direct 1:1 FK to gold.dim_date.date_key — reports pull
--              day/weekday/month/quarter/year attributes from dim_date.
-- month_key  : INTEGER YYYYMM (6-digit, e.g. 202410) = workdate / 100. Kept
--              for the month-grain join to gold.dim_provider (whose grain is
--              provnum + month_key) and for rolling up / joining to the
--              monthly gold.fact_provider_quality_metrics.
-- provider_key : surrogate FK to gold.dim_provider, looked up on
--                (provnum, month_key) at refresh time — dim_provider is
--                monthly-versioned, so every day in a given month for a
--                provider resolves to that month's single provider_key.
--                PBJ staffing and NH Provider Info are separate source feeds,
--                so a provider can report staffing for a month it has no NH
--                snapshot (hence no dim_provider row); those misses are
--                COALESCEd to -1, the "Unknown" member gold.dim_provider
--                seeds, so orphaned providers land in an explicit Unknown
--                bucket instead of a NULL key. Not nullable in practice —
--                every row gets a real key or -1.
--
-- Measures (raw building blocks only — no ratios, no aggregation): downstream
-- BI derives HPRD and contract-mix from these three per-day values.
--   mdscensus                  = silver's daily resident census (MDS)
--   total_direct_care_hours    = hrs_rn + hrs_lpn + hrs_cna     (that day)
--   contract_direct_care_hours = hrs_rn_ctr + hrs_lpn_ctr + hrs_cna_ctr
-- Direct-care roles only (RN/LPN/CNA), excluding admin/director hours — the
-- same scope CMS's reported_*_hprd columns use. Each component is COALESCEd
-- to 0 in the refresh proc so a NULL in one role doesn't null the whole
-- day's total.
--
-- Refresh    : full TRUNCATE + INSERT by
--              gold.sp_refresh_gold_fact_daily_staffing_metrics.
-- DISTKEY    : provnum (whole gold layer distributes on provnum, so
--              provnum-keyed joins across the fact/dim tables co-locate)
-- SORTKEY    : date_key, provnum (daily time-series scans by day then provider)

CREATE TABLE IF NOT EXISTS gold.fact_daily_staffing_metrics (

    provider_key                BIGINT,                     -- FK -> gold.dim_provider.provider_key (-1 = Unknown member on miss)
    provnum                     VARCHAR(20)     NOT NULL,
    date_key                    INTEGER         NOT NULL,   -- YYYYMMDD (= workdate); FK -> gold.dim_date.date_key
    month_key                   INTEGER         NOT NULL,   -- YYYYMM

    mdscensus                   SMALLINT,                   -- daily resident census (MDS)
    total_direct_care_hours     DECIMAL(9,2),               -- hrs_rn + hrs_lpn + hrs_cna
    contract_direct_care_hours  DECIMAL(9,2),               -- hrs_rn_ctr + hrs_lpn_ctr + hrs_cna_ctr

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at                TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (date_key, provnum);
