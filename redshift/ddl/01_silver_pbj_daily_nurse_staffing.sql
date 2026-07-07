-- Silver (curated) table for PBJ Daily Nurse Staffing.

-- Merge key  : provnum + workdate
-- Tiebreaker : _drive_modified_at DESC, _md5hash DESC
-- DISTKEY    : provnum  (high cardinality, used in provider-level filters/joins)
-- SORTKEY    : workdate, provnum  (time-series scans by date then provider)

CREATE TABLE IF NOT EXISTS silver.pbj_daily_nurse_staffing (

    -- ── Business columns ────────────────────────────────────────────────────
    provnum         VARCHAR(20)     NOT NULL,   -- CMS provider number
    provname        VARCHAR(255),
    city            VARCHAR(100),
    state           VARCHAR(2),
    county_name     VARCHAR(100),
    county_fips     SMALLINT,                   -- NUMBER(3,0)
    cy_qtr          VARCHAR(10),                -- e.g. "Q2 2024"
    workdate        INTEGER         NOT NULL,   -- YYYYMMDD, NUMBER(8,0)
    mdscensus       SMALLINT,                   -- NUMBER(3,0)

    hrs_rndon       DECIMAL(5,2),
    hrs_rndon_emp   DECIMAL(5,2),
    hrs_rndon_ctr   DECIMAL(4,2),

    hrs_rnadmin     DECIMAL(5,2),
    hrs_rnadmin_emp DECIMAL(5,2),
    hrs_rnadmin_ctr DECIMAL(4,2),

    hrs_rn          DECIMAL(5,2),
    hrs_rn_emp      DECIMAL(5,2),
    hrs_rn_ctr      DECIMAL(5,2),

    hrs_lpnadmin     DECIMAL(5,2),
    hrs_lpnadmin_emp DECIMAL(5,2),
    hrs_lpnadmin_ctr DECIMAL(5,2),

    hrs_lpn         DECIMAL(7,2),
    hrs_lpn_emp     DECIMAL(5,2),
    hrs_lpn_ctr     DECIMAL(7,2),

    hrs_cna         DECIMAL(6,2),
    hrs_cna_emp     DECIMAL(6,2),
    hrs_cna_ctr     DECIMAL(5,2),

    hrs_natrn       DECIMAL(5,2),
    hrs_natrn_emp   DECIMAL(5,2),
    hrs_natrn_ctr   DECIMAL(5,2),

    hrs_medaide     DECIMAL(5,2),
    hrs_medaide_emp DECIMAL(5,2),
    hrs_medaide_ctr DECIMAL(4,2),

    -- ── Lineage / tiebreaker metadata ───────────────────────────────────────
    _source_s3_key       VARCHAR(1024),         -- S3 path of the originating CSV
    _drive_modified_at   VARCHAR(30),           -- ISO-8601 from Drive API  (used as primary sort tiebreaker)
    _md5hash             VARCHAR(32),           -- MD5 of source file       (secondary tiebreaker)
    _loaded_at           TIMESTAMP DEFAULT SYSDATE

)
DISTSTYLE KEY
DISTKEY (provnum)
COMPOUND SORTKEY (workdate, provnum);
