"""Compute matching covariates for all treatment and control repos.

Extracts stars, size_kb, forks, num_commits, num_contributors, and
repo_age_months from existing CSVs, metadata JSONL, and bare git clones.
Falls back to GitHub API for repos without local clones.
"""

import csv
import json
import logging
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import yaml
from tqdm import tqdm

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

REFERENCE_DATE = datetime(2026, 3, 1, tzinfo=timezone.utc)

OUTPUT_COLUMNS = [
    "full_name",
    "treated",
    "stars",
    "size_kb",
    "forks",
    "num_commits",
    "num_contributors",
    "repo_age_months",
]


def setup_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    root.setLevel(logging.DEBUG)
    root.handlers.clear()

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    root.addHandler(console)

    fh = logging.FileHandler(log_path, mode="w")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s - %(message)s"))
    root.addHandler(fh)


def git_stats(repo_dir: Path) -> tuple[int | None, int | None]:
    """Return (num_commits, num_contributors) from a bare git clone."""
    num_commits = None
    num_contributors = None

    try:
        result = subprocess.run(
            ["git", "-C", str(repo_dir), "rev-list", "--count", "HEAD"],
            capture_output=True, text=True, timeout=60,
        )
        if result.returncode == 0:
            num_commits = int(result.stdout.strip())
    except (subprocess.TimeoutExpired, ValueError):
        pass

    try:
        result = subprocess.run(
            ["git", "-C", str(repo_dir), "log", "--format=%aE"],
            capture_output=True, text=True, timeout=120,
        )
        if result.returncode == 0:
            emails = {e for e in result.stdout.strip().splitlines() if e}
            num_contributors = len(emails)
    except subprocess.TimeoutExpired:
        pass

    return num_commits, num_contributors


def parse_date(date_str: str) -> datetime | None:
    if not date_str:
        return None
    try:
        return datetime.fromisoformat(date_str.replace("Z", "+00:00"))
    except ValueError:
        return None


def compute_age_months(created_at: str) -> float | None:
    dt = parse_date(created_at)
    if dt is None:
        return None
    ref = REFERENCE_DATE
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return max(0.0, (ref.year - dt.year) * 12 + (ref.month - dt.month))


