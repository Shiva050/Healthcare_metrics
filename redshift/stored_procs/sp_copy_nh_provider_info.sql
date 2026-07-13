-- Stored procedure: COPY one bronze NH Provider Info CSV into staging.
--
-- Wraps the COPY in a procedure so the Step Function can invoke it as
-- `CALL staging.sp_copy_nh_provider_info(:s3_key)` with a bound parameter,
-- keeping the (filename-derived, unsanitized) s3_key out of any
-- interpolated SQL text at the Step Functions layer.
--
-- Same COPY-can't-take-bound-parameters constraint as sp_copy_pbj_staffing:
-- the S3 URI has to be assembled into dynamic SQL and run via EXECUTE, with
-- quote_literal() closing the injection risk.
--
-- Bucket and IAM role are hardcoded for the same reason as the PBJ copy proc:
-- Redshift's CREATE PROCEDURE doesn't support parameter defaults, and neither
-- value varies per call.

CREATE OR REPLACE PROCEDURE staging.sp_copy_nh_provider_info(
    p_s3_key VARCHAR(1024)
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_s3_uri   VARCHAR(1280);
    v_iam_role VARCHAR(512) := 'arn:aws:iam::995679261492:role/service-role/AmazonRedshift-CommandsAccessRole-20260706T161330';
    v_sql      VARCHAR(65535);
BEGIN
    v_s3_uri := 's3://health-care-metrics-prj-bronze/' || p_s3_key;

    -- ACCEPTINVCHARS: same Windows-1252/Excel-export encoding issue as the
    -- PBJ CSVs (e.g. curly apostrophes in facility names).
    v_sql :=
        'COPY staging.nh_provider_info_stg (' ||
        'provnum,provider_name,provider_address,city,state,zip_code,' ||
        'telephone_number,ssa_county_code,county_name,ownership_type,' ||
        'certified_beds,avg_residents_per_day,avg_residents_per_day_footnote,' ||
        'provider_type,resides_in_hospital,legal_business_name,date_first_approved,' ||
        'affiliated_entity_name,affiliated_entity_id,ccrc_status,special_focus_status,' ||
        'abuse_icon,health_inspection_over_2yrs,ownership_change_last_12mo,' ||
        'resident_family_council,sprinkler_systems_all_areas,' ||
        'overall_rating,overall_rating_footnote,' ||
        'health_inspection_rating,health_inspection_rating_footnote,' ||
        'qm_rating,qm_rating_footnote,' ||
        'longstay_qm_rating,longstay_qm_rating_footnote,' ||
        'shortstay_qm_rating,shortstay_qm_rating_footnote,' ||
        'staffing_rating,staffing_rating_footnote,' ||
        'reported_staffing_footnote,pt_staffing_footnote,' ||
        'reported_cna_hprd,reported_lpn_hprd,reported_rn_hprd,reported_licensed_hprd,' ||
        'reported_total_nurse_hprd,reported_weekend_total_nurse_hprd,reported_weekend_rn_hprd,' ||
        'reported_pt_hprd,' ||
        'total_nurse_turnover_pct,total_nurse_turnover_footnote,' ||
        'rn_turnover_pct,rn_turnover_footnote,' ||
        'administrators_left_count,administrator_turnover_footnote,' ||
        'nursing_case_mix_index,nursing_case_mix_index_ratio,' ||
        'casemix_cna_hprd,casemix_lpn_hprd,casemix_rn_hprd,casemix_total_nurse_hprd,' ||
        'casemix_weekend_total_nurse_hprd,' ||
        'adjusted_cna_hprd,adjusted_lpn_hprd,adjusted_rn_hprd,adjusted_total_nurse_hprd,' ||
        'adjusted_weekend_total_nurse_hprd,' ||
        'cycle1_survey_date,cycle1_total_health_deficiencies,cycle1_standard_health_deficiencies,' ||
        'cycle1_complaint_health_deficiencies,cycle1_health_deficiency_score,' ||
        'cycle1_health_revisits,cycle1_health_revisit_score,cycle1_total_health_score,' ||
        'cycle2_survey_date,cycle2_total_health_deficiencies,cycle2_standard_health_deficiencies,' ||
        'cycle2_complaint_health_deficiencies,cycle2_health_deficiency_score,' ||
        'cycle2_health_revisits,cycle2_health_revisit_score,cycle2_total_health_score,' ||
        'cycle3_survey_date,cycle3_total_health_deficiencies,cycle3_standard_health_deficiencies,' ||
        'cycle3_complaint_health_deficiencies,cycle3_health_deficiency_score,' ||
        'cycle3_health_revisits,cycle3_health_revisit_score,cycle3_total_health_score,' ||
        'total_weighted_health_score,facility_reported_incidents,substantiated_complaints,' ||
        'infection_control_citations,num_fines,total_fines_amount,payment_denials,' ||
        'total_penalties,location,latitude,longitude,geocoding_footnote,processing_date' ||
        ') FROM ' || quote_literal(v_s3_uri) ||
        ' IAM_ROLE ' || quote_literal(v_iam_role) ||
        ' FORMAT AS CSV IGNOREHEADER 1 BLANKSASNULL EMPTYASNULL ACCEPTINVCHARS MAXERROR 0';

    EXECUTE v_sql;
END;
$$;
