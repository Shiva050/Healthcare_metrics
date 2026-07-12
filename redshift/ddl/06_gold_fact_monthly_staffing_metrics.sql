-- Gold fact: monthly staffing KPIs per provider, rolled up from daily PBJ data.
--
-- Grain      : provnum + month_key
-- Source     : silver.pbj_daily_nurse_staffing, GROUP BY provnum and the
--              first-of-month of workdate.
-- month_key  : INTEGER YYYYMM01 (first-of-month), same convention as
--              silver.nh_provider_info.snapshot_date_key, so this table joins
--              cleanly to gold.fact_provider_quality_metrics on
--              (provnum, month_key = snapshot_date_key) for combined
--              staffing-vs-quality reporting.
--
-- HPRD definitions (hours per resident day): direct-care hours only
-- (hrs_rn/hrs_lpn/hrs_cna) divided by total resident days, deliberately
-- excluding admin/director hours (hrs_rndon, hrs_rnadmin, hrs_lpnadmin) —
-- this mirrors what CMS's own reported_*_hprd columns in nh_provider_info
-- cover, so gold's numbers stay comparable to CMS-reported figures rather
-- than silently diverging in scope. That said, this is a reporting-oriented
-- approximation, not a certified reproduction of CMS's exact PBJ methodology
-- — worth sanity-checking against reported_rn_hprd etc. once real data is
-- loaded, before leaning on this for anything regulatory.
--
-- Refresh    : full TRUNCATE + INSERT by
--              gold.sp_refresh_gold_fact_monthly_staffing_metrics — see that
--              proc for why full rebuild instead of incremental.
-- DISTKEY    : provnum (joins to gold.dim_provider and the quality fact)
-- SORTKEY    : month_key, provnum (time-series scans by month then provider)

CREATE TABLE IF NOT EXISTS gold.fact_monthly_staffing_metrics (

    provnum                     VARCHAR(20)     NOT NULL,
    month_key                   INTEGER         NOT NULL,   -- YYYYMM01

    avg_daily_census            DECIMAL(7,2),
    total_resident_days         INTEGER,                    -- SUM(mdscensus); HPRD denominator
    days_reported               SMALLINT,                   -- COUNT(DISTINCT workdate); completeness signal

    rn_hours                    DECIMAL(9,2),
    lpn_hours                   DECIMAL(9,2),
    cna_hours                   DECIMAL(9,2),
    total_nurse_hours           DECIMAL(10,2),               -- rn + lpn + cna
    admin_director_hours        DECIMAL(9,2),                -- hrs_rndon + hrs_rnadmin + hrs_lpnadmin, excluded from HPRD

    rn_hprd                     DECIMAL(7,5),
    lpn_hprd                    DECIMAL(7,5),
    cna_hprd                    DECIMAL(7,5),
    total_nurse_hprd            DECIMAL(7,5),
    weekend_total_nurse_hprd    DECIMAL(7,5),

    contract_hours_pct          DECIMAL(5,2),                -- contract / total, across rn+lpn+cna

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at                TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (month_key, provnum);
