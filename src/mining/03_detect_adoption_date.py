"""Detect AI tool adoption dates for treatment candidate repos."""

import csv
import logging
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime
from pathlib import Path

import yaml
from tqdm import tqdm

# ---------------------------------------------------------------------------
# Path setup
# ---------------------------------------------------------------------------
PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT))

from src.mining.utils.commit_parser import detect_adoption, validate_windows  # noqa: E402

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
LOG_DIR = PROJECT_ROOT / "results" / "logs"
LOG_DIR.mkdir(parents=True, exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(LOG_DIR / "03_detect_adoption_date.log", mode="a"),
    ],
)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
CONFIG_PATH = PROJECT_ROOT / "config" / "config.yaml"
REPO_LISTS_DIR = PROJECT_ROOT / "config" / "repo_lists"
REPOS_DIR = PROJECT_ROOT / "repos"

INPUT_CSV = REPO_LISTS_DIR / "treatment_candidates.csv"
OUTPUT_FINAL_CSV = REPO_LISTS_DIR / "treatment_final.csv"
OUTPUT_ALL_CSV = REPO_LISTS_DIR / "treatment_all_with_adoption.csv"

CLONE_WORKERS = 4

OUTPUT_COLUMNS = [
    "full_name", "language", "stars", "size_kb", "default_branch", "markers",
    "adoption_date", "adoption_signal", "adoption_detail", "total_ai_events",
    "pre_months", "post_months", "total_commits", "avg_commits_per_month",
    "first_commit", "last_commit", "window_valid",
]


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def flatten_ai_markers(ai_markers: dict) -> list[str]:
    """Flatten the nested ai_markers config into a flat list of filenames."""
    flat: list[str] = []
    for files in ai_markers.values():
        if isinstance(files, list):
            flat.extend(files)
        else:
            flat.append(files)
    return flat


def repo_dir_name(full_name: str) -> str:
    """Convert 'owner/repo' to 'owner__repo' for local directory."""
    return full_name.replace("/", "__")


def clone_repo(full_name: str) -> bool:
    """Clone a repo as a bare repo. Returns True on success."""
    dir_name = repo_dir_name(full_name)
    dest = REPOS_DIR / dir_name

    if dest.exists():
        return True

    url = f"https://github.com/{full_name}.git"
    logger.info(f"Cloning {full_name} -> {dest}")
    try:
        subprocess.run(
            ["git", "clone", "--bare", "--single-branch", url, str(dest)],
            capture_output=True, text=True, timeout=300, check=True,
        )
        return True
    except subprocess.CalledProcessError as e:
        logger.error(f"Clone failed for {full_name}: {e.stderr.strip()}")
        return False
    except subprocess.TimeoutExpired:
        logger.error(f"Clone timed out for {full_name}")
        return False


def load_candidates() -> list[dict]:
    """Load treatment candidate repos from CSV."""
    if not INPUT_CSV.exists():
        logger.error(f"Input CSV not found: {INPUT_CSV}")
        sys.exit(1)

    with open(INPUT_CSV, newline="") as f:
        reader = csv.DictReader(f)
        return list(reader)


def load_already_processed() -> set[str]:
    """Load already-processed repo names from the audit CSV for idempotency."""
    if not OUTPUT_ALL_CSV.exists():
        return set()
    with open(OUTPUT_ALL_CSV, newline="") as f:
        reader = csv.DictReader(f)
        return {row["full_name"] for row in reader}


def process_repo(
    repo: dict,
    marker_files: list[str],
    commit_patterns: list[str],
    min_pre_months: int,
    min_post_months: int,
    min_commits_per_month: float,
) -> dict:
    """Process a single repo: clone, detect adoption, validate windows."""
    full_name = repo["full_name"]
    dir_name = repo_dir_name(full_name)
    repo_path = str(REPOS_DIR / dir_name)

    result = {
        "full_name": full_name,
        "language": repo.get("language", ""),
        "stars": repo.get("stars", ""),
        "size_kb": repo.get("size_kb", ""),
        "default_branch": repo.get("default_branch", ""),
        "markers": repo.get("markers", ""),
        "adoption_date": "",
        "adoption_signal": "",
        "adoption_detail": "",
        "total_ai_events": 0,
        "pre_months": "",
        "post_months": "",
        "total_commits": "",
        "avg_commits_per_month": "",
        "first_commit": "",
        "last_commit": "",
        "window_valid": False,
    }

    # Clone if needed
    if not clone_repo(full_name):
        result["adoption_detail"] = "clone_failed"
        return result

    # Detect adoption
    adoption = detect_adoption(repo_path, marker_files, commit_patterns)
    if adoption is None:
        result["adoption_detail"] = "no_ai_events"
        return result

    result["adoption_date"] = adoption["adoption_date"]
    result["adoption_signal"] = adoption["adoption_signal"]
    result["adoption_detail"] = adoption["adoption_detail"]
    result["total_ai_events"] = adoption["total_ai_events"]

    # Validate windows
    adoption_dt = datetime.fromisoformat(adoption["adoption_date"])
    windows = validate_windows(
        repo_path, adoption_dt, min_pre_months, min_post_months, min_commits_per_month
    )

    result["pre_months"] = windows["pre_months"]
    result["post_months"] = windows["post_months"]
    result["total_commits"] = windows["total_commits"]
    result["avg_commits_per_month"] = windows["avg_commits_per_month"]
    result["first_commit"] = windows["first_commit"] or ""
    result["last_commit"] = windows["last_commit"] or ""
    result["window_valid"] = windows["valid"]

    if not windows["valid"]:
        logger.debug(f"  {full_name}: window invalid - {windows['reason']}")

    return result


