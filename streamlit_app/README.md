# Nurse Staffing — Cross-Facility Streamlit app

Regulator-facing dashboard over the Redshift **gold** star schema. Staffing
scope only (`gold.fact_daily_staffing_metrics` + `gold.dim_provider` +
`gold.dim_date`). Reads via the **Redshift Data API** (boto3) — the same
workgroup/database/secret the ingestion and gold-refresh state machines use, so
there's no open database port.

## Metrics

The gold fact carries raw building blocks only, so ratios are derived in the app:

- **HPRD** (hours per resident-day) = `SUM(total_direct_care_hours) / SUM(mdscensus)` — direct-care nurses (RN + LPN + CNA), weighted ratio-of-sums over the selected months.
- **Contract mix %** = `SUM(contract_direct_care_hours) / SUM(total_direct_care_hours)` — share of hours from agency/contract staff.

Descriptive attributes come from each provider's latest `dim_provider` SCD2
version (the `-1` UNKNOWN sentinel is excluded).

## Run

```bash
cd streamlit_app
pip install -r requirements.txt
# AWS creds via env / ~/.aws / IAM role, with redshift-data + secretsmanager access
streamlit run app.py
```

Config is optional — defaults match the live infra. Override via
`.streamlit/secrets.toml` (see `secrets.toml.example`) or env vars:
`AWS_REGION`, `REDSHIFT_WORKGROUP`, `REDSHIFT_DATABASE`, `REDSHIFT_SECRET_ARN`.

## Design notes

- Only the **month-range** filter hits Redshift (cached 30 min per range).
  State / ownership / provider-type filters run client-side in pandas, so they're
  instant and don't re-query.
- Tabs: Overview (HPRD distribution, staffing-vs-contract scatter), By state
  (choropleth + table), Rankings (lowest HPRD / highest contract reliance),
  Trend (monthly system-wide), Outliers (understaffing flags).
- Quality metrics (`fact_provider_quality_metrics`) are intentionally excluded —
  that fact isn't refreshed by the live gold state machine yet.