"""Healthcare Metrics — Cross-Facility Nurse Staffing (regulator view).

Reads the Redshift gold star schema over the Redshift Data API. Staffing
scope only (gold.fact_daily_staffing_metrics + dim_provider + dim_date);
provider-quality metrics are out of scope until that fact is re-enabled in the
gold refresh state machine.

Layout: one month-range filter drives the (cached) server query; state /
ownership / provider-type filters are applied client-side so they're instant.
"""
from __future__ import annotations

import pandas as pd
import plotly.express as px
import plotly.graph_objects as go
import streamlit as st

import db
import queries
import theme

st.set_page_config(page_title="Nurse Staffing — Cross-Facility",
                   page_icon="🏥", layout="wide")
theme.register()

# HPRD reference bands (CMS direct-care context). Purely for outlier framing.
HPRD_LOW = 3.0      # below this = understaffed concern
HPRD_TARGET = 3.48  # CMS proposed minimum total nurse HPRD


def fmt_month(mk: int) -> str:
    mk = int(mk)
    return f"{mk // 100}-{mk % 100:02d}"


# ── Cached data loaders ─────────────────────────────────────────────────────
@st.cache_data(ttl=1800, show_spinner=False)
def load_month_bounds() -> tuple[int, int]:
    df = db.run_query(queries.month_bounds_sql())
    if df.empty or pd.isna(df.iloc[0]["min_month"]):
        return 0, 0
    return int(df.iloc[0]["min_month"]), int(df.iloc[0]["max_month"])


@st.cache_data(ttl=1800, show_spinner="Loading facility metrics…")
def load_facilities(start: int, end: int) -> pd.DataFrame:
    sql, params = queries.facility_metrics_sql()
    params = [{"name": "start", "value": start}, {"name": "end", "value": end}]
    return db.run_query(sql, params)


@st.cache_data(ttl=1800, show_spinner="Loading monthly trend…")
def load_trend(start: int, end: int) -> pd.DataFrame:
    sql, params = queries.monthly_trend_sql()
    params = [{"name": "start", "value": start}, {"name": "end", "value": end}]
    return db.run_query(sql, params)


# ── Header ──────────────────────────────────────────────────────────────────
st.title("🏥 Nurse Staffing — Cross-Facility View")
st.caption("Direct-care nurse staffing (RN + LPN + CNA) across facilities, from the "
           "Redshift gold layer. HPRD = direct-care hours per resident-day.")

min_month, max_month = load_month_bounds()
if max_month == 0:
    st.warning("No staffing data found in gold.fact_daily_staffing_metrics.")
    st.stop()

months = [m for m in range(min_month, max_month + 1) if m % 100 in range(1, 13)]
month_labels = {m: fmt_month(m) for m in months}

# ── Sidebar filters ─────────────────────────────────────────────────────────
with st.sidebar:
    st.header("Filters")
    start_mk, end_mk = st.select_slider(
        "Month range", options=months, value=(min_month, max_month),
        format_func=lambda m: month_labels[m],
    )

facilities = load_facilities(int(start_mk), int(end_mk))
if facilities.empty:
    st.warning("No facilities in the selected range.")
    st.stop()

states = sorted(facilities["state"].dropna().unique().tolist())
ownerships = sorted(facilities["ownership_type"].dropna().unique().tolist())
ptypes = sorted(facilities["provider_type"].dropna().unique().tolist())

with st.sidebar:
    sel_states = st.multiselect("State", states, default=[])
    sel_owners = st.multiselect("Ownership type", ownerships, default=[])
    sel_ptypes = st.multiselect("Provider type", ptypes, default=[])
    min_days = st.slider("Min reporting days", 0, 120, 30,
                         help="Exclude facilities with sparse data in the range.")
    st.divider()
    st.caption(f"Range: {fmt_month(start_mk)} → {fmt_month(end_mk)}")

# ── Client-side filtering (instant, no re-query) ────────────────────────────
f = facilities.copy()
if sel_states:
    f = f[f["state"].isin(sel_states)]
if sel_owners:
    f = f[f["ownership_type"].isin(sel_owners)]
if sel_ptypes:
    f = f[f["provider_type"].isin(sel_ptypes)]
