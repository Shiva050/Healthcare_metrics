"""Redshift access via the Redshift Data API (boto3) — the same async
execute/describe/poll pattern the ingestion and gold-refresh state machines
use, and the same workgroup/database/secret. No open DB port; auth is IAM +
Secrets Manager.

Per-statement latency is high (execute -> poll -> fetch), so callers push
aggregation into SQL and cache results with st.cache_data. This module only
knows how to run a statement and hand back a typed DataFrame.
"""
from __future__ import annotations

import os
import time

import boto3
import pandas as pd

try:
    import streamlit as st

    def _cfg(key: str, default: str) -> str:
        # st.secrets first (deployment), then env var, then the known-infra default.
        try:
            if key in st.secrets:
                return str(st.secrets[key])
        except Exception:
            pass
        return os.environ.get(key, default)
except Exception:  # allow importing outside a Streamlit runtime (e.g. smoke test)
    def _cfg(key: str, default: str) -> str:
        return os.environ.get(key, default)


REGION = _cfg("AWS_REGION", "us-east-1")
WORKGROUP = _cfg("REDSHIFT_WORKGROUP", "default-workgroup")
DATABASE = _cfg("REDSHIFT_DATABASE", "healthcare_metrics")
SECRET_ARN = _cfg(
    "REDSHIFT_SECRET_ARN",
    "arn:aws:secretsmanager:us-east-1:995679261492:secret:redshift!default-namespace-admin-gONVpo",
)

_POLL_SECONDS = 0.4
_NUMERIC_TYPES = {
    "int2", "int4", "int8", "smallint", "integer", "bigint",
    "float4", "float8", "real", "double", "numeric", "decimal",
}

_client = None


def _redshift_data():
    global _client
    if _client is None:
        _client = boto3.client("redshift-data", region_name=REGION)
    return _client


def _field_value(field: dict):
    if field.get("isNull"):
        return None
    for k in ("stringValue", "longValue", "doubleValue", "booleanValue"):
        if k in field:
            return field[k]
    return None


def run_query(sql: str, params: list[dict] | None = None,
              timeout_seconds: int = 120) -> pd.DataFrame:
    """Execute one SQL statement and return the result set as a DataFrame.

    params: list of {"name": ..., "value": ...} (values are stringified — the
    Data API always binds parameters as text; cast in SQL where a numeric
    comparison is needed, e.g. `month_key BETWEEN :start::int AND :end::int`).
    """
    client = _redshift_data()
    kwargs = dict(WorkgroupName=WORKGROUP, Database=DATABASE,
                  SecretArn=SECRET_ARN, Sql=sql)
    if params:
        kwargs["Parameters"] = [
            {"name": p["name"], "value": str(p["value"])} for p in params
        ]

    stmt_id = client.execute_statement(**kwargs)["Id"]

    deadline = time.time() + timeout_seconds
    while True:
        desc = client.describe_statement(Id=stmt_id)
        status = desc["Status"]
        if status in ("FINISHED", "FAILED", "ABORTED"):
            break
        if time.time() > deadline:
            raise TimeoutError(f"Redshift statement {stmt_id} timed out after {timeout_seconds}s")
        time.sleep(_POLL_SECONDS)

    if status != "FINISHED":
        raise RuntimeError(f"Redshift statement {status}: {desc.get('Error', '<no detail>')}")

    if not desc.get("HasResultSet"):
        return pd.DataFrame()

    columns: list[str] = []
    numeric_cols: set[str] = set()
    rows: list[list] = []
    next_token = None
    while True:
        page_kwargs = {"Id": stmt_id}
        if next_token:
            page_kwargs["NextToken"] = next_token
        page = client.get_statement_result(**page_kwargs)

        if not columns:
            for meta in page["ColumnMetadata"]:
                name = meta.get("label") or meta["name"]
                columns.append(name)
                if meta.get("typeName", "").lower() in _NUMERIC_TYPES:
                    numeric_cols.add(name)

        for record in page.get("Records", []):
            rows.append([_field_value(f) for f in record])

        next_token = page.get("NextToken")
        if not next_token:
            break

    df = pd.DataFrame(rows, columns=columns)
    for col in numeric_cols:
        if col in df.columns:
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df