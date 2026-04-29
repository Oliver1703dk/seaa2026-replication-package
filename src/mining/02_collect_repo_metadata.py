"""Collect repo metadata and filter to Java repos."""

from __future__ import annotations

import json
import logging
import os
import sys
import time
from datetime import timezone
from pathlib import Path

import pandas as pd
import yaml
from github import Auth, Github, GithubException, RateLimitExceededException
from tqdm import tqdm

# Ensure project root is on sys.path for imports
_PROJECT_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(_PROJECT_ROOT))

from src.mining.utils.ai_signal_detector import validate_marker_content  # noqa: E402

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONFIG_PATH = _PROJECT_ROOT / "config" / "config.yaml"
INPUT_CSV = _PROJECT_ROOT / "config" / "repo_lists" / "treatment_candidates_raw.csv"
METADATA_JSONL = _PROJECT_ROOT / "data" / "raw" / "github_metadata" / "repo_metadata.jsonl"
LANG_CACHE_JSONL = _PROJECT_ROOT / "data" / "raw" / "github_metadata" / "language_cache.jsonl"
OUTPUT_CSV = _PROJECT_ROOT / "config" / "repo_lists" / "treatment_candidates.csv"
LOG_FILE = _PROJECT_ROOT / "results" / "logs" / "02_collect_repo_metadata.log"


def _setup_logging() -> logging.Logger:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    logger = logging.getLogger("02_collect_repo_metadata")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()

    fmt = logging.Formatter("%(asctime)s %(levelname)-8s %(message)s", datefmt="%Y-%m-%d %H:%M:%S")

    fh = logging.FileHandler(LOG_FILE, mode="a", encoding="utf-8")
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(fmt)
    logger.addHandler(fh)

    ch = logging.StreamHandler()
    ch.setLevel(logging.INFO)
    ch.setFormatter(fmt)
    logger.addHandler(ch)

    return logger


def _load_config() -> dict:
    return yaml.safe_load(CONFIG_PATH.read_text())


def _get_github_client(cfg: dict) -> Github:
    token_env = cfg["mining"]["github_token_env"]
    token = os.environ.get(token_env)
    if not token:
        # Read from .env file directly
        env_path = _PROJECT_ROOT / ".env"
        if env_path.exists():
            for line in env_path.read_text().splitlines():
                line = line.strip()
                if line.startswith(f"{token_env}="):
                    token = line.split("=", 1)[1].strip()
                    break
    if not token:
        raise RuntimeError(f"GitHub token not found in env var {token_env} or .env file")
    return Github(auth=Auth.Token(token), per_page=100)


def _wait_for_rate_limit(g: Github, logger: logging.Logger) -> None:
    """Block until the core rate limit resets."""
    rl = g.get_rate_limit().resources.core
    if rl.remaining > 10:
        return
    reset_ts = rl.reset.replace(tzinfo=timezone.utc).timestamp()
    wait = max(reset_ts - time.time(), 0) + 5
    logger.warning(
        "Rate limit nearly exhausted (%d left). Sleeping %.0fs until reset.",
        rl.remaining, wait,
    )
    time.sleep(wait)


def _load_language_cache() -> dict[str, str | None]:
    """Load cached language lookups (repo_name -> language or None)."""
    cache: dict[str, str | None] = {}
    if LANG_CACHE_JSONL.exists():
        for line in LANG_CACHE_JSONL.read_text().splitlines():
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
                cache[entry["full_name"]] = entry.get("language")
            except (json.JSONDecodeError, KeyError):
                continue
    return cache


def _append_language_cache(full_name: str, language: str | None) -> None:
    LANG_CACHE_JSONL.parent.mkdir(parents=True, exist_ok=True)
    with open(LANG_CACHE_JSONL, "a", encoding="utf-8") as f:
        f.write(json.dumps({"full_name": full_name, "language": language}) + "\n")


