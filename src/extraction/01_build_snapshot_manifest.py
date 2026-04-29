#!/usr/bin/env python3
"""Build snapshot manifest: resolve commit SHAs for each repo-month in the study window.

Reads:
  - data/processed/matching.csv
  - config/repo_lists/treatment_final.csv

Writes:
  - data/interim/snapshot_manifest.csv
"""
import csv
import logging
import subprocess
from pathlib import Path

import yaml

PROJECT_ROOT = Path(__file__).resolve().parents[2]
cfg = yaml.safe_load((PROJECT_ROOT / "config/config.yaml").read_text())

log_dir = PROJECT_ROOT / cfg["paths"]["logs"]
log_dir.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(log_dir / "01_extract_snapshots.log"),
    ],
)
log = logging.getLogger(__name__)

REPOS_DIR = PROJECT_ROOT / "repos"
MATCHING_CSV = PROJECT_ROOT / "data/processed/matching.csv"
TREATMENT_CSV = PROJECT_ROOT / "config/repo_lists/treatment_final.csv"
OUTPUT = PROJECT_ROOT / "data/interim/snapshot_manifest.csv"

PRE_MONTHS = cfg["analysis"]["pre_trend_window"]   # 6
POST_MONTHS = cfg["analysis"]["post_window"]        # 6


def month_offset(yyyy_mm: str, offset: int) -> str:
    """Add offset months to a YYYY-MM string."""
    year, month = int(yyyy_mm[:4]), int(yyyy_mm[5:7])
    month += offset
    while month <= 0:
        month += 12
        year -= 1
    while month > 12:
        month -= 12
        year += 1
    return f"{year:04d}-{month:02d}"


def resolve_sha(repo_path: Path, before_date: str) -> str | None:
    """Get the latest commit SHA before the given date."""
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_path), "rev-list", "-n", "1",
             "--first-parent", f"--before={before_date}", "HEAD"],
            capture_output=True, text=True, timeout=10,
        )
        sha = result.stdout.strip()
        return sha if sha else None
    except (subprocess.TimeoutExpired, Exception):
        return None


def main() -> None:
    log.info("Building snapshot manifest")

    # Load treatment adoption dates
    adoption_month: dict[str, str] = {}
    with open(TREATMENT_CSV) as f:
        reader = csv.DictReader(f)
        for row in reader:
            adoption_month[row["full_name"]] = row["adoption_date"][:7]
    log.info("Loaded %d treatment adoption dates", len(adoption_month))

    # Load matching pairs
    pairs: list[tuple[str, str]] = []
    with open(MATCHING_CSV) as f:
        reader = csv.DictReader(f)
        for row in reader:
            pairs.append((row["treatment_repo"], row["control_repo"]))
    log.info("Loaded %d matched pairs", len(pairs))

    # Build manifest
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "repo_name", "dir_name", "month", "commit_sha",
        "is_treatment", "first_treat_month", "status",
    ]

    found = 0
    missing = 0
    no_repo = 0
    total = 0

    with open(OUTPUT, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for pair_idx, (treatment, control) in enumerate(pairs):
            first_treat = adoption_month.get(treatment)
            if not first_treat:
                log.warning("No adoption date for %s, skipping", treatment)
                continue

            for repo, is_treatment in [(treatment, 1), (control, 0)]:
                dir_name = repo.replace("/", "__", 1)
                repo_path = REPOS_DIR / dir_name

                for offset in range(-PRE_MONTHS, POST_MONTHS + 1):
                    month = month_offset(first_treat, offset)
                    before_date = f"{month}-01"
                    total += 1

                    if not repo_path.is_dir():
                        writer.writerow({
                            "repo_name": repo, "dir_name": dir_name,
                            "month": month, "commit_sha": "",
                            "is_treatment": is_treatment,
                            "first_treat_month": first_treat, "status": "no_repo",
                        })
                        no_repo += 1
                        continue

                    sha = resolve_sha(repo_path, before_date)
                    if sha:
                        writer.writerow({
                            "repo_name": repo, "dir_name": dir_name,
                            "month": month, "commit_sha": sha,
                            "is_treatment": is_treatment,
                            "first_treat_month": first_treat, "status": "found",
                        })
                        found += 1
                    else:
                        writer.writerow({
                            "repo_name": repo, "dir_name": dir_name,
                            "month": month, "commit_sha": "",
                            "is_treatment": is_treatment,
                            "first_treat_month": first_treat, "status": "missing",
                        })
                        missing += 1

            if (pair_idx + 1) % 10 == 0:
                log.info("  Processed %d / %d pairs ...", pair_idx + 1, len(pairs))

    log.info("=== Manifest Summary ===")
    log.info("  Total snapshots:     %d", total)
    log.info("  Found (have SHA):    %d", found)
    log.info("  Missing (no commit): %d", missing)
    log.info("  No repo clone:       %d", no_repo)
    log.info("  Output: %s", OUTPUT)


if __name__ == "__main__":
    main()
