"""Search for Java control repos (no AI tool markers)."""

import csv
import json
import logging
import random
import sys
import time
from pathlib import Path

import yaml
from github.GithubException import GithubException
from tqdm import tqdm

PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(PROJECT_ROOT / "src"))

from mining.utils.github_api import check_rate_limit, create_client  # noqa: E402

AI_MARKER_PATHS = [
    ".cursorrules",
    "CLAUDE.md",
    "claude.md",
    "AGENTS.md",
    ".github/copilot-instructions.md",
    ".aider.conf.yml",
]

STAR_RANGES = [
    "stars:5..20",
    "stars:20..50",
    "stars:50..200",
    "stars:200..1000",
    "stars:>1000",
]

MAX_PER_RANGE = 500
TARGET_CONTROLS = 300
SEARCH_SLEEP = 2.0  # seconds between search queries (30/min limit)
VERIFY_SLEEP = 0.1  # light pause between repo verification batches

CSV_COLUMNS = [
    "full_name",
    "language",
    "stars",
    "size_kb",
    "forks",
    "created_at",
    "pushed_at",
    "default_branch",
    "description",
    "license",
    "ai_markers_verified_absent",
]


def setup_logging(log_path: Path) -> None:
    log_path.parent.mkdir(parents=True, exist_ok=True)
    root_logger = logging.getLogger()
    root_logger.setLevel(logging.DEBUG)

    root_logger.handlers.clear()

    console = logging.StreamHandler(sys.stdout)
    console.setLevel(logging.INFO)
    console.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(message)s"))
    root_logger.addHandler(console)

    fh = logging.FileHandler(log_path, mode="a")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(
        logging.Formatter("%(asctime)s [%(levelname)s] %(name)s - %(message)s")
    )
    root_logger.addHandler(fh)


def load_treatment_names(repo_lists_dir: Path) -> set[str]:
    """Load treatment repo names to exclude from control candidates."""
    for filename in ("treatment_final.csv", "treatment_candidates.csv"):
        path = repo_lists_dir / filename
        if path.exists():
            names: set[str] = set()
            with open(path) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    name = row.get("full_name", "").strip()
                    if name:
                        names.add(name.lower())
            logging.getLogger(__name__).info(
                f"Loaded {len(names)} treatment names from {path.name}"
            )
            return names
    return set()