def _check_language(g: Github, full_name: str, logger: logging.Logger) -> str | None:
    """Quick language check - 1 API call, returns language string or None."""
    _wait_for_rate_limit(g, logger)
    try:
        r = g.get_repo(full_name)
        return r.language
    except RateLimitExceededException:
        _wait_for_rate_limit(g, logger)
        try:
            r = g.get_repo(full_name)
            return r.language
        except Exception:
            return None
    except GithubException as e:
        if e.status == 404:
            logger.debug("Repo not found (404): %s", full_name)
        return None
    except Exception:
        return None


def _fetch_repo_metadata(g: Github, full_name: str, logger: logging.Logger) -> dict | None:
    """Fetch metadata for a single repo. Returns dict or None on failure."""
    _wait_for_rate_limit(g, logger)
    try:
        r = g.get_repo(full_name)
    except RateLimitExceededException:
        _wait_for_rate_limit(g, logger)
        try:
            r = g.get_repo(full_name)
        except Exception as e:
            logger.error("Failed to fetch %s after rate-limit wait: %s", full_name, e)
            return None
    except GithubException as e:
        if e.status == 404:
            logger.warning("Repo not found (404): %s", full_name)
        else:
            logger.error("GitHub API error for %s: %s", full_name, e)
        return None
    except Exception as e:
        logger.error("Unexpected error fetching %s: %s", full_name, e)
        return None

    try:
        license_id = r.license.spdx_id if r.license else None
    except Exception:
        license_id = None

    return {
        "full_name": r.full_name,
        "language": r.language,
        "stargazers_count": r.stargazers_count,
        "forks_count": r.forks_count,
        "created_at": r.created_at.isoformat() if r.created_at else None,
        "pushed_at": r.pushed_at.isoformat() if r.pushed_at else None,
        "updated_at": r.updated_at.isoformat() if r.updated_at else None,
        "size": r.size,
        "default_branch": r.default_branch,
        "topics": [],
        "license": license_id,
        "archived": r.archived,
        "fork": r.fork,
        "open_issues_count": r.open_issues_count,
        "subscribers_count": r.subscribers_count,
        "description": r.description,
    }


