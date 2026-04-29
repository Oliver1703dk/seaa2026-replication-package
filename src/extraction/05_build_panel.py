#!/usr/bin/env python3
"""Build the final panel dataset by merging smells, metrics, and controls.

Reads:
  - data/processed/matching.csv
  - config/repo_lists/treatment_final.csv
  - data/processed/repo_characteristics.csv
  - data/interim/snapshot_manifest.csv
  - data/interim/parsed_smells_summary.csv
  - data/interim/graph_metrics_summary.csv

Writes:
  - data/processed/panel_monthly.csv
"""
import logging
import random
import subprocess
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd
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
        logging.FileHandler(log_dir / "05_build_panel.log"),
    ],
)
log = logging.getLogger(__name__)

REPOS_DIR = PROJECT_ROOT / "repos"
OUTPUT = PROJECT_ROOT / "data/processed/panel_monthly.csv"


def month_to_int(ym: str) -> int:
    """Convert YYYY-MM to integer months since epoch (for month_id)."""
    year, month = ym.split("-")
    return int(year) * 12 + int(month)


def get_monthly_git_stats(repo_path: Path, months: list[str]) -> dict[str, dict]:
    """Get monthly commit count and contributor count from git log.

    Returns dict[month_str -> {"commits": int, "contributors": int}].
    """
    stats: dict[str, dict] = {m: {"commits": 0, "contributors": 0} for m in months}

    if not repo_path.is_dir():
        return stats

    try:
        result = subprocess.run(
            ["git", "-C", str(repo_path), "log", "--format=%aI|%ae"],
            capture_output=True, text=True, timeout=30,
        )
        if result.returncode != 0:
            return stats
    except (subprocess.TimeoutExpired, Exception):
        return stats

    # Parse and bin by month
    monthly_authors: dict[str, set] = defaultdict(set)
    monthly_commits: dict[str, int] = defaultdict(int)

    for line in result.stdout.strip().split("\n"):
        if not line or "|" not in line:
            continue
        date_str, author = line.split("|", 1)
        ym = date_str[:7]  # YYYY-MM
        monthly_commits[ym] += 1
        monthly_authors[ym].add(author)

    for m in months:
        stats[m]["commits"] = monthly_commits.get(m, 0)
        stats[m]["contributors"] = len(monthly_authors.get(m, set()))

    return stats


