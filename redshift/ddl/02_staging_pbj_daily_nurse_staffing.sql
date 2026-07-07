-- Staging table for PBJ Daily Nurse Staffing.
-- Truncated before each COPY; no DISTKEY/SORTKEY needed (small, ephemeral).
-- Column list must match the COPY column list in the Step Function exactly.

CREATE TABLE IF NOT EXISTS staging.pbj_daily_nurse_staffing_stg (

    provnum         VARCHAR(20),
    provname        VARCHAR(255),
    city            VARCHAR(100),
    state           VARCHAR(2),
    county_name     VARCHAR(100),
    county_fips     SMALLINT,
    cy_qtr          VARCHAR(10),
    workdate        INTEGER,
    mdscensus       SMALLINT,

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
    hrs_medaide_ctr DECIMAL(4,2)

)
DISTSTYLE EVEN;
