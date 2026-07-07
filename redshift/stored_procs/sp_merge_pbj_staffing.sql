-- Stored procedure: idempotent MERGE from staging -> silver.
--
-- Called by the Step Function after a successful COPY into staging.
-- Parameters come from summary["processed"] produced by the Lambda:
--   p_s3_key            : S3 path of the source CSV (for lineage)
--   p_drive_modified_at : Drive API modifiedTime (ISO-8601) — primary tiebreaker
--   p_md5hash           : MD5 of the source file — secondary tiebreaker
--
-- Merge key  : provnum + workdate
-- Win rule   : incoming row wins when its drive_modified_at is NEWER than the
--              existing row's, or when equal but md5hash is lexicographically
--              GREATER (covers the edge case of same-timestamp, same-batch,
--              different-content files).
--
-- Error classification (for Step Function DLQ routing):
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; Step Function retries

CREATE OR REPLACE PROCEDURE silver.sp_merge_pbj_staffing(
    p_s3_key            VARCHAR(1024),
    p_drive_modified_at VARCHAR(30),
    p_md5hash           VARCHAR(32)
)
LANGUAGE plpgsql
AS $$
BEGIN

    MERGE INTO silver.pbj_daily_nurse_staffing
    USING (
        SELECT
            provnum,
            provname,
            city,
            state,
            county_name,
            county_fips,
            cy_qtr,
            workdate,
            mdscensus,
            hrs_rndon,
            hrs_rndon_emp,
            hrs_rndon_ctr,
            hrs_rnadmin,
            hrs_rnadmin_emp,
            hrs_rnadmin_ctr,
            hrs_rn,
            hrs_rn_emp,
            hrs_rn_ctr,
            hrs_lpnadmin,
            hrs_lpnadmin_emp,
            hrs_lpnadmin_ctr,
            hrs_lpn,
            hrs_lpn_emp,
            hrs_lpn_ctr,
            hrs_cna,
            hrs_cna_emp,
            hrs_cna_ctr,
            hrs_natrn,
            hrs_natrn_emp,
            hrs_natrn_ctr,
            hrs_medaide,
            hrs_medaide_emp,
            hrs_medaide_ctr
        FROM staging.pbj_daily_nurse_staffing_stg
        WHERE provnum IS NOT NULL
          AND workdate IS NOT NULL
    ) AS src
    ON  silver.pbj_daily_nurse_staffing.provnum  = src.provnum
    AND silver.pbj_daily_nurse_staffing.workdate = src.workdate

    -- Update only when incoming file is newer, or same-time but different content
    WHEN MATCHED AND (
        p_drive_modified_at > _drive_modified_at
        OR (
            p_drive_modified_at = _drive_modified_at
            AND p_md5hash > _md5hash
        )
    ) THEN
        UPDATE SET
            provname        = src.provname,
            city            = src.city,
            state           = src.state,
            county_name     = src.county_name,
            county_fips     = src.county_fips,
            cy_qtr          = src.cy_qtr,
            mdscensus       = src.mdscensus,
            hrs_rndon       = src.hrs_rndon,
            hrs_rndon_emp   = src.hrs_rndon_emp,
            hrs_rndon_ctr   = src.hrs_rndon_ctr,
            hrs_rnadmin     = src.hrs_rnadmin,
            hrs_rnadmin_emp = src.hrs_rnadmin_emp,
            hrs_rnadmin_ctr = src.hrs_rnadmin_ctr,
            hrs_rn          = src.hrs_rn,
            hrs_rn_emp      = src.hrs_rn_emp,
            hrs_rn_ctr      = src.hrs_rn_ctr,
            hrs_lpnadmin     = src.hrs_lpnadmin,
            hrs_lpnadmin_emp = src.hrs_lpnadmin_emp,
            hrs_lpnadmin_ctr = src.hrs_lpnadmin_ctr,
            hrs_lpn         = src.hrs_lpn,
            hrs_lpn_emp     = src.hrs_lpn_emp,
            hrs_lpn_ctr     = src.hrs_lpn_ctr,
            hrs_cna         = src.hrs_cna,
            hrs_cna_emp     = src.hrs_cna_emp,
            hrs_cna_ctr     = src.hrs_cna_ctr,
            hrs_natrn       = src.hrs_natrn,
            hrs_natrn_emp   = src.hrs_natrn_emp,
            hrs_natrn_ctr   = src.hrs_natrn_ctr,
            hrs_medaide     = src.hrs_medaide,
            hrs_medaide_emp = src.hrs_medaide_emp,
            hrs_medaide_ctr = src.hrs_medaide_ctr,
            _source_s3_key      = p_s3_key,
            _drive_modified_at  = p_drive_modified_at,
            _md5hash            = p_md5hash,
            _loaded_at          = SYSDATE

    WHEN NOT MATCHED THEN
        INSERT (
            provnum, provname, city, state, county_name, county_fips,
            cy_qtr, workdate, mdscensus,
            hrs_rndon, hrs_rndon_emp, hrs_rndon_ctr,
            hrs_rnadmin, hrs_rnadmin_emp, hrs_rnadmin_ctr,
            hrs_rn, hrs_rn_emp, hrs_rn_ctr,
            hrs_lpnadmin, hrs_lpnadmin_emp, hrs_lpnadmin_ctr,
            hrs_lpn, hrs_lpn_emp, hrs_lpn_ctr,
            hrs_cna, hrs_cna_emp, hrs_cna_ctr,
            hrs_natrn, hrs_natrn_emp, hrs_natrn_ctr,
            hrs_medaide, hrs_medaide_emp, hrs_medaide_ctr,
            _source_s3_key, _drive_modified_at, _md5hash, _loaded_at
        )
        VALUES (
            src.provnum, src.provname, src.city, src.state, src.county_name, src.county_fips,
            src.cy_qtr, src.workdate, src.mdscensus,
            src.hrs_rndon, src.hrs_rndon_emp, src.hrs_rndon_ctr,
            src.hrs_rnadmin, src.hrs_rnadmin_emp, src.hrs_rnadmin_ctr,
            src.hrs_rn, src.hrs_rn_emp, src.hrs_rn_ctr,
            src.hrs_lpnadmin, src.hrs_lpnadmin_emp, src.hrs_lpnadmin_ctr,
            src.hrs_lpn, src.hrs_lpn_emp, src.hrs_lpn_ctr,
            src.hrs_cna, src.hrs_cna_emp, src.hrs_cna_ctr,
            src.hrs_natrn, src.hrs_natrn_emp, src.hrs_natrn_ctr,
            src.hrs_medaide, src.hrs_medaide_emp, src.hrs_medaide_ctr,
            p_s3_key, p_drive_modified_at, p_md5hash, SYSDATE
        );

EXCEPTION WHEN OTHERS THEN
    IF SQLERRM ILIKE '%invalid%'
       OR SQLERRM ILIKE '%out of range%'
       OR SQLERRM ILIKE '%type mismatch%'
       OR SQLERRM ILIKE '%conversion%'
       OR SQLERRM ILIKE '%constraint%'
       OR SQLERRM ILIKE '%violat%'
       OR SQLERRM ILIKE '%numeric%' THEN
        RAISE EXCEPTION 'DATA_ERROR | % | source: %', SQLERRM, p_s3_key;
    ELSE
        RAISE;
    END IF;
END;
$$;
