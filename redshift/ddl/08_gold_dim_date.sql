-- Gold dimension: calendar date, day grain.
--
-- Grain      : one row per calendar day across whatever range
--              gold.sp_refresh_gold_dim_date is called with — this table
--              isn't derived from silver at all (it's a static calendar,
--              not sourced from any ingested data), so its refresh is a
--              generate-and-replace, not a reshape/rollup of anything.
--
-- date_key   : INTEGER YYYYMMDD, day-grain natural key — same convention as
--              silver's workdate, for joining to daily-grain data if ever
--              needed (silver.pbj_daily_nurse_staffing.workdate, e.g.).
-- month_key  : INTEGER YYYYMM (6-digit, e.g. 202410) — same convention and
--              column name as gold.dim_provider.month_key,
--              gold.fact_monthly_staffing_metrics.month_key, and
--              gold.fact_provider_quality_metrics.month_key, so this table
--              equi-joins to all three on (month_key) directly.
-- day_of_week: 0=Sunday..6=Saturday (Redshift EXTRACT(DOW ...) convention),
--              matching the same convention already used for the weekend
--              HPRD split in sp_refresh_gold_fact_monthly_staffing_metrics.
--
-- Refresh : gold.sp_refresh_gold_dim_date(p_start_date, p_end_date), full
--           TRUNCATE + INSERT — cheap even for a multi-decade range (a
--           20-year day-grain calendar is ~7,300 rows).
-- DISTSTYLE ALL : small and joined constantly by every query that touches
--           dates — replicating it to every node avoids a redistribution
--           step on every join, the standard Redshift recommendation for
--           this kind of reference/calendar dimension.
-- SORTKEY : date_key (natural chronological scan order)

CREATE TABLE IF NOT EXISTS gold.dim_date (

    date_key         INTEGER         NOT NULL,   -- YYYYMMDD
    full_date        DATE            NOT NULL,
    month_key        INTEGER         NOT NULL,   -- YYYYMM

    day_of_month     SMALLINT,
    day_of_week      SMALLINT,                   -- 0=Sun..6=Sat
    day_name         VARCHAR(9),
    is_weekend       BOOLEAN,
    week_of_year     SMALLINT,

    month_number     SMALLINT,
    month_name       VARCHAR(9),

    quarter          SMALLINT,
    quarter_name     VARCHAR(2),                 -- 'Q1'..'Q4'

    year             SMALLINT,
    is_leap_year     BOOLEAN,

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at    TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE ALL
SORTKEY (date_key);