def main():
    logger.info("=" * 60)
    logger.info("03_detect_adoption_date.py starting")
    logger.info("=" * 60)

    # Load config
    cfg = load_config()
    mining = cfg["mining"]
    marker_files = flatten_ai_markers(mining["ai_markers"])
    commit_patterns = mining["commit_patterns"]
    min_pre_months = mining["min_pre_months"]
    min_post_months = mining["min_post_months"]
    min_commits_per_month = mining["min_commits_per_month"]

    logger.info(f"AI marker files: {marker_files}")
    logger.info(f"Commit patterns: {commit_patterns}")
    logger.info(
        f"Window requirements: pre>={min_pre_months}mo, "
        f"post>={min_post_months}mo, avg>={min_commits_per_month}/mo"
    )

    # Load candidates
    candidates = load_candidates()
    logger.info(f"Loaded {len(candidates)} treatment candidates")

    # Check idempotency
    already_done = load_already_processed()
    to_process = [c for c in candidates if c["full_name"] not in already_done]
    logger.info(f"Already processed: {len(already_done)}, remaining: {len(to_process)}")

    if not to_process:
        logger.info("All repos already processed. Nothing to do.")
        # Still regenerate final CSV from audit CSV
        _regenerate_final_csv()
        return

    # Ensure repos dir exists
    REPOS_DIR.mkdir(parents=True, exist_ok=True)

    # Clone repos in parallel first
    repos_to_clone = [
        r["full_name"] for r in to_process
        if not (REPOS_DIR / repo_dir_name(r["full_name"])).exists()
    ]
    if repos_to_clone:
        logger.info(f"Cloning {len(repos_to_clone)} repos with {CLONE_WORKERS} workers...")
        with ThreadPoolExecutor(max_workers=CLONE_WORKERS) as pool:
            futures = {pool.submit(clone_repo, name): name for name in repos_to_clone}
            for future in tqdm(as_completed(futures), total=len(futures), desc="Cloning"):
                name = futures[future]
                try:
                    success = future.result()
                    if not success:
                        logger.warning(f"Failed to clone {name}")
                except Exception as e:
                    logger.error(f"Exception cloning {name}: {e}")

    # Process repos sequentially (git log is I/O bound, parallelism gains minimal)
    new_results: list[dict] = []
    for repo in tqdm(to_process, desc="Detecting adoption"):
        result = process_repo(
            repo, marker_files, commit_patterns,
            min_pre_months, min_post_months, min_commits_per_month,
        )
        new_results.append(result)
        logger.info(
            f"  {result['full_name']}: adoption={result['adoption_date'] or 'none'}, "
            f"valid={result['window_valid']}"
        )

    # Append new results to audit CSV
    write_header = not OUTPUT_ALL_CSV.exists()
    with open(OUTPUT_ALL_CSV, "a", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        if write_header:
            writer.writeheader()
        for row in new_results:
            writer.writerow(row)

    logger.info(f"Appended {len(new_results)} results to {OUTPUT_ALL_CSV}")

    # Regenerate final CSV
    _regenerate_final_csv()

    # Log funnel
    _log_funnel(candidates)


def _regenerate_final_csv():
    """Read audit CSV and write final CSV with only valid-window repos."""
    if not OUTPUT_ALL_CSV.exists():
        logger.warning("Audit CSV does not exist, cannot regenerate final CSV")
        return

    with open(OUTPUT_ALL_CSV, newline="") as f:
        reader = csv.DictReader(f)
        all_rows = list(reader)

    valid_rows = [r for r in all_rows if r.get("window_valid", "").lower() == "true"]

    with open(OUTPUT_FINAL_CSV, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        writer.writerows(valid_rows)

    logger.info(f"Wrote {len(valid_rows)} valid repos to {OUTPUT_FINAL_CSV}")


def _log_funnel(candidates: list[dict]):
    """Log the selection funnel."""
    if not OUTPUT_ALL_CSV.exists():
        return

    with open(OUTPUT_ALL_CSV, newline="") as f:
        reader = csv.DictReader(f)
        all_rows = list(reader)

    total = len(candidates)
    adoption_detected = sum(1 for r in all_rows if r.get("adoption_date", ""))
    window_valid = sum(1 for r in all_rows if r.get("window_valid", "").lower() == "true")

    logger.info("=" * 40)
    logger.info("SELECTION FUNNEL")
    logger.info(f"  Total candidates:    {total}")
    logger.info(f"  Adoption detected:   {adoption_detected}")
    logger.info(f"  Window valid:        {window_valid}")
    logger.info(f"  Final treatment set: {window_valid}")
    logger.info("=" * 40)


if __name__ == "__main__":
    main()
