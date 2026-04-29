#!/usr/bin/env python3
"""Compute graph-level architectural metrics from Arcan CSV output.

Reads: data/raw/arcan_output/{dir_name}__{month}/arcanOutput/project/component-metrics.csv
Writes: data/interim/graph_metrics_summary.csv

Metrics computed (package-level, then averaged):
  - ce_mean: mean efferent coupling (FanOut)
  - ca_mean: mean afferent coupling (FanIn)
  - instability_mean: mean I = Ce/(Ca+Ce)
  - distance_mean: mean |A + I - 1|
  - modularity_q: NaN (requires full dependency graph, unavailable in CSV output)
"""
import csv
import logging
import random
from pathlib import Path

import numpy as np
import yaml
from tqdm import tqdm

PROJECT_ROOT = Path(__file__).resolve().parents[2]
cfg = yaml.safe_load((PROJECT_ROOT / "config/config.yaml").read_text())
random.seed(cfg["study"]["seed"])
np.random.seed(cfg["study"]["seed"])

log_dir = PROJECT_ROOT / cfg["paths"]["logs"]
log_dir.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(log_dir / "04_compute_metrics.log"),
    ],
)
log = logging.getLogger(__name__)

ARCAN_OUT = PROJECT_ROOT / "data/raw/arcan_output"
OUTPUT = PROJECT_ROOT / "data/interim/graph_metrics_summary.csv"


def parse_snapshot_id(dirname: str) -> tuple[str, str]:
    parts = dirname.split("__")
    month = parts[-1]
    dir_name = "__".join(parts[:-1])
    return dir_name, month


def find_component_metrics(snapshot_dir: Path) -> Path | None:
    arcan_subdir = snapshot_dir / "arcanOutput"
    if not arcan_subdir.is_dir():
        return None
    for sub in arcan_subdir.iterdir():
        if sub.is_dir():
            f = sub / "component-metrics.csv"
            if f.exists():
                return f
    return None


def compute_metrics(comp_file: Path) -> dict:
    """Compute aggregated metrics from component-metrics.csv (packages only)."""
    ce_vals: list[float] = []
    ca_vals: list[float] = []
    i_vals: list[float] = []
    d_vals: list[float] = []

    with open(comp_file) as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("vertexLabel") != "container":
                continue

            try:
                ce = float(row.get("FanOut", 0))
                ca = float(row.get("FanIn", 0))
                instability = float(row.get("InstabilityMetric", 0))
                abstractness = float(row.get("AbstractnessMetric", 0))
            except (ValueError, TypeError):
                continue

            ce_vals.append(ce)
            ca_vals.append(ca)
            i_vals.append(instability)
            d_vals.append(abs(abstractness + instability - 1.0))

    if not ce_vals:
        return {
            "ce_mean": 0.0, "ca_mean": 0.0,
            "instability_mean": 0.0, "distance_mean": 0.0,
            "modularity_q": np.nan,
        }

    return {
        "ce_mean": round(float(np.mean(ce_vals)), 4),
        "ca_mean": round(float(np.mean(ca_vals)), 4),
        "instability_mean": round(float(np.mean(i_vals)), 4),
        "distance_mean": round(float(np.mean(d_vals)), 4),
        "modularity_q": np.nan,  # Requires full dependency graph (not in CSV)
    }


def main() -> None:
    log.info("Computing graph metrics from %s", ARCAN_OUT)

    snapshot_dirs = sorted(
        d for d in ARCAN_OUT.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )
    log.info("Found %d snapshot directories", len(snapshot_dirs))

    rows: list[dict] = []
    skipped = 0

    for snap_dir in tqdm(snapshot_dirs, desc="Computing metrics"):
        dir_name, month = parse_snapshot_id(snap_dir.name)
        repo_name = dir_name.replace("__", "/", 1)

        comp_file = find_component_metrics(snap_dir)
        if comp_file is None:
            skipped += 1
            continue

        try:
            metrics = compute_metrics(comp_file)
        except Exception as e:
            log.error("Failed on %s: %s", snap_dir.name, e)
            skipped += 1
            continue

        rows.append({"repo_name": repo_name, "dir_name": dir_name, "month": month, **metrics})

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "repo_name", "dir_name", "month",
        "ce_mean", "ca_mean", "instability_mean", "distance_mean", "modularity_q",
    ]
    with open(OUTPUT, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    log.info("Wrote %d rows to %s (skipped %d)", len(rows), OUTPUT, skipped)


if __name__ == "__main__":
    main()
