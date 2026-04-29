#!/usr/bin/env python3
"""Build container-only panel by swapping smell source in the panel builder.

Reads parsed_smells_summary_container.csv instead of parsed_smells_summary.csv,
writes panel_monthly_container_only.csv.

This is a thin wrapper that patches the input path and output path of 05_build_panel.
"""
import importlib
import sys
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[2]

# Patch the paths before importing the module
sys.path.insert(0, str(PROJECT_ROOT / "src/extraction"))

import logging

log = logging.getLogger(__name__)


def main() -> None:
    # Import the build_panel module
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "build_panel",
        PROJECT_ROOT / "src/extraction/05_build_panel.py"
    )
    mod = importlib.util.module_from_spec(spec)

    # Override the paths
    mod.PROJECT_ROOT = PROJECT_ROOT
    mod.OUTPUT = PROJECT_ROOT / "data/processed/panel_monthly_container_only.csv"

    # Load the module
    spec.loader.exec_module(mod)

    # Patch the smells path in main
    original_main = mod.main

    def patched_main():
        # We need to run the same logic but with different smell input
        # The simplest approach: just copy the original panel and recalculate
        # Actually, let's just do a direct approach
        import pandas as pd
        import numpy as np

        log.info("Building CONTAINER-ONLY panel")

        # Read original panel
        orig_panel = pd.read_csv(PROJECT_ROOT / "data/processed/panel_monthly.csv")
        log.info("Original panel: %d rows", len(orig_panel))

        # Read container-only smells
        container_smells = pd.read_csv(
            PROJECT_ROOT / "data/interim/parsed_smells_summary_container.csv"
        )
        log.info("Container-only smells: %d rows", len(container_smells))

        # Create lookup
        container_lookup = {}
        for _, row in container_smells.iterrows():
            key = (row["dir_name"], row["month"])
            container_lookup[key] = row

        # Overwrite smell columns in the panel
        new_rows = []
        for _, prow in orig_panel.iterrows():
            row_dict = prow.to_dict()
            dir_name = row_dict["repo_name"].replace("/", "__", 1)
            month = row_dict["month"]
            skey = (dir_name, month)

            if skey in container_lookup:
                sd = container_lookup[skey]
                cd = sd["cd_count"]
                ud = sd["ud_count"]
                hl = sd["hl_count"]
                gc = sd["gc_count"]
                total = sd["total_smells"]
                kloc = sd["kloc"]

                row_dict["cd_count"] = cd
                row_dict["ud_count"] = ud
                row_dict["hl_count"] = hl
                row_dict["gc_count"] = gc
                row_dict["total_smells"] = total
                # LOC and packages stay the same (already container-level)

                # Recalculate densities
                row_dict["asd"] = round(total / kloc, 6) if kloc and kloc > 0 else np.nan
                row_dict["cd_density"] = round(cd / kloc, 6) if kloc and kloc > 0 else np.nan
                row_dict["ud_density"] = round(ud / kloc, 6) if kloc and kloc > 0 else np.nan
                row_dict["hl_density"] = round(hl / kloc, 6) if kloc and kloc > 0 else np.nan
                row_dict["gc_density"] = round(gc / kloc, 6) if kloc and kloc > 0 else np.nan

            new_rows.append(row_dict)

        panel = pd.DataFrame(new_rows)
        outpath = PROJECT_ROOT / "data/processed/panel_monthly_container_only.csv"
        panel.to_csv(outpath, index=False)

        n_repos = panel["repo_id"].nunique()
        missing = panel["asd"].isna().sum()
        missing_pct = 100 * missing / len(panel) if len(panel) > 0 else 0

        log.info("=== Container-Only Panel Summary ===")
        log.info("  Rows:       %d", len(panel))
        log.info("  Repos:      %d", n_repos)
        log.info("  Missing ASD: %d (%.1f%%)", missing, missing_pct)
        log.info("  Output:     %s", outpath)

        # Compare means
        orig_asd = orig_panel["asd"].dropna().mean()
        new_asd = panel["asd"].dropna().mean()
        log.info("  ASD mean: %.3f (orig) -> %.3f (container-only)", orig_asd, new_asd)

    patched_main()


if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
    )
    main()