f = f[f["reporting_days"] >= min_days]
f = f[f["hprd"].notna()]

if f.empty:
    st.warning("No facilities match the current filters.")
    st.stop()

# ── KPI row ─────────────────────────────────────────────────────────────────
n_fac = len(f)
n_states = f["state"].nunique()
avg_hprd = (f["hprd"] * f["avg_census"]).sum() / f["avg_census"].sum()  # census-weighted
avg_mix = (f["contract_mix"] * f["avg_census"]).sum() / f["avg_census"].sum()
# Contract reliance is hours-per-bed, so weight by beds: Σ contract hours / Σ beds.
_beds = f.loc[f["contract_reliance"].notna(), "certified_beds"]
_chrs = f.loc[f["contract_reliance"].notna(), "contract_hours_total"]
avg_reliance = _chrs.sum() / _beds.sum() if _beds.sum() else float("nan")
below_target = int((f["hprd"] < HPRD_TARGET).sum())

k1, k2, k3, k4, k5, k6 = st.columns(6)
k1.metric("Facilities", f"{n_fac:,}")
k2.metric("States", n_states)
k3.metric("Avg HPRD", f"{avg_hprd:.2f}", help="Census-weighted direct-care HPRD")
k4.metric("Avg contract mix", f"{avg_mix * 100:.1f}%",
          help="Share of direct-care hours from contract (agency) staff")
k5.metric("Contract hrs/bed", f"{avg_reliance:.1f}",
          help="Beds-weighted contract-reliance ratio: total contract "
               "direct-care hours over the period per certified bed")
k6.metric("Below CMS target", f"{below_target:,}",
          delta=f"{below_target / n_fac * 100:.0f}% of facilities",
          delta_color="inverse", help=f"HPRD < {HPRD_TARGET}")

st.divider()

tab_overview, tab_states, tab_rank, tab_trend, tab_outliers = st.tabs(
    ["Overview", "By state", "Rankings", "Trend", "Outliers"])

# ── Overview ────────────────────────────────────────────────────────────────
with tab_overview:
    c1, c2 = st.columns(2)
    with c1:
        st.subheader("HPRD distribution")
        fig = px.histogram(f, x="hprd", nbins=40)
        fig.update_traces(marker_color=theme.CATEGORICAL[0],
                          marker_line_color=theme.SURFACE, marker_line_width=1)
        fig.add_vline(x=HPRD_TARGET, line_dash="dash", line_color=theme.STATUS["critical"],
                      annotation_text="CMS target", annotation_position="top")
        fig.update_layout(xaxis_title="HPRD", yaxis_title="Facilities",
                          bargap=0.02, showlegend=False)
        st.plotly_chart(fig, use_container_width=True)
    with c2:
        st.subheader("Staffing vs. contract reliance")
        fig = px.scatter(
            f, x="hprd", y="contract_mix", size="avg_census",
            color="ownership_type", hover_name="provider_name",
            hover_data={"state": True, "hprd": ":.2f", "contract_mix": ":.1%"},
            size_max=22,
        )
        fig.update_layout(xaxis_title="HPRD", yaxis_title="Contract mix",
                          yaxis_tickformat=".0%", legend_title="Ownership")
        fig.add_vline(x=HPRD_TARGET, line_dash="dash", line_color=theme.STATUS["critical"])
        st.plotly_chart(fig, use_container_width=True)

    c3, c4 = st.columns(2)
    with c3:
        st.subheader("Contract-reliance distribution")
        rel = f["contract_reliance"].dropna()
        # Long right tail (a few very high hrs/bed) compresses the bulk; clip the
        # display at the 99th pct so the shape of the mass is readable.
        rel_clip = rel.clip(upper=rel.quantile(0.99))
        fig = px.histogram(rel_clip, nbins=40)
        fig.update_traces(marker_color=theme.CATEGORICAL[1],
                          marker_line_color=theme.SURFACE, marker_line_width=1)
        fig.update_layout(xaxis_title="Contract hrs / bed (99th-pct clipped)",
                          yaxis_title="Facilities", bargap=0.02, showlegend=False)
        st.plotly_chart(fig, use_container_width=True)
    with c4:
        st.subheader("Contract mix vs. hrs/bed")
        rel_df = f[f["contract_reliance"].notna()].copy()
        rel_df["reliance_disp"] = rel_df["contract_reliance"].clip(
            upper=rel_df["contract_reliance"].quantile(0.99))
        fig = px.scatter(
            rel_df, x="reliance_disp", y="contract_mix", size="avg_census",
            color="ownership_type", hover_name="provider_name",
            hover_data={"state": True, "contract_reliance": ":.1f",
                        "contract_mix": ":.1%", "reliance_disp": False},
            size_max=22,
        )
        fig.update_layout(xaxis_title="Contract hrs / bed", yaxis_title="Contract mix",
                          yaxis_tickformat=".0%", legend_title="Ownership")
        st.plotly_chart(fig, use_container_width=True)

