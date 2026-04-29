#!/usr/bin/env python3
"""Parse Arcan CSV outputs - CONTAINER-level (package) smells only.

Variant of 03_parse_arcan_output.py that filters to AffectedComponentType == 'CONTAINER',
excluding class-level (UNIT) smells. This produces a package-architecture-only panel
for sensitivity analysis.

Reads: data/raw/arcan_output/{dir_name}__{month}/arcanOutput/project/
Writes: data/interim/parsed_smells_summary_container.csv
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
        logging.FileHandler(log_dir / "03b_parse_container_only.log"),
    ],
)
log = logging.getLogger(__name__)

ARCAN_OUT = PROJECT_ROOT / "data/raw/arcan_output"
OUTPUT = PROJECT_ROOT / "data/interim/parsed_smells_summary_container.csv"

SMELL_MAP: dict[str, str] = {
    "cyclicdep": "cd",
    "hublikedep": "hl",
    "unstabledep": "ud",
    "godcomponent": "gc",
}


def parse_snapshot_id(dirname: str) -> tuple[str, str]:
    parts = dirname.split("__")
    month = parts[-1]
    dir_name = "__".join(parts[:-1])
    return dir_name, month


def find_arcan_csvs(snapshot_dir: Path) -> Path | None:
    arcan_subdir = snapshot_dir / "arcanOutput"
    if not arcan_subdir.is_dir():
        return None
    for sub in arcan_subdir.iterdir():
        if sub.is_dir() and (
            (sub / "smell-characteristics.csv").exists()
            or (sub / "component-metrics.csv").exists()
        ):
            return sub
    return None


def parse_snapshot(csv_dir: Path) -> dict:
    """Extract CONTAINER-level smell counts and package stats from Arcan CSV output."""
    smells = {"cd": 0, "ud": 0, "hl": 0, "gc": 0}
    num_packages = 0
    total_loc = 0

    # Parse smell counts - CONTAINER only
    smell_file = csv_dir / "smell-characteristics.csv"
    if smell_file.exists():
        with open(smell_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                # FILTER: only package-level smells
                if row.get("AffectedComponentType") != "CONTAINER":
                    continue
                smell_type = row.get("smellType", "").lower().replace("_", "")
                mapped = SMELL_MAP.get(smell_type)
                if mapped:
                    smells[mapped] += 1

    # Parse package stats (same as original - already container-only)
    comp_file = csv_dir / "component-metrics.csv"
    if comp_file.exists():
        with open(comp_file) as f:
            reader = csv.DictReader(f)
            for row in reader:
                if row.get("vertexLabel") == "container":
                    num_packages += 1
                    try:
                        total_loc += int(float(row.get("LinesOfCode", 0)))
                    except (ValueError, TypeError):
                        pass

    total = sum(smells.values())
    kloc = total_loc / 1000.0
    return {
        "cd_count": smells["cd"],
        "ud_count": smells["ud"],
        "hl_count": smells["hl"],
        "gc_count": smells["gc"],
        "total_smells": total,
        "num_packages": num_packages,
        "loc": total_loc,
        "kloc": round(kloc, 3),
    }


def main() -> None:
    log.info("Parsing CONTAINER-only smells from %s", ARCAN_OUT)

    snapshot_dirs = sorted(
        d for d in ARCAN_OUT.iterdir()
        if d.is_dir() and not d.name.startswith(".")
    )
    log.info("Found %d snapshot directories", len(snapshot_dirs))

    rows: list[dict] = []
    skipped = 0

    for snap_dir in tqdm(snapshot_dirs, desc="Parsing container smells"):
        dir_name, month = parse_snapshot_id(snap_dir.name)
        repo_name = dir_name.replace("__", "/", 1)

        csv_dir = find_arcan_csvs(snap_dir)
        if csv_dir is None:
            skipped += 1
            continue

        try:
            metrics = parse_snapshot(csv_dir)
        except Exception as e:
            log.error("Failed to parse %s: %s", snap_dir.name, e)
            skipped += 1
            continue

        rows.append({"repo_name": repo_name, "dir_name": dir_name, "month": month, **metrics})

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "repo_name", "dir_name", "month",
        "cd_count", "ud_count", "hl_count", "gc_count", "total_smells",
        "num_packages", "loc", "kloc",
    ]
    with open(OUTPUT, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    log.info("Wrote %d rows to %s (skipped %d)", len(rows), OUTPUT, skipped)

    # Quick comparison with original
    orig = PROJECT_ROOT / "data/interim/parsed_smells_summary.csv"
    if orig.exists():
        import pandas as pd
        df_orig = pd.read_csv(orig)
        df_cont = pd.read_csv(OUTPUT)
        log.info("=== Container-only vs Original ===")
        for col in ["cd_count", "ud_count", "hl_count", "gc_count", "total_smells"]:
            orig_sum = df_orig[col].sum()
            cont_sum = df_cont[col].sum()
            pct = 100 * cont_sum / orig_sum if orig_sum > 0 else 0
            log.info("  %s: %d -> %d (%.1f%% retained)", col, orig_sum, cont_sum, pct)


if __name__ == "__main__":
    main()
