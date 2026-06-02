"""Smoke tests for the shipped replication data.

Fast, dependency-light checks that the frozen panel the analysis depends on is
present and internally consistent. Run with: `uv run pytest tests/` (or `pytest`).
These guard the numbers the paper, README, and artifact abstract report.
"""

from pathlib import Path

import numpy as np
import pandas as pd
import pytest

ROOT = Path(__file__).resolve().parents[1]
PANEL = ROOT / "data" / "processed" / "panel_monthly.csv"

EXPECTED_COLUMNS = [
    "repo_id", "repo_name", "month", "month_id", "is_treatment", "first_treat_month",
    "post", "time_to_event", "cd_count", "ud_count", "hl_count", "gc_count",
    "total_smells", "num_packages", "loc", "kloc", "asd", "cd_density", "ud_density",
    "hl_density", "gc_density", "ce_mean", "ca_mean", "instability_mean",
    "distance_mean", "modularity_q", "monthly_commits", "monthly_contributors",
    "stars", "repo_age_months", "tool_type", "adoption_signal", "total_ai_events",
]


@pytest.fixture(scope="module")
def panel() -> pd.DataFrame:
    assert PANEL.exists(), f"frozen panel not found at {PANEL}"
    return pd.read_csv(PANEL)


def test_panel_shape(panel: pd.DataFrame) -> None:
    assert panel.shape == (2241, 33)


def test_expected_columns(panel: pd.DataFrame) -> None:
    assert list(panel.columns) == EXPECTED_COLUMNS


def test_repo_counts(panel: pd.DataFrame) -> None:
    assert panel["repo_id"].nunique() == 175
    by_treat = panel.groupby("is_treatment")["repo_id"].nunique().to_dict()
    assert by_treat == {0: 85, 1: 90}  # 90 treatment + 85 control matched repos


def test_analysis_subset(panel: pd.DataFrame) -> None:
    """Repos with at least one successful Arcan snapshot (non-missing ASD)."""
    sub = panel[panel["asd"].notna()]
    assert len(sub) == 1811  # successful snapshots
    by_treat = sub.groupby("is_treatment")["repo_id"].nunique().to_dict()
    assert by_treat == {0: 77, 1: 74}  # 151 analysis repos = 74 treatment + 77 control


def test_event_window(panel: pd.DataFrame) -> None:
    assert panel["time_to_event"].min() == -6
    assert panel["time_to_event"].max() == 6


def test_asd_equals_smells_per_kloc(panel: pd.DataFrame) -> None:
    sub = panel[panel["asd"].notna()]
    assert (sub["kloc"] > 0).all()
    np.testing.assert_allclose(sub["asd"], sub["total_smells"] / sub["kloc"], atol=1e-5)


def test_total_smells_is_sum_of_types(panel: pd.DataFrame) -> None:
    sub = panel[panel["asd"].notna()]
    parts = sub[["cd_count", "ud_count", "hl_count", "gc_count"]].sum(axis=1)
    assert (sub["total_smells"] == parts).all()