def _load_existing_metadata() -> dict[str, dict]:
    """Load already-fetched metadata from JSONL for resume support."""
    existing: dict[str, dict] = {}
    if METADATA_JSONL.exists():
        with open(METADATA_JSONL, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                    existing[entry["full_name"]] = entry
                except (json.JSONDecodeError, KeyError):
                    continue
    return existing


def _append_metadata(entry: dict) -> None:
    """Append a single metadata entry to the JSONL file."""
    METADATA_JSONL.parent.mkdir(parents=True, exist_ok=True)
    with open(METADATA_JSONL, "a", encoding="utf-8") as f:
        f.write(json.dumps(entry, ensure_ascii=False) + "\n")


# Category names that are high-reliability (near-zero false positives)
_HIGH_RELIABILITY_CATEGORIES = {"cursor", "copilot", "aider"}

# Map category names to actual file paths for content validation
_CATEGORY_TO_FILES = {
    "claude_code": ["CLAUDE.md", "claude.md"],
    "codex": ["AGENTS.md"],
}


def _has_only_weak_markers(markers_str: str) -> bool:
    """Check if repo was detected only via weak markers (CLAUDE.md/AGENTS.md)."""
    markers = [m.strip() for m in markers_str.split(",") if m.strip()]
    return all(m not in _HIGH_RELIABILITY_CATEGORIES for m in markers)


def _validate_weak_markers(
    g: Github, full_name: str, markers_str: str, logger: logging.Logger
) -> bool:
    """For repos with only weak markers, download and validate content."""
    markers = [m.strip() for m in markers_str.split(",") if m.strip()]
    _wait_for_rate_limit(g, logger)

    try:
        repo = g.get_repo(full_name)
    except Exception as e:
        logger.warning("Could not access %s for marker validation: %s", full_name, e)
        return False

    # Map category names to actual file paths
    for category in markers:
        file_paths = _CATEGORY_TO_FILES.get(category, [])
        for file_path in file_paths:
            try:
                content_file = repo.get_contents(file_path)
                text = content_file.decoded_content.decode("utf-8", errors="replace")
                if validate_marker_content(text, file_path):
                    logger.debug(
                        "Marker %s (%s) in %s passed content validation",
                        category, file_path, full_name,
                    )
                    return True
                else:
                    logger.debug(
                        "Marker %s (%s) in %s failed content validation",
                        category, file_path, full_name,
                    )
            except GithubException as e:
                if e.status == 404:
                    logger.debug("File %s no longer exists in %s", file_path, full_name)
                else:
                    logger.warning("Error validating %s in %s: %s", file_path, full_name, e)
            except Exception as e:
                logger.warning("Error decoding %s in %s: %s", file_path, full_name, e)

    return False


def main() -> None:
    logger = _setup_logging()
    logger.info("=" * 60)
    logger.info("02_collect_repo_metadata - starting")
    logger.info("=" * 60)

    cfg = _load_config()
    g = _get_github_client(cfg)

    # Log rate limit status
    rl = g.get_rate_limit().resources.core
    logger.info("Rate limit: %d / %d remaining, resets %s", rl.remaining, rl.limit, rl.reset)

    # -----------------------------------------------------------------------
    # Step 1: Load input CSV
    # -----------------------------------------------------------------------
    if not INPUT_CSV.exists():
        logger.error("Input file not found: %s", INPUT_CSV)
        logger.error("Run 01_search_treatment_repos.py first.")
        sys.exit(1)

    df_input = pd.read_csv(INPUT_CSV)
    logger.info("Loaded %d rows from %s", len(df_input), INPUT_CSV.name)

    if "full_name" not in df_input.columns:
        logger.error("Input CSV must have a 'full_name' column")
        sys.exit(1)

    # Deduplicate by full_name, keeping the first occurrence (preserve markers)
    # The raw CSV may have duplicates if a repo was found via multiple search queries
    has_markers = "markers" in df_input.columns
    if has_markers:
        # Merge markers for duplicate repos
        markers_map: dict[str, set[str]] = {}
        for _, row in df_input.iterrows():
            name = row["full_name"]
            m = str(row.get("markers", "")).strip()
            if name not in markers_map:
                markers_map[name] = set()
            if m:
                markers_map[name].update(mk.strip() for mk in m.split(",") if mk.strip())
        repo_markers = {k: ",".join(sorted(v)) for k, v in markers_map.items()}
    else:
        repo_markers = {}

    unique_repos = list(dict.fromkeys(df_input["full_name"].tolist()))
    logger.info("Unique repos to process: %d", len(unique_repos))

    # -----------------------------------------------------------------------
    # Step 2a: Fast language pre-filter via repo search + intersection
    # -----------------------------------------------------------------------
    existing = _load_existing_metadata()
    logger.info("Already have full metadata for %d repos (resume support)", len(existing))

    target_lang = cfg["mining"]["language"]  # "Java"
    min_stars = cfg["mining"]["min_stars"]
    candidate_set = set(unique_repos)
    logger.info("Language pre-filter: finding %s repos via repo search + intersection", target_lang)

    # Strategy: search GitHub for Java repos matching base criteria,
    # then intersect with our marker-candidate list. Uses search API (30/min)
    # instead of checking 80K repos via core API (5K/hr).
    # Fine-grained star ranges to avoid the 1000-result cap per query.
    # Each range should ideally return <1000 results for complete coverage.
    # Ultra-fine star ranges: each range targets < 1000 results.
    star_ranges = (
        [(s, s) for s in range(min_stars, 100)]  # individual stars 5-99
        + [(s, s + 4) for s in range(100, 500, 5)]  # 5-star bands 100-499
        + [(s, s + 9) for s in range(500, 1000, 10)]  # 10-star bands 500-999
        + [(s, s + 49) for s in range(1000, 5000, 50)]  # 50-star bands 1K-5K
        + [(5000, 9999), (10000, 49999), (50000, 500000)]
    )
    java_from_search: set[str] = set()

    for lo, hi in star_ranges:
        q = f"language:{target_lang} stars:{lo}..{hi} pushed:>2024-01-01 archived:false fork:false"
        logger.info("Repo search: %s", q)
        time.sleep(2.5)  # search rate: 30/min
        try:
            results = g.search_repositories(q, sort="updated", order="desc")
            total = results.totalCount
            logger.info("  -> %d results for stars:%d..%d", total, lo, hi)
        except GithubException as e:
            logger.warning("Search error for stars:%d..%d: %s", lo, hi, e)
            continue

        # Collect up to 1000 results (API cap)
        page_num = 0
        collected = 0
        while collected < min(total, 1000):
            time.sleep(2.5)
            try:
                page = results.get_page(page_num)
            except GithubException as e:
                logger.warning("Page error at page %d: %s", page_num, e)
                break
            if not page:
                break
            for repo in page:
                java_from_search.add(repo.full_name)
                collected += 1
            page_num += 1
        logger.info("  -> Collected %d repos for stars:%d..%d", collected, lo, hi)

    logger.info("Total Java repos from search: %d", len(java_from_search))

    # Also include Java repos already in existing metadata
    for name, meta in existing.items():
        if meta.get("language") == target_lang and name in candidate_set:
            java_from_search.add(name)

    # Intersect with our marker-candidate list
    java_repos = [r for r in unique_repos if r in java_from_search]
    logger.info(
        "Intersection with %d marker candidates: %d %s repos",
        len(candidate_set), len(java_repos), target_lang,
    )

    # -----------------------------------------------------------------------
    # Step 2b: Fetch full metadata only for target-language repos
    # -----------------------------------------------------------------------
    to_fetch = [r for r in java_repos if r not in existing]
    logger.info("Need full metadata for %d %s repos", len(to_fetch), target_lang)

    for repo_name in tqdm(to_fetch, desc="Fetching metadata", unit="repo"):
        meta = _fetch_repo_metadata(g, repo_name, logger)
        if meta is not None:
            existing[meta["full_name"]] = meta
            _append_metadata(meta)
            logger.debug(
                "Fetched: %s (lang=%s, stars=%s)",
                meta["full_name"], meta["language"], meta["stargazers_count"],
            )
        else:
            logger.warning("Skipping %s - could not fetch metadata", repo_name)

    logger.info("Total metadata entries: %d", len(existing))

    # -----------------------------------------------------------------------
    # Step 3: Build metadata DataFrame
    # -----------------------------------------------------------------------
    # Only include repos from our input list
    records = []
    for repo_name in unique_repos:
        if repo_name in existing:
            entry = existing[repo_name].copy()
            entry["markers"] = repo_markers.get(repo_name, "")
            records.append(entry)

    if not records:
        logger.error("No metadata collected - nothing to filter")
        sys.exit(1)

    df = pd.DataFrame(records)
    total = len(df)
    logger.info("Starting filter funnel with %d repos", total)

    # -----------------------------------------------------------------------
    # Step 4: Apply filters
    # -----------------------------------------------------------------------
    min_stars = cfg["mining"]["min_stars"]
    activity_cutoff = "2024-01-01"
    min_size_kb = 2000  # lowered from 5000; LOC/package checks happen later

    # Filter: Java
    df_java = df[df["language"] == "Java"].copy()
    n_java = len(df_java)
    logger.info("  Filter: Java language      → %d / %d", n_java, total)

    # Filter: stars
    df_stars = df_java[df_java["stargazers_count"] >= min_stars].copy()
    n_stars = len(df_stars)
    logger.info("  Filter: stars >= %d         → %d / %d", min_stars, n_stars, n_java)

    # Filter: not archived
    df_active = df_stars[~df_stars["archived"]].copy()
    n_active = len(df_active)
    logger.info("  Filter: not archived        → %d / %d", n_active, n_stars)

    # Filter: not fork
    df_nofork = df_active[~df_active["fork"]].copy()
    n_nofork = len(df_nofork)
    logger.info("  Filter: not fork            → %d / %d", n_nofork, n_active)

    # Filter: size >= 5000 KB
    df_size = df_nofork[df_nofork["size"] >= min_size_kb].copy()
    n_size = len(df_size)
    logger.info("  Filter: size >= %d KB       → %d / %d", min_size_kb, n_size, n_nofork)

    # Filter: pushed_at > 2024-01-01
    df_size["pushed_at_dt"] = pd.to_datetime(df_size["pushed_at"], utc=True, errors="coerce")
    cutoff_dt = pd.Timestamp(activity_cutoff, tz="UTC")
    df_recent = df_size[df_size["pushed_at_dt"] > cutoff_dt].copy()
    n_recent = len(df_recent)
    logger.info("  Filter: pushed > %s  → %d / %d", activity_cutoff, n_recent, n_size)

    # -----------------------------------------------------------------------
    # Step 5: Content validation for weak-marker-only repos
    # -----------------------------------------------------------------------
    if has_markers:
        validated_flags: list[bool] = []
        needs_validation = []
        for idx, row in df_recent.iterrows():
            markers_str = str(row.get("markers", ""))
            if _has_only_weak_markers(markers_str):
                needs_validation.append((idx, row["full_name"], markers_str))
                validated_flags.append(False)  # placeholder
            else:
                validated_flags.append(True)  # high-reliability marker present

        # Validate weak-marker repos
        if needs_validation:
            logger.info(
                "Validating content for %d weak-marker-only repos...",
                len(needs_validation),
            )
            validated_indices: set[int] = set()
            for list_pos, (idx, full_name, markers_str) in enumerate(
                tqdm(needs_validation, desc="Validating markers", unit="repo")
            ):
                if _validate_weak_markers(g, full_name, markers_str, logger):
                    validated_indices.add(list_pos)

            # Update flags
            val_pos = 0
            updated_flags: list[bool] = []
            for flag in validated_flags:
                if flag:
                    updated_flags.append(True)
                else:
                    updated_flags.append(val_pos in validated_indices)
                    val_pos += 1
            validated_flags = updated_flags

        df_recent = df_recent.copy()
        df_recent["marker_validated"] = validated_flags
        df_validated = df_recent[df_recent["marker_validated"]].copy()
        n_validated = len(df_validated)
        logger.info("  Filter: marker validated    → %d / %d", n_validated, n_recent)
    else:
        df_validated = df_recent.copy()
        df_validated["marker_validated"] = True
        n_validated = len(df_validated)
        logger.info(
            "  Filter: marker validated    → %d / %d (no markers col)",
            n_validated, n_recent,
        )

    # -----------------------------------------------------------------------
    # Step 6: Log filtering funnel summary
    # -----------------------------------------------------------------------
    logger.info("-" * 50)
    logger.info("FILTERING FUNNEL SUMMARY")
    logger.info("-" * 50)
    logger.info("  Total repos:             %d", total)
    logger.info("  Java:                    %d", n_java)
    logger.info("  Stars >= %d:             %d", min_stars, n_stars)
    logger.info("  Not archived:            %d", n_active)
    logger.info("  Not fork:                %d", n_nofork)
    logger.info("  Size >= %d KB:           %d", min_size_kb, n_size)
    logger.info("  Active (pushed > %s): %d", activity_cutoff, n_recent)
    logger.info("  Marker validated:        %d", n_validated)
    logger.info("-" * 50)

    # -----------------------------------------------------------------------
    # Step 7: Save filtered output
    # -----------------------------------------------------------------------
    OUTPUT_CSV.parent.mkdir(parents=True, exist_ok=True)

    df_out = df_validated.copy()
    # Rename for output clarity
    df_out = df_out.rename(columns={
        "stargazers_count": "stars",
        "size": "size_kb",
        "forks_count": "forks",
    })
    out_cols_renamed = [
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
        "markers",
        "marker_validated",
    ]

    # Ensure all columns exist
    for col in out_cols_renamed:
        if col not in df_out.columns:
            df_out[col] = ""

    df_out = df_out[out_cols_renamed]

    # Drop temporary columns
    if "pushed_at_dt" in df_out.columns:
        df_out = df_out.drop(columns=["pushed_at_dt"])

    df_out.to_csv(OUTPUT_CSV, index=False)
    logger.info("Saved %d treatment candidates to %s", len(df_out), OUTPUT_CSV)

    # Log rate limit at end
    rl = g.get_rate_limit().resources.core
    logger.info("Rate limit at end: %d / %d remaining", rl.remaining, rl.limit)
    logger.info("Done.")


if __name__ == "__main__":
    main()