def main() -> None:
    log.info("Building panel dataset")

    # --- Load matching pairs ---
    matching = pd.read_csv(PROJECT_ROOT / "data/processed/matching.csv")
    log.info("Loaded %d matched pairs", len(matching))

    # --- Load treatment adoption info ---
    treatment_df = pd.read_csv(PROJECT_ROOT / "config/repo_lists/treatment_final.csv")
    adoption_dates: dict[str, str] = {}
    tool_meta: dict[str, dict] = {}
    for _, row in treatment_df.iterrows():
        adoption_dates[row["full_name"]] = row["adoption_date"][:7]  # YYYY-MM
        # Tool metadata for heterogeneity analyses
        ai_events_raw = row.get("total_ai_events", 0)
        tool_meta[row["full_name"]] = {
            "tool_type": str(row.get("markers", "unknown")),
            "adoption_signal": str(row.get("adoption_signal", "unknown")),
            "total_ai_events": int(ai_events_raw)
                if str(ai_events_raw).isdigit() else 0,
        }

    # --- Load repo characteristics (time-invariant controls) ---
    repo_chars_path = PROJECT_ROOT / "data/processed/repo_characteristics.csv"
    repo_chars: dict[str, dict] = {}
    if repo_chars_path.exists():
        rc_df = pd.read_csv(repo_chars_path)
        for _, row in rc_df.iterrows():
            repo_chars[row["full_name"]] = {
                "stars": row.get("stars", np.nan),
                "repo_age_months": row.get("repo_age_months", np.nan),
            }

    # --- Load snapshot manifest ---
    manifest = pd.read_csv(PROJECT_ROOT / "data/interim/snapshot_manifest.csv")
    manifest_found = manifest[manifest["status"] == "found"]
    log.info("Manifest: %d total, %d found", len(manifest), len(manifest_found))

    # --- Load smell summary ---
    smells_path = PROJECT_ROOT / "data/interim/parsed_smells_summary.csv"
    smells_lookup: dict[tuple[str, str], dict] = {}
    if smells_path.exists():
        smells_df = pd.read_csv(smells_path)
        for _, row in smells_df.iterrows():
            key = (row["dir_name"], row["month"])
            smells_lookup[key] = row.to_dict()
        log.info("Loaded %d smell records", len(smells_lookup))
    else:
        log.warning("No parsed smells summary found at %s", smells_path)

    # --- Load graph metrics summary ---
    metrics_path = PROJECT_ROOT / "data/interim/graph_metrics_summary.csv"
    metrics_lookup: dict[tuple[str, str], dict] = {}
    if metrics_path.exists():
        metrics_df = pd.read_csv(metrics_path)
        for _, row in metrics_df.iterrows():
            key = (row["dir_name"], row["month"])
            metrics_lookup[key] = row.to_dict()
        log.info("Loaded %d metric records", len(metrics_lookup))
    else:
        log.warning("No graph metrics summary found at %s", metrics_path)

    # --- Compute monthly git stats for all repos ---
    log.info("Computing monthly git stats for %d repos ...", len(matching) * 2)
    all_repos = set()
    repo_months: dict[str, list[str]] = defaultdict(list)

    for _, mrow in manifest_found.iterrows():
        dn = mrow["dir_name"]
        all_repos.add(dn)
        repo_months[dn].append(mrow["month"])

    git_stats: dict[str, dict[str, dict]] = {}
    for dn in tqdm(sorted(all_repos), desc="Git stats"):
        repo_path = REPOS_DIR / dn
        months = sorted(set(repo_months[dn]))
        git_stats[dn] = get_monthly_git_stats(repo_path, months)

    # --- Build panel rows ---
    log.info("Assembling panel rows ...")
    panel_rows: list[dict] = []
    repo_id_map: dict[str, int] = {}
    next_id = 1

    for _, mrow in matching.iterrows():
        treatment_repo = mrow["treatment_repo"]
        control_repo = mrow["control_repo"]
        first_treat = adoption_dates.get(treatment_repo, "")

        if not first_treat:
            log.warning("No adoption date for %s", treatment_repo)
            continue

        first_treat_int = month_to_int(first_treat)

        for repo, is_treatment in [(treatment_repo, 1), (control_repo, 0)]:
            dir_name = repo.replace("/", "__", 1)

            if repo not in repo_id_map:
                repo_id_map[repo] = next_id
                next_id += 1
            rid = repo_id_map[repo]

            # Time-invariant controls
            rc = repo_chars.get(repo, {})
            stars = rc.get("stars", np.nan)
            repo_age = rc.get("repo_age_months", np.nan)

            # Get the months for this repo from manifest
            repo_manifest = manifest[
                (manifest["dir_name"] == dir_name) & (manifest["status"] == "found")
            ]

            for _, snap in repo_manifest.iterrows():
                month = snap["month"]
                month_int = month_to_int(month)
                time_to_event = month_int - first_treat_int
                post = 1 if time_to_event >= 0 else 0

                # Smell data
                skey = (dir_name, month)
                sd = smells_lookup.get(skey, {})
                cd = sd.get("cd_count", np.nan)
                ud = sd.get("ud_count", np.nan)
                hl = sd.get("hl_count", np.nan)
                gc = sd.get("gc_count", np.nan)
                total_smells = sd.get("total_smells", np.nan)
                num_packages = sd.get("num_packages", np.nan)
                loc = sd.get("loc", np.nan)
                kloc = sd.get("kloc", np.nan)

                # Densities (per KLOC)
                asd = total_smells / kloc if kloc and kloc > 0 else np.nan
                cd_density = cd / kloc if kloc and kloc > 0 else np.nan
                ud_density = ud / kloc if kloc and kloc > 0 else np.nan
                hl_density = hl / kloc if kloc and kloc > 0 else np.nan
                gc_density = gc / kloc if kloc and kloc > 0 else np.nan

                # Graph metrics
                md = metrics_lookup.get(skey, {})
                ce_mean = md.get("ce_mean", np.nan)
                ca_mean = md.get("ca_mean", np.nan)
                i_mean = md.get("instability_mean", np.nan)
                d_mean = md.get("distance_mean", np.nan)
                q = md.get("modularity_q", np.nan)

                # Time-varying controls from git
                gs = git_stats.get(dir_name, {}).get(month, {})
                monthly_commits = gs.get("commits", 0)
                monthly_contributors = gs.get("contributors", 0)

                panel_rows.append({
                    "repo_id": rid,
                    "repo_name": repo,
                    "month": month,
                    "month_id": month_int,
                    "is_treatment": is_treatment,
                    "first_treat_month": first_treat,
                    "post": post,
                    "time_to_event": time_to_event,
                    "cd_count": cd,
                    "ud_count": ud,
                    "hl_count": hl,
                    "gc_count": gc,
                    "total_smells": total_smells,
                    "num_packages": num_packages,
                    "loc": loc,
                    "kloc": kloc,
                    "asd": round(asd, 6) if not np.isnan(asd) else np.nan,
                    "cd_density": round(cd_density, 6) if not np.isnan(cd_density) else np.nan,
                    "ud_density": round(ud_density, 6) if not np.isnan(ud_density) else np.nan,
                    "hl_density": round(hl_density, 6) if not np.isnan(hl_density) else np.nan,
                    "gc_density": round(gc_density, 6) if not np.isnan(gc_density) else np.nan,
                    "ce_mean": ce_mean,
                    "ca_mean": ca_mean,
                    "instability_mean": i_mean,
                    "distance_mean": d_mean,
                    "modularity_q": q,
                    "monthly_commits": monthly_commits,
                    "monthly_contributors": monthly_contributors,
                    "stars": stars,
                    "repo_age_months": repo_age,
                    # Tool metadata (treatment repos only)
                    "tool_type": tool_meta.get(repo, {}).get("tool_type", "control")
                        if is_treatment else "control",
                    "adoption_signal": tool_meta.get(repo, {}).get("adoption_signal", None)
                        if is_treatment else None,
                    "total_ai_events": tool_meta.get(repo, {}).get("total_ai_events", 0)
                        if is_treatment else 0,
                })

    # --- Write output ---
    panel = pd.DataFrame(panel_rows)
    panel = panel.sort_values(["repo_id", "month"]).reset_index(drop=True)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    panel.to_csv(OUTPUT, index=False)

    # --- Validation ---
    n_repos = panel["repo_id"].nunique()
    n_treatment = panel[panel["is_treatment"] == 1]["repo_id"].nunique()
    n_control = panel[panel["is_treatment"] == 0]["repo_id"].nunique()
    tte_range = (panel["time_to_event"].min(), panel["time_to_event"].max())
    missing_asd = panel["asd"].isna().sum()
    missing_pct = 100 * missing_asd / len(panel) if len(panel) > 0 else 0

    log.info("=== Panel Summary ===")
    log.info("  Rows:       %d", len(panel))
    log.info("  Repos:      %d (treatment=%d, control=%d)", n_repos, n_treatment, n_control)
    log.info("  Months:     %d unique", panel["month"].nunique())
    log.info("  TTE range:  %d to %d", tte_range[0], tte_range[1])
    log.info("  Missing ASD: %d (%.1f%%)", missing_asd, missing_pct)
    log.info("  Output:     %s", OUTPUT)

    if missing_pct > 30:
        log.warning("Missing ASD exceeds 30%% - check Arcan output coverage")
    if n_repos < 100:
        log.warning("Fewer than 100 repos - expected ~180")


if __name__ == "__main__":
    main()