# ── By state ────────────────────────────────────────────────────────────────
with tab_states:
    by_state = (
        f.assign(census_hprd=f["hprd"] * f["avg_census"],
                 census_mix=f["contract_mix"] * f["avg_census"])
        .groupby("state")
        .agg(facilities=("provnum", "size"),
             census=("avg_census", "sum"),
             census_hprd=("census_hprd", "sum"),
             census_mix=("census_mix", "sum"))
        .reset_index()
    )
    by_state["hprd"] = by_state["census_hprd"] / by_state["census"]
    by_state["contract_mix"] = by_state["census_mix"] / by_state["census"]

    st.subheader("Census-weighted HPRD by state")
    fig = px.choropleth(
        by_state, locations="state", locationmode="USA-states",
        color="hprd", scope="usa",
        color_continuous_scale=[c[1] for c in theme.SEQ_BLUE],
        hover_name="state",
        hover_data={"hprd": ":.2f", "contract_mix": ":.1%", "facilities": True},
    )
    fig.update_layout(coloraxis_colorbar_title="HPRD", margin=dict(l=0, r=0, t=8, b=0))
    st.plotly_chart(fig, use_container_width=True)

    st.dataframe(
        by_state[["state", "facilities", "hprd", "contract_mix"]]
        .sort_values("hprd").rename(columns={
            "state": "State", "facilities": "Facilities",
            "hprd": "HPRD", "contract_mix": "Contract mix"}),
        use_container_width=True, hide_index=True,
        column_config={
            "HPRD": st.column_config.NumberColumn(format="%.2f"),
            "Contract mix": st.column_config.NumberColumn(format="%.1f%%"),
        },
    )

# ── Rankings ────────────────────────────────────────────────────────────────
with tab_rank:
    cols = ["provnum", "provider_name", "state", "ownership_type", "certified_beds",
            "avg_census", "hprd", "contract_mix", "contract_reliance", "reporting_days"]
    rename = {"provnum": "CCN", "provider_name": "Facility", "state": "State",
              "ownership_type": "Ownership", "certified_beds": "Beds",
              "avg_census": "Avg census", "hprd": "HPRD",
              "contract_mix": "Contract mix", "contract_reliance": "Contract hrs/bed",
              "reporting_days": "Days"}
    colcfg = {
        "HPRD": st.column_config.NumberColumn(format="%.2f"),
        "Contract mix": st.column_config.NumberColumn(format="%.1f%%"),
        "Contract hrs/bed": st.column_config.NumberColumn(
            format="%.1f", help="Total contract direct-care hours over the period per certified bed"),
        "Avg census": st.column_config.NumberColumn(format="%.0f"),
    }
    c1, c2, c3 = st.columns(3)
    with c1:
        st.subheader("Lowest HPRD")
        st.dataframe(f.nsmallest(25, "hprd")[cols].rename(columns=rename),
                     use_container_width=True, hide_index=True, column_config=colcfg)
    with c2:
        st.subheader("Highest contract mix")
        st.dataframe(f.nlargest(25, "contract_mix")[cols].rename(columns=rename),
                     use_container_width=True, hide_index=True, column_config=colcfg)
    with c3:
        st.subheader("Highest contract hrs / bed")
        st.dataframe(f[f["contract_reliance"].notna()].nlargest(25, "contract_reliance")[cols]
                     .rename(columns=rename),
                     use_container_width=True, hide_index=True, column_config=colcfg)