def load_existing_controls(csv_path: Path) -> list[dict]:
    """Load already-verified control candidates if file exists."""
    if not csv_path.exists():
        return []
    rows = []
    with open(csv_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            rows.append(row)
    return rows


def search_repos_in_range(g, star_range: str, seed: int, logger) -> list:
    """Search GitHub for Java repos in a star range, return up to MAX_PER_RANGE randomized."""
    query = f"language:Java {star_range} pushed:>2024-01-01 archived:false fork:false"
    logger.info(f"Searching: {query}")

    time.sleep(SEARCH_SLEEP)
    try:
        results = g.search_repositories(query, sort="stars", order="desc")
        total = results.totalCount
    except GithubException as e:
        logger.error(f"Search API error for '{query}': {e}")
        return []

    logger.info(f"  -> {total} results for {star_range}")

    # Collect up to 1000 (API cap) repos from search results
    collected = []
    pages_needed = min(10, (min(total, 1000) + 99) // 100)  # 100 per page, max 1000

    for page_num in range(pages_needed):
        time.sleep(SEARCH_SLEEP)
        try:
            page = results.get_page(page_num)
        except GithubException as e:
            logger.warning(f"Error fetching page {page_num} for '{query}': {e}")
            break

        if not page:
            break

        for repo in page:
            collected.append(repo)

        logger.debug(f"  Page {page_num}: {len(collected)} repos collected")

        if len(collected) >= min(total, 1000):
            break

    logger.info(f"  -> Collected {len(collected)} repos from search")

    # Randomize and cap
    rng = random.Random(seed)
    rng.shuffle(collected)
    return collected[:MAX_PER_RANGE]


def verify_no_ai_markers(g, repo_full_name: str, logger) -> bool:
    """Verify a repo has NO AI marker files. Returns True if clean (no markers)."""
    try:
        repo = g.get_repo(repo_full_name)
    except GithubException as e:
        logger.warning(f"Cannot access repo {repo_full_name}: {e}")
        return False

    for marker_path in AI_MARKER_PATHS:
        try:
            repo.get_contents(marker_path)
            # If we get here, file exists -> NOT a valid control
            logger.debug(f"  Found marker {marker_path} in {repo_full_name}")
            return False
        except GithubException as e:
            if e.status == 404:
                continue  # File doesn't exist, good
            logger.warning(
                f"API error checking {marker_path} in {repo_full_name}: {e}"
            )
            # On non-404 errors, be conservative and skip this repo
            return False

    return True


def repo_to_row(repo) -> dict:
    """Extract CSV row from a PyGithub Repository object."""
    license_name = ""
    if repo.license and repo.license.spdx_id:
        license_name = repo.license.spdx_id

    return {
        "full_name": repo.full_name,
        "language": repo.language or "",
        "stars": repo.stargazers_count,
        "size_kb": repo.size,
        "forks": repo.forks_count,
        "created_at": repo.created_at.isoformat() if repo.created_at else "",
        "pushed_at": repo.pushed_at.isoformat() if repo.pushed_at else "",
        "default_branch": repo.default_branch or "",
        "description": (repo.description or "")[:500],
        "license": license_name,
        "ai_markers_verified_absent": True,
    }


def save_candidates(csv_path: Path, rows: list[dict]) -> None:
    csv_path.parent.mkdir(parents=True, exist_ok=True)
    with open(csv_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for row in rows:
            writer.writerow(row)


def main() -> None:
    config_path = PROJECT_ROOT / "config" / "config.yaml"
    with open(config_path) as f:
        config = yaml.safe_load(f)

    seed = config["study"]["seed"]
    random.seed(seed)

    log_path = PROJECT_ROOT / config["paths"]["logs"] / "04_search_control_candidates.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    csv_path = PROJECT_ROOT / "config" / "repo_lists" / "control_candidates.csv"
    repo_lists_dir = PROJECT_ROOT / "config" / "repo_lists"
    repo_lists_dir.mkdir(parents=True, exist_ok=True)

    logger.info("=== Phase 1: Search Control Candidates ===")
    logger.info(f"Config: seed={seed}, target={TARGET_CONTROLS}")

    # Idempotency check
    existing = load_existing_controls(csv_path)
    if len(existing) >= 200:
        logger.info(
            f"Control candidates already exist with {len(existing)} entries (>= 200). Skipping."
        )
        return

    # Load treatment names to exclude
    treatment_names = load_treatment_names(repo_lists_dir)
    logger.info(f"Excluding {len(treatment_names)} treatment repos")

    g = create_client()
    rl = check_rate_limit(g)
    logger.info(f"Rate limits: {json.dumps(rl)}")

    # Phase A: Collect candidate repos from search
    all_candidates = []
    seen_names: set[str] = set()

    for star_range in STAR_RANGES:
        repos = search_repos_in_range(g, star_range, seed, logger)

        added = 0
        for repo in repos:
            name_lower = repo.full_name.lower()
            if name_lower in seen_names:
                continue
            if name_lower in treatment_names:
                logger.debug(f"  Excluding treatment repo: {repo.full_name}")
                continue
            seen_names.add(name_lower)
            all_candidates.append(repo)
            added += 1

        logger.info(
            f"  -> {added} new candidates from {star_range} "
            f"(total pool: {len(all_candidates)})"
        )

        rl = check_rate_limit(g)
        logger.debug(f"Rate limits after search: {json.dumps(rl)}")

    logger.info(f"Total candidate pool (pre-verification): {len(all_candidates)}")

    # Phase B: Verify no AI markers exist
    verified: list[dict] = []
    excluded_count = 0

    for repo in tqdm(all_candidates, desc="Verifying controls"):
        if len(verified) >= TARGET_CONTROLS:
            logger.info(f"Reached target of {TARGET_CONTROLS} verified controls")
            break

        # Check rate limit periodically
        if (len(verified) + excluded_count) % 50 == 0 and (len(verified) + excluded_count) > 0:
            rl = check_rate_limit(g)
            remaining = rl["core"]["remaining"]
            logger.info(
                f"Progress: {len(verified)} verified, {excluded_count} excluded, "
                f"core API remaining: {remaining}"
            )
            if remaining < 100:
                wait_time = 300
                logger.warning(
                    f"Core API nearly exhausted ({remaining} left). "
                    f"Sleeping {wait_time}s..."
                )
                time.sleep(wait_time)

        time.sleep(VERIFY_SLEEP)

        is_clean = verify_no_ai_markers(g, repo.full_name, logger)

        if is_clean:
            row = repo_to_row(repo)
            verified.append(row)
            logger.debug(f"  PASS: {repo.full_name}")
        else:
            excluded_count += 1
            logger.debug(f"  FAIL: {repo.full_name} (has AI markers or inaccessible)")

    logger.info(
        f"Verification complete: {len(verified)} verified, "
        f"{excluded_count} excluded"
    )

    # Save results
    save_candidates(csv_path, verified)
    logger.info(f"Saved {len(verified)} control candidates to {csv_path}")

    rl = check_rate_limit(g)
    logger.info(f"Final rate limits: {json.dumps(rl)}")
    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
