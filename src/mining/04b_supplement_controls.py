"""Supplement control candidates with repos across diverse star ranges.

The original script 04 collected 300 controls all at 19-20 stars.
This supplements with controls from higher star ranges to enable
propensity score matching across the full treatment distribution.

Uses the git tree API (1 call per repo) for fast AI-marker verification.
"""

import csv
import hashlib
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

# Star ranges matching the treatment distribution (excluding 5-20, already covered)
STAR_RANGES_TARGETS = [
    ("stars:21..50", 60),
    ("stars:51..200", 60),
    ("stars:201..1000", 80),
    ("stars:1001..50000", 80),
]

SEARCH_CANDIDATES_PER_RANGE = 300  # search pool size per range
SEARCH_SLEEP = 2.0

# AI marker files to check
MARKER_FILES = [
    ".cursorrules",
    "CLAUDE.md",
    "claude.md",
    "AGENTS.md",
    ".github/copilot-instructions.md",
    ".aider.conf.yml",
    ".aider.model.settings.yml",
]

# Directory-based markers (check if any tree entry starts with this prefix)
MARKER_DIRS = [".cursor/rules/"]

CSV_COLUMNS = [
    "full_name", "language", "stars", "size_kb", "forks",
    "created_at", "pushed_at", "default_branch", "description",
    "license", "ai_markers_verified_absent",
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

    fh = logging.FileHandler(log_path, mode="a")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter("%(asctime)s [%(levelname)s] %(name)s - %(message)s"))
    root.addHandler(fh)


def load_excluded_names(repo_lists_dir: Path) -> set[str]:
    """Load all repo names to exclude (treatment + existing controls)."""
    names: set[str] = set()
    for filename in ("treatment_final.csv", "treatment_candidates.csv", "control_candidates.csv"):
        path = repo_lists_dir / filename
        if path.exists():
            with open(path) as f:
                reader = csv.DictReader(f)
                for row in reader:
                    name = row.get("full_name", "").strip()
                    if name:
                        names.add(name.lower())
    return names


def has_ai_markers_via_tree(repo, logger) -> bool:
    """Check for AI markers using git tree API (1 API call instead of 6+)."""
    try:
        tree = repo.get_git_tree(repo.default_branch, recursive=True)
        paths = {item.path for item in tree.tree}

        # Check file markers
        for marker in MARKER_FILES:
            if marker in paths:
                logger.debug(f"  Found marker file {marker} in {repo.full_name}")
                return True

        # Check directory markers
        for marker_dir in MARKER_DIRS:
            if any(p.startswith(marker_dir) for p in paths):
                logger.debug(f"  Found marker dir {marker_dir} in {repo.full_name}")
                return True

        # Handle truncated trees (very large repos)
        if tree.truncated:
            logger.debug(f"  Tree truncated for {repo.full_name}, falling back to file checks")
            for marker in MARKER_FILES:
                try:
                    repo.get_contents(marker)
                    return True
                except GithubException as e:
                    if e.status == 404:
                        continue
                    return True  # conservative on errors

        return False

    except GithubException as e:
        logger.warning(f"  Tree API error for {repo.full_name}: {e}")
        return True  # conservative: exclude on error


def repo_to_row(repo) -> dict:
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


def main() -> None:
    cfg = yaml.safe_load((PROJECT_ROOT / "config" / "config.yaml").read_text())
    seed = cfg["study"]["seed"]
    random.seed(seed)

    log_path = PROJECT_ROOT / cfg["paths"]["logs"] / "04b_supplement_controls.log"
    setup_logging(log_path)
    logger = logging.getLogger(__name__)

    logger.info("=== Supplement Control Candidates ===")

    repo_lists_dir = PROJECT_ROOT / "config" / "repo_lists"
    exclude = load_excluded_names(repo_lists_dir)
    logger.info(f"Excluding {len(exclude)} known repos")

    g = create_client()
    rl = check_rate_limit(g)
    logger.info(f"Rate limits: core={rl['core']['remaining']}/{rl['core']['limit']}")

    new_controls: list[dict] = []

    for star_range, target in STAR_RANGES_TARGETS:
        query = f"language:Java {star_range} pushed:>2024-01-01 archived:false fork:false"
        logger.info(f"\nSearching: {query} (target: {target})")

        time.sleep(SEARCH_SLEEP)
        try:
            results = g.search_repositories(query, sort="updated", order="desc")
            total = results.totalCount
        except GithubException as e:
            logger.error(f"Search error for {star_range}: {e}")
            continue

        logger.info(f"  -> {total} results")

        # Collect candidates
        candidates = []
        pages_needed = min(10, (min(total, SEARCH_CANDIDATES_PER_RANGE) + 99) // 100)

        for page_num in range(pages_needed):
            time.sleep(SEARCH_SLEEP)
            try:
                page = results.get_page(page_num)
            except GithubException as e:
                logger.warning(f"  Page {page_num} error: {e}")
                break

            if not page:
                break

            for repo in page:
                if repo.full_name.lower() not in exclude:
                    candidates.append(repo)

            if len(candidates) >= SEARCH_CANDIDATES_PER_RANGE:
                break

        logger.info(f"  -> {len(candidates)} candidates (after exclusions)")

        # Randomize
        rng = random.Random(seed + int(hashlib.md5(star_range.encode()).hexdigest(), 16) % (2**31))
        rng.shuffle(candidates)

        # Verify no AI markers
        verified = 0
        checked = 0

        for repo in tqdm(candidates, desc=f"Verifying {star_range}", leave=False):
            if verified >= target:
                break

            checked += 1
            time.sleep(0.1)  # gentle rate limiting

            if not has_ai_markers_via_tree(repo, logger):
                new_controls.append(repo_to_row(repo))
                verified += 1
                exclude.add(repo.full_name.lower())  # prevent duplicates across ranges

            # Rate limit check every 50 repos
            if checked % 50 == 0:
                rl = check_rate_limit(g)
                remaining = rl["core"]["remaining"]
                if remaining < 200:
                    logger.warning(f"Core API low ({remaining}). Sleeping 60s...")
                    time.sleep(60)

        logger.info(f"  -> Verified {verified}/{target} controls for {star_range}")

    logger.info(f"\nTotal new controls: {len(new_controls)}")

    # Load existing controls and merge
    existing_path = repo_lists_dir / "control_candidates.csv"
    existing: list[dict] = []
    with open(existing_path) as f:
        for row in csv.DictReader(f):
            existing.append(row)

    combined = existing + new_controls
    logger.info(f"Combined: {len(existing)} existing + {len(new_controls)} new = {len(combined)} total")

    # Save
    with open(existing_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=CSV_COLUMNS)
        writer.writeheader()
        for row in combined:
            writer.writerow(row)

    logger.info(f"Saved {len(combined)} controls to {existing_path}")

    # Star distribution of new controls
    star_counts: dict[str, int] = {}
    for c in new_controls:
        s = int(c["stars"])
        if s <= 50:
            bucket = "21-50"
        elif s <= 200:
            bucket = "51-200"
        elif s <= 1000:
            bucket = "201-1000"
        else:
            bucket = "1001+"
        star_counts[bucket] = star_counts.get(bucket, 0) + 1

    logger.info("New controls by star range:")
    for bucket, count in sorted(star_counts.items()):
        logger.info(f"  {bucket}: {count}")

    rl = check_rate_limit(g)
    logger.info(f"Final rate limits: core={rl['core']['remaining']}/{rl['core']['limit']}")
    logger.info("=== Done ===")


if __name__ == "__main__":
    main()
