-- Stored procedure: COPY one bronze CSV into the PBJ staging table.
--
-- Wraps the COPY in a procedure so the Step Function can invoke it as
-- `CALL staging.sp_copy_pbj_staffing(:s3_key)` with a bound parameter,
-- keeping the (Drive-filename-derived, unsanitized) s3_key out of any
-- interpolated SQL text at the Step Functions layer.
--
-- COPY's FROM clause accepts NO substitution mechanism in this Redshift
-- version — confirmed the hard way: neither Data API Parameters binding
-- ("syntax error at or near $1") nor a plain plpgsql variable referenced
-- directly in FROM (same "$1" error, this time from the query planner
-- rewriting the variable reference) work. COPY needs a literal string in
-- the SQL text at parse time. So the URI has to be assembled into dynamic
-- SQL and run via EXECUTE — and because that's string concatenation again,
-- quote_literal() is what actually closes the injection risk this time
-- (properly escaping any quote characters in p_s3_key), not parameter
-- binding.
--
-- Bucket and IAM role are hardcoded rather than taken as parameters with
-- defaults: Redshift's CREATE PROCEDURE doesn't support DEFAULT values on
-- parameters at all, and neither of these ever actually varies per call.

CREATE OR REPLACE PROCEDURE staging.sp_copy_pbj_staffing(
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

    -- Every value spliced in below goes through quote_literal() — no
    -- hand-escaped quotes.
    --
    -- ACCEPTINVCHARS: source CSVs from Drive are sometimes saved as
    -- Windows-1252/Excel-style encoding rather than UTF-8 (e.g. a curly
    -- apostrophe in a facility name lands as byte 0x92, which isn't valid
    -- UTF-8 on its own). Without this, COPY aborts the whole load on the
    -- first such byte ("String contains invalid or unsupported UTF8
    -- codepoints"). With it, the offending byte is substituted with '?' in
    -- that one field and the load proceeds — matching the same problem
    -- "Exploratory Data Analysis/load_stage_csvs.py" already works around
    -- for the Snowflake side with a WINDOWS1252 fallback file format.
    v_sql :=
        'COPY staging.pbj_daily_nurse_staffing_stg (' ||
        'provnum,provname,city,state,county_name,county_fips,cy_qtr,' ||
        'workdate,mdscensus,hrs_rndon,hrs_rndon_emp,hrs_rndon_ctr,' ||
        'hrs_rnadmin,hrs_rnadmin_emp,hrs_rnadmin_ctr,hrs_rn,hrs_rn_emp,' ||
        'hrs_rn_ctr,hrs_lpnadmin,hrs_lpnadmin_emp,hrs_lpnadmin_ctr,hrs_lpn,' ||
        'hrs_lpn_emp,hrs_lpn_ctr,hrs_cna,hrs_cna_emp,hrs_cna_ctr,hrs_natrn,' ||
        'hrs_natrn_emp,hrs_natrn_ctr,hrs_medaide,hrs_medaide_emp,hrs_medaide_ctr' ||
        ') FROM ' || quote_literal(v_s3_uri) ||
        ' IAM_ROLE ' || quote_literal(v_iam_role) ||
        ' FORMAT AS CSV IGNOREHEADER 1 BLANKSASNULL EMPTYASNULL ACCEPTINVCHARS MAXERROR 0';

    EXECUTE v_sql;
END;
$$;
