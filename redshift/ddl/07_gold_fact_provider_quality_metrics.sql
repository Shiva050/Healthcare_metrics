-- Gold fact: monthly quality/ratings KPIs per provider.
--
-- Grain      : provnum + snapshot_date_key
-- Source     : silver.nh_provider_info — already monthly-snapshot grain, so
--              this is a business-curated reshape (ratings, turnover,
--              deficiencies, penalties) rather than an aggregation. Column
--              names are kept close to the silver source so this table reads
--              as "the reporting-friendly subset of nh_provider_info", not a
--              reinterpretation of it.
-- Join       : (provnum, snapshot_date_key) to
--              gold.fact_monthly_staffing_metrics (provnum, month_key) for
--              combined staffing-vs-quality analysis (e.g. does low HPRD
--              correlate with more deficiencies/penalties).
--
-- Refresh    : full TRUNCATE + INSERT by
--              gold.sp_refresh_gold_fact_provider_quality_metrics.
-- DISTKEY    : provnum
-- SORTKEY    : snapshot_date_key, provnum

CREATE TABLE IF NOT EXISTS gold.fact_provider_quality_metrics (

    provnum                             VARCHAR(20)     NOT NULL,
    snapshot_date_key                   INTEGER         NOT NULL,   -- YYYYMM01

    -- ── Ratings ──────────────────────────────────────────────────────────────
    overall_rating                      SMALLINT,
    health_inspection_rating            SMALLINT,
    qm_rating                           SMALLINT,
    longstay_qm_rating                  SMALLINT,
    shortstay_qm_rating                 SMALLINT,
    staffing_rating                     SMALLINT,

    -- ── Turnover ─────────────────────────────────────────────────────────────
    total_nurse_turnover_pct            DECIMAL(4,1),
    rn_turnover_pct                     DECIMAL(4,1),
    administrators_left_count           SMALLINT,

    -- ── Deficiencies / penalties / incidents ────────────────────────────────
    total_deficiencies_3yr              SMALLINT,    -- sum of cycle1/2/3 total_health_deficiencies
    facility_reported_incidents         SMALLINT,
    substantiated_complaints            SMALLINT,
    infection_control_citations         SMALLINT,
    num_fines                           SMALLINT,
    total_fines_amount                  DECIMAL(9,2),
    payment_denials                     SMALLINT,
    total_penalties                     SMALLINT,

    -- ── Facility attributes that vary by snapshot ───────────────────────────
    certified_beds                      SMALLINT,
    avg_residents_per_day               DECIMAL(4,1),
    ownership_type                      VARCHAR(100),
    special_focus_status                VARCHAR(50),
    abuse_icon                          BOOLEAN,

    -- ── Lineage ──────────────────────────────────────────────────────────────
    _refreshed_at                       TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (snapshot_date_key, provnum);
