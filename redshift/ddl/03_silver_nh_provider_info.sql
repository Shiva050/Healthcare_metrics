-- Silver (curated) table for NH Provider Info — monthly snapshot.
--
-- Load strategy : delete-then-insert (NOT merge). Each monthly file is a full
--                 replace of that month's providers, not a row-by-row upsert.
-- Key           : provnum + snapshot_date_key
-- Duplicates    : a repeated provnum within one file has no distinguishing
--                 lineage (drive_modified_at/md5hash are constant for every
--                 row in a single load) — it means the file is malformed,
--                 not that two updates need a winner picked. The Step
--                 Function checks for this (CheckNhDuplicates) before ever
--                 calling silver.sp_load_nh_provider_info, and routes any
--                 hit straight to the DLQ.
-- snapshot_date_key : INTEGER YYYYMMDD, first-of-month, derived from the
--                     source filename (e.g. NH_ProviderInfo_Oct2024.csv ->
--                     20241001) — NOT from S3/Drive modifiedTime, since a
--                     late re-upload of an old month's file must still key
--                     to that old month, not to whenever it happened to be
--                     re-uploaded.
-- DISTKEY       : provnum  (high cardinality, used in provider-level filters/joins)
-- SORTKEY       : snapshot_date_key, provnum  (time-series scans by month then provider)

