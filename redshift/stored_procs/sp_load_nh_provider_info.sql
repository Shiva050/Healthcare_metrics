-- Stored procedure: idempotent delete-then-insert from staging -> silver.
--
-- Called by the Step Function after CopyNhToStagingTable *and* the
-- CheckNhDuplicates pre-check have both succeeded — the Step Function runs
-- `SELECT provnum, COUNT(*) FROM staging.nh_provider_info_stg WHERE provnum
-- IS NOT NULL GROUP BY provnum HAVING COUNT(*) > 1` before ever calling this
-- proc, and routes straight to the DLQ if that returns any rows: a repeated
-- provnum within one file has no distinguishing lineage (drive_modified_at/
-- md5hash are constant for every row in a single load), so a repeat means
-- the file is malformed, not that a winner needs picking.
--
-- The ROW_NUMBER/rn=1 dedup below still runs as a second, in-proc guard —
-- same belt-and-suspenders layering as silver.sp_merge_pbj_staffing. It's
-- what actually protects the DELETE/INSERT against ever inserting more than
-- one row per provnum, independent of whatever the state-machine pre-check
-- did or didn't catch.
--
-- Parameters:
--   p_s3_key            : S3 path of the source CSV (lineage)
--   p_snapshot_date_key : INTEGER YYYYMMDD, first-of-month — derived by the
--                         Lambda from the source filename (e.g.
--                         NH_ProviderInfo_Oct2024.csv -> 20241001), NOT from
--                         S3/Drive modifiedTime, since a late re-upload of an
--                         old month's corrected file must still land under
--                         that old month's key.
--   p_drive_modified_at : Drive API modifiedTime (ISO-8601) — primary tiebreaker.
--   p_md5hash           : MD5 of the source file — secondary tiebreaker.
--                         Both are constant for every row in *this* call
--                         (one file per call), so within a single load they
--                         can't distinguish one duplicate row from another
--                         on real lineage grounds — same caveat as PBJ's
--                         dedup. They're carried through as parameters (not
--                         read per-row) both for that ORDER BY and so
--                         silver.nh_provider_info records which Drive file
--                         version produced each row.
--
-- Load strategy: NH Provider Info is a full monthly snapshot (every provnum
-- CMS tracks is re-sent each month), so there's no row-level "last writer
-- wins" merge here — unlike PBJ, a new month's file is simply the new truth
-- for that month. DELETE + INSERT is used instead of MERGE:
--   - DELETE is scoped to (snapshot_date_key = p_snapshot_date_key AND
--     provnum IN <this file's provnums>) so a load can never remove another
--     month's rows, and only ever removes provnums actually present in this
--     file (defensive — correct today because the file is always a full
--     snapshot, but also correct if that ever changes to partial re-sends).
--   - Both statements run in the same implicit procedure transaction, so a
--     failure between them rolls back the DELETE too — no window where a
--     month's data is gone but the reload hasn't landed yet.
--   - Idempotent: re-running the same file for the same month deletes and
--     reinserts identical rows — safe to retry after a Step Function retry.
--
-- Error classification (for Step Function DLQ routing), same convention as
-- silver.sp_merge_pbj_staffing:
--   DATA_ERROR prefix  → bad data / schema mismatch → needs human review
--   anything else      → transient; Step Function retries

CREATE OR REPLACE PROCEDURE silver.sp_load_nh_provider_info(
    p_s3_key            VARCHAR(1024),
    p_snapshot_date_key INTEGER,
    p_drive_modified_at VARCHAR(30),
    p_md5hash           VARCHAR(32)
)
LANGUAGE plpgsql
AS $$
BEGIN

    -- Guard against the source CSV itself containing more than one row for
    -- the same provnum + snapshot_date_key (Redshift's MERGE would error out
    -- on this if we were using MERGE; for DELETE+INSERT it would instead
    -- silently duplicate rows in silver, which is just as bad).
    -- p_snapshot_date_key is included in the PARTITION BY for consistency
    -- with the (provnum, snapshot_date_key) key used everywhere else in this
    -- proc (see the DELETE below) — it's a no-op today since staging only
    -- ever holds one snapshot's rows per call, but keeps the partition
    -- correct if that invariant ever changes. p_drive_modified_at and
    -- p_md5hash are constant for every row in this call (one file per
    -- call), so this can't prefer one duplicate over another on real
    -- lineage grounds — it just picks one deterministically so exactly one
    -- row per (provnum, snapshot_date_key) reaches the DELETE/INSERT below.
    CREATE TEMP TABLE IF NOT EXISTS tmp_nh_stg_dedup (LIKE staging.nh_provider_info_stg);
    DELETE FROM tmp_nh_stg_dedup;

    INSERT INTO tmp_nh_stg_dedup
    SELECT
        provnum, provider_name, provider_address, city, state, zip_code,
        telephone_number, ssa_county_code, county_name, ownership_type,
        certified_beds, avg_residents_per_day, avg_residents_per_day_footnote,
        provider_type, resides_in_hospital, legal_business_name, date_first_approved,
        affiliated_entity_name, affiliated_entity_id, ccrc_status, special_focus_status,
        abuse_icon, health_inspection_over_2yrs, ownership_change_last_12mo,
        resident_family_council, sprinkler_systems_all_areas,
        overall_rating, overall_rating_footnote,
        health_inspection_rating, health_inspection_rating_footnote,
        qm_rating, qm_rating_footnote,
        longstay_qm_rating, longstay_qm_rating_footnote,
        shortstay_qm_rating, shortstay_qm_rating_footnote,
        staffing_rating, staffing_rating_footnote,
        reported_staffing_footnote, pt_staffing_footnote,
        reported_cna_hprd, reported_lpn_hprd, reported_rn_hprd, reported_licensed_hprd,
        reported_total_nurse_hprd, reported_weekend_total_nurse_hprd, reported_weekend_rn_hprd,
        reported_pt_hprd,
        total_nurse_turnover_pct, total_nurse_turnover_footnote,
        rn_turnover_pct, rn_turnover_footnote,
        administrators_left_count, administrator_turnover_footnote,
        nursing_case_mix_index, nursing_case_mix_index_ratio,
        casemix_cna_hprd, casemix_lpn_hprd, casemix_rn_hprd, casemix_total_nurse_hprd,
        casemix_weekend_total_nurse_hprd,
        adjusted_cna_hprd, adjusted_lpn_hprd, adjusted_rn_hprd, adjusted_total_nurse_hprd,
        adjusted_weekend_total_nurse_hprd,
        cycle1_survey_date, cycle1_total_health_deficiencies, cycle1_standard_health_deficiencies,
        cycle1_complaint_health_deficiencies, cycle1_health_deficiency_score,
        cycle1_health_revisits, cycle1_health_revisit_score, cycle1_total_health_score,
        cycle2_survey_date, cycle2_total_health_deficiencies, cycle2_standard_health_deficiencies,
        cycle2_complaint_health_deficiencies, cycle2_health_deficiency_score,
        cycle2_health_revisits, cycle2_health_revisit_score, cycle2_total_health_score,
        cycle3_survey_date, cycle3_total_health_deficiencies, cycle3_standard_health_deficiencies,
        cycle3_complaint_health_deficiencies, cycle3_health_deficiency_score,
        cycle3_health_revisits, cycle3_health_revisit_score, cycle3_total_health_score,
        total_weighted_health_score, facility_reported_incidents, substantiated_complaints,
        infection_control_citations, num_fines, total_fines_amount, payment_denials,
        total_penalties, location, latitude, longitude, geocoding_footnote, processing_date
    FROM (
        SELECT s.*,
               ROW_NUMBER() OVER (
                   PARTITION BY provnum, p_snapshot_date_key
                   ORDER BY p_drive_modified_at DESC, p_md5hash DESC
               ) AS rn
        FROM staging.nh_provider_info_stg s
        WHERE s.provnum IS NOT NULL
    ) s
    WHERE rn = 1;

    -- Scoped delete: snapshot_date_key confines this to the current month,
    -- and the join to this file's provnums confines it to providers this
    -- file actually describes.
    DELETE FROM silver.nh_provider_info t
    USING tmp_nh_stg_dedup s
    WHERE t.snapshot_date_key = p_snapshot_date_key
      AND t.provnum = s.provnum;

    INSERT INTO silver.nh_provider_info (
        provnum, provider_name, provider_address, city, state, zip_code,
        telephone_number, ssa_county_code, county_name, ownership_type,
        certified_beds, avg_residents_per_day, avg_residents_per_day_footnote,
        provider_type, resides_in_hospital, legal_business_name, date_first_approved,
        affiliated_entity_name, affiliated_entity_id, ccrc_status, special_focus_status,
        abuse_icon, health_inspection_over_2yrs, ownership_change_last_12mo,
        resident_family_council, sprinkler_systems_all_areas,
        overall_rating, overall_rating_footnote,
        health_inspection_rating, health_inspection_rating_footnote,
        qm_rating, qm_rating_footnote,
        longstay_qm_rating, longstay_qm_rating_footnote,
        shortstay_qm_rating, shortstay_qm_rating_footnote,
        staffing_rating, staffing_rating_footnote,
        reported_staffing_footnote, pt_staffing_footnote,
        reported_cna_hprd, reported_lpn_hprd, reported_rn_hprd, reported_licensed_hprd,
        reported_total_nurse_hprd, reported_weekend_total_nurse_hprd, reported_weekend_rn_hprd,
        reported_pt_hprd,
        total_nurse_turnover_pct, total_nurse_turnover_footnote,
        rn_turnover_pct, rn_turnover_footnote,
        administrators_left_count, administrator_turnover_footnote,
        nursing_case_mix_index, nursing_case_mix_index_ratio,
        casemix_cna_hprd, casemix_lpn_hprd, casemix_rn_hprd, casemix_total_nurse_hprd,
        casemix_weekend_total_nurse_hprd,
        adjusted_cna_hprd, adjusted_lpn_hprd, adjusted_rn_hprd, adjusted_total_nurse_hprd,
        adjusted_weekend_total_nurse_hprd,
        cycle1_survey_date, cycle1_total_health_deficiencies, cycle1_standard_health_deficiencies,
        cycle1_complaint_health_deficiencies, cycle1_health_deficiency_score,
        cycle1_health_revisits, cycle1_health_revisit_score, cycle1_total_health_score,
        cycle2_survey_date, cycle2_total_health_deficiencies, cycle2_standard_health_deficiencies,
        cycle2_complaint_health_deficiencies, cycle2_health_deficiency_score,
        cycle2_health_revisits, cycle2_health_revisit_score, cycle2_total_health_score,
        cycle3_survey_date, cycle3_total_health_deficiencies, cycle3_standard_health_deficiencies,
        cycle3_complaint_health_deficiencies, cycle3_health_deficiency_score,
        cycle3_health_revisits, cycle3_health_revisit_score, cycle3_total_health_score,
        total_weighted_health_score, facility_reported_incidents, substantiated_complaints,
        infection_control_citations, num_fines, total_fines_amount, payment_denials,
        total_penalties, location, latitude, longitude, geocoding_footnote, processing_date,
        snapshot_date_key, _source_s3_key, _drive_modified_at, _md5hash, _loaded_at
    )
    SELECT
        provnum, provider_name, provider_address, city, state, zip_code,
        telephone_number, ssa_county_code, county_name, ownership_type,
        certified_beds, avg_residents_per_day, avg_residents_per_day_footnote,
        provider_type, resides_in_hospital, legal_business_name, date_first_approved,
        affiliated_entity_name, affiliated_entity_id, ccrc_status, special_focus_status,
        abuse_icon, health_inspection_over_2yrs, ownership_change_last_12mo,
        resident_family_council, sprinkler_systems_all_areas,
        overall_rating, overall_rating_footnote,
        health_inspection_rating, health_inspection_rating_footnote,
        qm_rating, qm_rating_footnote,
        longstay_qm_rating, longstay_qm_rating_footnote,
        shortstay_qm_rating, shortstay_qm_rating_footnote,
        staffing_rating, staffing_rating_footnote,
        reported_staffing_footnote, pt_staffing_footnote,
        reported_cna_hprd, reported_lpn_hprd, reported_rn_hprd, reported_licensed_hprd,
        reported_total_nurse_hprd, reported_weekend_total_nurse_hprd, reported_weekend_rn_hprd,
        reported_pt_hprd,
        total_nurse_turnover_pct, total_nurse_turnover_footnote,
        rn_turnover_pct, rn_turnover_footnote,
        administrators_left_count, administrator_turnover_footnote,
        nursing_case_mix_index, nursing_case_mix_index_ratio,
        casemix_cna_hprd, casemix_lpn_hprd, casemix_rn_hprd, casemix_total_nurse_hprd,
        casemix_weekend_total_nurse_hprd,
        adjusted_cna_hprd, adjusted_lpn_hprd, adjusted_rn_hprd, adjusted_total_nurse_hprd,
        adjusted_weekend_total_nurse_hprd,
        cycle1_survey_date, cycle1_total_health_deficiencies, cycle1_standard_health_deficiencies,
        cycle1_complaint_health_deficiencies, cycle1_health_deficiency_score,
        cycle1_health_revisits, cycle1_health_revisit_score, cycle1_total_health_score,
        cycle2_survey_date, cycle2_total_health_deficiencies, cycle2_standard_health_deficiencies,
        cycle2_complaint_health_deficiencies, cycle2_health_deficiency_score,
        cycle2_health_revisits, cycle2_health_revisit_score, cycle2_total_health_score,
        cycle3_survey_date, cycle3_total_health_deficiencies, cycle3_standard_health_deficiencies,
        cycle3_complaint_health_deficiencies, cycle3_health_deficiency_score,
        cycle3_health_revisits, cycle3_health_revisit_score, cycle3_total_health_score,
        total_weighted_health_score, facility_reported_incidents, substantiated_complaints,
        infection_control_citations, num_fines, total_fines_amount, payment_denials,
        total_penalties, location, latitude, longitude, geocoding_footnote, processing_date,
        p_snapshot_date_key, p_s3_key, p_drive_modified_at, p_md5hash, SYSDATE
    FROM tmp_nh_stg_dedup;

    DROP TABLE tmp_nh_stg_dedup;

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
        -- Bare RAISE (re-raise as-is) needs NONATOMIC mode in Redshift;
        -- this procedure runs atomic, so re-raise explicitly instead.
        RAISE EXCEPTION '%', SQLERRM;
    END IF;
END;
$$;