def main() -> None:
    cfg = yaml.safe_load((PROJECT_ROOT / "config" / "config.yaml").read_text())
    seed = cfg["study"]["seed"]
    np.random.seed(seed)

    log_path = PROJECT_ROOT / cfg["paths"]["logs"] / "01_compute_covariates.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    logger.info("=== Phase 2 Step 1: Compute Covariates ===")
    logger.info(f"Config: seed={seed}, reference_date={REFERENCE_DATE.date()}")

    # Load treatment metadata from JSONL (for forks + created_at)
    meta: dict[str, dict] = {}
    jsonl_path = PROJECT_ROOT / "data" / "raw" / "github_metadata" / "repo_metadata.jsonl"
    with open(jsonl_path) as f:
        for line in f:
            d = json.loads(line)
            meta[d["full_name"]] = d

    # Load treatment repos
    treatment_path = PROJECT_ROOT / "config" / "repo_lists" / "treatment_final.csv"
    repos: list[dict] = []
    with open(treatment_path) as f:
        for row in csv.DictReader(f):
            m = meta.get(row["full_name"], {})
            repos.append({
                "full_name": row["full_name"],
                "treated": 1,
                "stars": int(row["stars"]),
                "size_kb": int(row["size_kb"]),
                "forks": int(m.get("forks_count", 0)),
                "created_at": m.get("created_at", ""),
            })

    n_treat = len(repos)

    # Load control repos
    control_path = PROJECT_ROOT / "config" / "repo_lists" / "control_candidates.csv"
    with open(control_path) as f:
        for row in csv.DictReader(f):
            repos.append({
                "full_name": row["full_name"],
                "treated": 0,
                "stars": int(row["stars"]),
                "size_kb": int(row["size_kb"]),
                "forks": int(row.get("forks", 0)),
                "created_at": row.get("created_at", ""),
            })

    logger.info(f"Loaded {n_treat} treatment + {len(repos) - n_treat} control repos")

    # Extract git stats from bare clones (parallelized)
    repos_dir = PROJECT_ROOT / "repos"

    def process_repo(repo: dict) -> dict:
        dir_name = repo["full_name"].replace("/", "__")
        repo_path = repos_dir / dir_name

        num_commits, num_contributors = None, None
        if repo_path.exists():
            num_commits, num_contributors = git_stats(repo_path)

        age = compute_age_months(repo["created_at"])

        return {
            "full_name": repo["full_name"],
            "treated": repo["treated"],
            "stars": repo["stars"],
            "size_kb": repo["size_kb"],
            "forks": repo["forks"],
            "num_commits": num_commits,
            "num_contributors": num_contributors,
            "repo_age_months": age,
        }

    logger.info("Extracting git stats from bare clones...")
    results: list[dict] = []
    api_needed: list[dict] = []

    with ThreadPoolExecutor(max_workers=8) as executor:
        futures = {executor.submit(process_repo, r): r for r in repos}
        for future in tqdm(as_completed(futures), total=len(repos), desc="Covariates"):
            result = future.result()
            if result["num_commits"] is None:
                api_needed.append(result)
            results.append(result)

    # Fall back to GitHub API for repos without clones
    if api_needed:
        logger.info(f"Fetching covariates via GitHub API for {len(api_needed)} uncloned repos...")
        from mining.utils.github_api import create_client  # noqa: E402
        from github.GithubException import GithubException  # noqa: E402

        g = create_client()
        api_ok = 0
        api_fail = 0

        for r in tqdm(api_needed, desc="API fallback"):
            try:
                repo = g.get_repo(r["full_name"])
                # get_commits().totalCount is 1 API call
                r["num_commits"] = repo.get_commits().totalCount
                r["num_contributors"] = repo.get_contributors().totalCount
                api_ok += 1
            except GithubException as e:
                logger.debug(f"API error for {r['full_name']}: {e}")
                api_fail += 1
            time.sleep(0.5)  # rate limit courtesy

        logger.info(f"API fallback: {api_ok} OK, {api_fail} failed")

    results.sort(key=lambda r: r["full_name"])

    # Report missing values
    for col in OUTPUT_COLUMNS:
        missing = sum(1 for r in results if r.get(col) is None)
        if missing:
            logger.warning(f"Missing {col}: {missing}/{len(results)}")

    # Save
    out_path = PROJECT_ROOT / "data" / "processed" / "repo_characteristics.csv"
    out_path.parent.mkdir(parents=True, exist_ok=True)

    with open(out_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=OUTPUT_COLUMNS)
        writer.writeheader()
        for r in results:
            writer.writerow({col: r.get(col, "") for col in OUTPUT_COLUMNS})

    logger.info(f"Saved {len(results)} repos to {out_path}")

    # Summary stats
    for label, group in [
        ("Treatment", [r for r in results if r["treated"] == 1]),
        ("Control", [r for r in results if r["treated"] == 0]),
    ]:
        def vals(key: str) -> np.ndarray:
            return np.array([r[key] for r in group if r[key] is not None])

        logger.info(f"\n{label} ({len(group)} repos):")
        for col, name in [
            ("stars", "Stars"),
            ("num_commits", "Commits"),
            ("num_contributors", "Contributors"),
            ("repo_age_months", "Age (months)"),
            ("size_kb", "Size (KB)"),
            ("forks", "Forks"),
        ]:
            v = vals(col)
            if len(v):
                logger.info(
                    f"  {name:<16} median={np.median(v):>8.0f}  "
                    f"mean={np.mean(v):>8.0f}  range=[{np.min(v):.0f}, {np.max(v):.0f}]"
                )

    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
