"""SQL against the Redshift gold star schema (staffing scope only).

Reads gold.fact_daily_staffing_metrics + gold.dim_provider + gold.dim_date.
The gold fact carries raw building blocks only (mdscensus, total /
contract_direct_care_hours), so the reporting math lives here:

    HPRD (hours per resident-day) = SUM(total_direct_care_hours) / SUM(mdscensus)
    contract mix %                = SUM(contract_direct_care_hours) / SUM(total_direct_care_hours)
    contract reliance (hrs/bed)   = SUM(contract_direct_care_hours) / certified_beds

HPRD and contract mix are properly weighted ratios-of-sums over the period, not
averages of daily ratios. For contract reliance, certified_beds is a per-facility
scalar from the prov CTE (one row per provnum) — it is NEVER summed across the
day-grain fact, which would multiply it by the number of days; only the contract
hours are summed. Descriptive attributes (name, state, ownership, ...) come from
each provider's LATEST dim_provider row (the current SCD2 version), excluding
the -1 'UNKNOWN' sentinel member.

Only the month range parameterizes the server query; state / ownership /
provider-type filtering is done client-side in pandas so it never re-hits the
Data API.
"""
from __future__ import annotations

# One row per provnum: the provider's most recent descriptive attributes.
# ROW_NUMBER over month_key DESC picks the latest snapshot; the UNKNOWN
# sentinel (provnum 'UNKNOWN', month_key 0) is excluded.
_PROV_CTE = """
WITH prov AS (
    SELECT provnum, provider_name, state, county_name,
           ownership_type, provider_type, certified_beds
    FROM (
        SELECT provnum, provider_name, state, county_name,
               ownership_type, provider_type, certified_beds,
               ROW_NUMBER() OVER (PARTITION BY provnum ORDER BY month_key DESC) AS rn
        FROM gold.dim_provider
        WHERE provnum <> 'UNKNOWN'
    )
    WHERE rn = 1
)
"""


def month_bounds_sql() -> str:
    """Min/max month_key present in the staffing fact — drives the range slider."""
    return """
    SELECT MIN(month_key) AS min_month, MAX(month_key) AS max_month
    FROM gold.fact_daily_staffing_metrics
    """


def facility_metrics_sql() -> tuple[str, list[dict]]:
    """Per-facility staffing metrics aggregated over [:start, :end] (month_key).

    Returns provider attributes + weighted HPRD, contract mix, avg census, and
    reporting-day count. One row per provider. Filtering by state/ownership/etc.
    is left to the caller (pandas).
    """
    sql = _PROV_CTE + """
    , agg AS (
        SELECT provnum,
               COUNT(*)                          AS reporting_days,
               AVG(mdscensus::float)             AS avg_census,
               SUM(mdscensus)                    AS sum_census,
               SUM(total_direct_care_hours)      AS sum_hours,
               SUM(contract_direct_care_hours)   AS sum_ctr_hours
        FROM gold.fact_daily_staffing_metrics
        WHERE month_key BETWEEN :start::int AND :end::int
        GROUP BY provnum
    )
    SELECT a.provnum,
           p.provider_name,
           p.state,
           p.county_name,
           p.ownership_type,
           p.provider_type,
           p.certified_beds,
           a.reporting_days,
           a.avg_census,
           a.sum_ctr_hours                                     AS contract_hours_total,
           CASE WHEN a.sum_census > 0
                THEN a.sum_hours / a.sum_census END           AS hprd,
           CASE WHEN a.sum_hours > 0
                THEN a.sum_ctr_hours / a.sum_hours END         AS contract_mix,
           -- Contract-reliance ratio: total contract hours over the period per
           -- certified bed. certified_beds comes from the one-row-per-provnum
           -- prov CTE (a scalar per facility) so it is NEVER summed across the
           -- day-grain fact rows — only the hours are summed.
           CASE WHEN p.certified_beds > 0
                THEN a.sum_ctr_hours::float / p.certified_beds END AS contract_reliance
    FROM agg a
    LEFT JOIN prov p ON p.provnum = a.provnum
    """
    return sql, [{"name": "start", "value": ""}, {"name": "end", "value": ""}]


def monthly_trend_sql() -> tuple[str, list[dict]]:
    """Monthly HPRD / contract-mix rolled up by state + ownership over the range.

    Grain months x states x ownership types is small (~thousands of rows), so
    the caller can filter by state/ownership client-side and re-aggregate to a
    system-wide or per-state monthly trend without another round trip.
    """
    sql = _PROV_CTE + """
    SELECT f.month_key,
           p.state,
           p.ownership_type,
           SUM(f.mdscensus)                    AS sum_census,
           SUM(f.total_direct_care_hours)      AS sum_hours,
           SUM(f.contract_direct_care_hours)   AS sum_ctr_hours
    FROM gold.fact_daily_staffing_metrics f
    LEFT JOIN prov p ON p.provnum = f.provnum
    WHERE f.month_key BETWEEN :start::int AND :end::int
    GROUP BY f.month_key, p.state, p.ownership_type
    ORDER BY f.month_key
    """
    return sql, [{"name": "start", "value": ""}, {"name": "end", "value": ""}]