# ── Trend ───────────────────────────────────────────────────────────────────
with tab_trend:
    trend = load_trend(int(start_mk), int(end_mk))
    if sel_states:
        trend = trend[trend["state"].isin(sel_states)]
    if sel_owners:
        trend = trend[trend["ownership_type"].isin(sel_owners)]

    st.subheader("System-wide monthly HPRD")
    if trend.empty:
        st.info("No trend data for the current filters.")
    else:
        monthly = (trend.groupby("month_key")
                   .agg(sum_hours=("sum_hours", "sum"),
                        sum_census=("sum_census", "sum"),
                        sum_ctr=("sum_ctr_hours", "sum"))
                   .reset_index())
        monthly["hprd"] = monthly["sum_hours"] / monthly["sum_census"]
        monthly["contract_mix"] = monthly["sum_ctr"] / monthly["sum_hours"]
        monthly["month"] = monthly["month_key"].map(fmt_month)

        fig = go.Figure()
        fig.add_trace(go.Scatter(
            x=monthly["month"], y=monthly["hprd"], mode="lines+markers",
            line=dict(color=theme.CATEGORICAL[0], width=2),
            marker=dict(size=8), name="HPRD",
            hovertemplate="%{x}<br>HPRD %{y:.2f}<extra></extra>"))
        fig.add_hline(y=HPRD_TARGET, line_dash="dash",
                      line_color=theme.STATUS["critical"],
                      annotation_text="CMS target")
        fig.update_layout(xaxis_title="Month", yaxis_title="HPRD", showlegend=False)
        st.plotly_chart(fig, use_container_width=True)

        fig2 = go.Figure()
        fig2.add_trace(go.Scatter(
            x=monthly["month"], y=monthly["contract_mix"], mode="lines+markers",
            line=dict(color=theme.CATEGORICAL[1], width=2),
            marker=dict(size=8), name="Contract mix",
            hovertemplate="%{x}<br>%{y:.1%}<extra></extra>"))
        fig2.update_layout(xaxis_title="Month", yaxis_title="Contract mix",
                           yaxis_tickformat=".0%", showlegend=False)
        st.subheader("System-wide monthly contract mix")
        st.plotly_chart(fig2, use_container_width=True)

# ── Outliers ────────────────────────────────────────────────────────────────
with tab_outliers:
    st.subheader("Understaffing & contract-reliance flags")
    flags = f.copy()
    hprd_p10 = flags["hprd"].quantile(0.10)
    mix_p90 = flags["contract_mix"].quantile(0.90)

    def classify(row):
        if row["hprd"] < HPRD_LOW:
            return "critical"
        if row["hprd"] < HPRD_TARGET or row["contract_mix"] > mix_p90:
            return "serious"
        return None

    flags["flag"] = flags.apply(classify, axis=1)
    flagged = flags[flags["flag"].notna()].sort_values("hprd")
    st.caption(f"{len(flagged):,} flagged · HPRD 10th pct = {hprd_p10:.2f} · "
               f"contract-mix 90th pct = {mix_p90 * 100:.1f}%")

    icon = {"critical": "🔴 Critical", "serious": "🟠 Serious"}
    show = flagged.assign(Flag=flagged["flag"].map(icon))[
        ["Flag", "provnum", "provider_name", "state", "ownership_type",
         "hprd", "contract_mix", "contract_reliance", "avg_census"]
    ].rename(columns={"provnum": "CCN", "provider_name": "Facility",
                      "state": "State", "ownership_type": "Ownership",
                      "hprd": "HPRD", "contract_mix": "Contract mix",
                      "contract_reliance": "Contract hrs/bed",
                      "avg_census": "Avg census"})
    st.dataframe(show, use_container_width=True, hide_index=True,
                 column_config={
                     "HPRD": st.column_config.NumberColumn(format="%.2f"),
                     "Contract mix": st.column_config.NumberColumn(format="%.1f%%"),
                     "Contract hrs/bed": st.column_config.NumberColumn(format="%.1f"),
                     "Avg census": st.column_config.NumberColumn(format="%.0f"),
                 })