CREATE TABLE IF NOT EXISTS silver.nh_provider_info (

    -- ── Key ─────────────────────────────────────────────────────────────────
    provnum                             VARCHAR(20)     NOT NULL,   -- CMS CERTIFICATION NUMBER (CCN)
    snapshot_date_key                   INTEGER         NOT NULL,   -- YYYYMMDD, first-of-month

    -- ── Facility info ───────────────────────────────────────────────────────
    provider_name                       VARCHAR(255),
    provider_address                    VARCHAR(255),
    city                                VARCHAR(100),
    state                               VARCHAR(2),
    zip_code                            INTEGER,
    telephone_number                    BIGINT,
    ssa_county_code                     SMALLINT,
    county_name                         VARCHAR(100),
    ownership_type                      VARCHAR(100),
    certified_beds                      SMALLINT,
    avg_residents_per_day               DECIMAL(4,1),
    avg_residents_per_day_footnote      SMALLINT,
    provider_type                       VARCHAR(100),
    resides_in_hospital                 BOOLEAN,
    legal_business_name                 VARCHAR(255),
    date_first_approved                 DATE,
    affiliated_entity_name              VARCHAR(255),
    affiliated_entity_id                SMALLINT,
    ccrc_status                         BOOLEAN,
    special_focus_status                VARCHAR(50),
    abuse_icon                          BOOLEAN,
    health_inspection_over_2yrs         BOOLEAN,
    ownership_change_last_12mo          BOOLEAN,
    resident_family_council             VARCHAR(10),
    sprinkler_systems_all_areas         VARCHAR(10),

    -- ── Ratings ──────────────────────────────────────────────────────────────
    overall_rating                      SMALLINT,
    overall_rating_footnote             SMALLINT,
    health_inspection_rating            SMALLINT,
    health_inspection_rating_footnote   SMALLINT,
    qm_rating                           SMALLINT,
    qm_rating_footnote                  SMALLINT,
    longstay_qm_rating                  SMALLINT,
    longstay_qm_rating_footnote         SMALLINT,
    shortstay_qm_rating                 SMALLINT,
    shortstay_qm_rating_footnote        SMALLINT,
    staffing_rating                     SMALLINT,
    staffing_rating_footnote            SMALLINT,

    -- ── Reported staffing hours (HPRD) ──────────────────────────────────────
    reported_staffing_footnote          SMALLINT,
    pt_staffing_footnote                SMALLINT,
    reported_cna_hprd                   DECIMAL(6,5),
    reported_lpn_hprd                   DECIMAL(6,5),
    reported_rn_hprd                    DECIMAL(6,5),
    reported_licensed_hprd              DECIMAL(6,5),
    reported_total_nurse_hprd           DECIMAL(7,5),
    reported_weekend_total_nurse_hprd   DECIMAL(7,5),
    reported_weekend_rn_hprd            DECIMAL(6,5),
    reported_pt_hprd                    DECIMAL(6,5),

    -- ── Turnover ─────────────────────────────────────────────────────────────
    total_nurse_turnover_pct            DECIMAL(4,1),
    total_nurse_turnover_footnote       SMALLINT,
    rn_turnover_pct                     DECIMAL(4,1),
    rn_turnover_footnote                SMALLINT,
    administrators_left_count           SMALLINT,
    administrator_turnover_footnote     SMALLINT,

    -- ── Case-mix / adjusted staffing ────────────────────────────────────────
    nursing_case_mix_index              DECIMAL(6,5),
    nursing_case_mix_index_ratio        DECIMAL(6,5),
    casemix_cna_hprd                    DECIMAL(6,5),
    casemix_lpn_hprd                    DECIMAL(6,5),
    casemix_rn_hprd                     DECIMAL(6,5),
    casemix_total_nurse_hprd            DECIMAL(7,5),
    casemix_weekend_total_nurse_hprd    DECIMAL(6,5),
    adjusted_cna_hprd                   DECIMAL(6,5),
    adjusted_lpn_hprd                   DECIMAL(6,5),
    adjusted_rn_hprd                    DECIMAL(6,5),
    adjusted_total_nurse_hprd           DECIMAL(7,5),
    adjusted_weekend_total_nurse_hprd   DECIMAL(7,5),

    -- ── Health survey cycle 1 ────────────────────────────────────────────────
    cycle1_survey_date                       DATE,
    cycle1_total_health_deficiencies         SMALLINT,
    cycle1_standard_health_deficiencies      SMALLINT,
    cycle1_complaint_health_deficiencies     SMALLINT,
    cycle1_health_deficiency_score           SMALLINT,
    cycle1_health_revisits                   SMALLINT,
    cycle1_health_revisit_score              SMALLINT,
    cycle1_total_health_score                SMALLINT,

    -- ── Health survey cycle 2 ────────────────────────────────────────────────
    cycle2_survey_date                       DATE,
    cycle2_total_health_deficiencies         SMALLINT,
    cycle2_standard_health_deficiencies      SMALLINT,
    cycle2_complaint_health_deficiencies     SMALLINT,
    cycle2_health_deficiency_score           SMALLINT,
    cycle2_health_revisits                   SMALLINT,
    cycle2_health_revisit_score              SMALLINT,
    cycle2_total_health_score                SMALLINT,

    -- ── Health survey cycle 3 ────────────────────────────────────────────────
    cycle3_survey_date                       DATE,
    cycle3_total_health_deficiencies         SMALLINT,
    cycle3_standard_health_deficiencies      SMALLINT,
    cycle3_complaint_health_deficiencies     SMALLINT,
    cycle3_health_deficiency_score           SMALLINT,
    cycle3_health_revisits                   SMALLINT,
    cycle3_health_revisit_score              SMALLINT,
    cycle3_total_health_score                SMALLINT,

    -- ── Penalties / incidents / geo ──────────────────────────────────────────
    total_weighted_health_score         DECIMAL(7,3),
    facility_reported_incidents         SMALLINT,
    substantiated_complaints            SMALLINT,
    infection_control_citations         SMALLINT,
    num_fines                           SMALLINT,
    total_fines_amount                  DECIMAL(9,2),
    payment_denials                     SMALLINT,
    total_penalties                     SMALLINT,
    location                            VARCHAR(500),
    latitude                             DECIMAL(6,4),
    longitude                            DECIMAL(6,3),
    geocoding_footnote                  SMALLINT,
    processing_date                     DATE,

    -- ── Lineage metadata ─────────────────────────────────────────────────────
    _source_s3_key       VARCHAR(1024),         -- S3 path of the originating CSV
    _drive_modified_at   VARCHAR(30),           -- ISO-8601 from Drive API (audit only — not a tiebreaker, see sp_load_nh_provider_info)
    _md5hash             VARCHAR(32),           -- MD5 of source file       (audit only)
    _loaded_at           TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (snapshot_date_key, provnum);
