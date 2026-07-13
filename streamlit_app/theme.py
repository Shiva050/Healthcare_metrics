"""Chart theme — validated, colorblind-safe palette (dataviz skill reference
instance, light surface) plus a Plotly template so every figure reads as one
system: fixed-order categorical hues (never cycled), a single-hue blue
sequential ramp for magnitude (choropleth), and reserved status colors for
outlier flags.
"""
from __future__ import annotations

import plotly.graph_objects as go
import plotly.io as pio

# ── Categorical hues, in fixed order (assign by slot, never cycle) ──────────
CATEGORICAL = [
    "#2a78d6",  # 1 blue
    "#1baf7a",  # 2 aqua
    "#eda100",  # 3 yellow
    "#008300",  # 4 green
    "#4a3aa7",  # 5 violet
    "#e34948",  # 6 red
    "#e87ba4",  # 7 magenta
    "#eb6834",  # 8 orange
]

# ── Sequential blue ramp (continuous magnitude: choropleth / heat) ──────────
SEQ_BLUE = [
    [0.0, "#cde2fb"],
    [0.25, "#86b6ef"],
    [0.5, "#3987e5"],
    [0.75, "#1c5cab"],
    [1.0, "#0d366b"],
]

# ── Status (reserved — never reused as a series color) ──────────────────────
STATUS = {
    "good": "#0ca30c",
    "warning": "#fab219",
    "serious": "#ec835a",
    "critical": "#d03b3b",
}

# ── Ink / chrome (light surface) ────────────────────────────────────────────
SURFACE = "#fcfcfb"
INK_PRIMARY = "#0b0b0b"
INK_SECONDARY = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
BASELINE = "#c3c2b7"

FONT_FAMILY = 'system-ui, -apple-system, "Segoe UI", sans-serif'


def _template() -> go.layout.Template:
    t = go.layout.Template()
    t.layout = go.Layout(
        colorway=CATEGORICAL,
        font=dict(family=FONT_FAMILY, color=INK_PRIMARY, size=13),
        paper_bgcolor=SURFACE,
        plot_bgcolor=SURFACE,
        title=dict(font=dict(size=16, color=INK_PRIMARY)),
        margin=dict(l=56, r=24, t=48, b=48),
        xaxis=dict(
            gridcolor=GRID, zerolinecolor=BASELINE, linecolor=BASELINE,
            tickcolor=MUTED, tickfont=dict(color=INK_SECONDARY, size=12),
            title=dict(font=dict(color=INK_SECONDARY, size=12)),
        ),
        yaxis=dict(
            gridcolor=GRID, zerolinecolor=BASELINE, linecolor=BASELINE,
            tickcolor=MUTED, tickfont=dict(color=INK_SECONDARY, size=12),
            title=dict(font=dict(color=INK_SECONDARY, size=12)),
        ),
        legend=dict(font=dict(color=INK_SECONDARY, size=12), bgcolor="rgba(0,0,0,0)"),
        hoverlabel=dict(font=dict(family=FONT_FAMILY, size=12)),
    )
    return t


def register() -> None:
    """Register + activate the 'healthcare' Plotly template. Call once at startup."""
    pio.templates["healthcare"] = _template()
    pio.templates.default = "plotly_white+healthcare"
