"""Git commit parsing utilities for AI tool adoption detection."""

import logging
import re
import subprocess
from collections import Counter
from datetime import datetime

logger = logging.getLogger(__name__)


def _run_git(repo_path: str, args: list[str], timeout: int = 30) -> str | None:
    """Run a git command in a repo directory, return stdout or None on error."""
    cmd = ["git", "-C", repo_path] + args
    try:
        result = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=True
        )
        return result.stdout
    except subprocess.CalledProcessError as e:
        logger.debug(f"git command failed in {repo_path}: {' '.join(cmd)}\n{e.stderr.strip()}")
        return None
    except subprocess.TimeoutExpired:
        logger.warning(f"git command timed out ({timeout}s) in {repo_path}: {' '.join(cmd)}")
        return None


def _parse_iso_date(iso_str: str) -> datetime:
    """Parse an ISO 8601 date string from git into a timezone-aware datetime."""
    return datetime.fromisoformat(iso_str)


def find_file_additions(repo_path: str, filenames: list[str]) -> list[dict]:
    """Find commits where specific files were first added to the repo.

    For each filename, finds ALL additions (covers file added, deleted, re-added).
    Returns list of dicts with: filename, commit_hash, date, detail.
    """
    results = []
    for filename in filenames:
        output = _run_git(
            repo_path,
            [
                "log", "--all", "--diff-filter=A", "--reverse",
                "--format=%H %aI", "--", filename,
            ],
            timeout=30,
        )
        if output is None:
            continue

        for line in output.strip().splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            commit_hash, date_str = parts
            try:
                date = _parse_iso_date(date_str)
            except ValueError:
                logger.debug(f"Could not parse date '{date_str}' for {filename}")
                continue
            results.append({
                "filename": filename,
                "commit_hash": commit_hash,
                "date": date,
                "detail": f"file_add:{filename}",
            })

    return results


def find_commit_patterns(repo_path: str, patterns: list[str]) -> list[dict]:
    """Find commits whose messages match regex patterns.

    Returns list of dicts with: pattern, commit_hash, date.
    """
    results = []
    seen_hashes: set[str] = set()

    for pattern in patterns:
        output = _run_git(
            repo_path,
            [
                "log", "--all", "-E", f"--grep={pattern}",
                "--reverse", "--format=%H %aI",
            ],
            timeout=30,
        )
        if output is None:
            continue

        for line in output.strip().splitlines():
            line = line.strip()
            if not line:
                continue
            parts = line.split(" ", 1)
            if len(parts) != 2:
                continue
            commit_hash, date_str = parts
            if commit_hash in seen_hashes:
                continue
            seen_hashes.add(commit_hash)
            try:
                date = _parse_iso_date(date_str)
            except ValueError:
                logger.debug(f"Could not parse date '{date_str}' for pattern '{pattern}'")
                continue
            results.append({
                "pattern": pattern,
                "commit_hash": commit_hash,
                "date": date,
            })

    return results


def get_commit_dates(repo_path: str) -> list[datetime]:
    """Get all commit author dates in the repo, sorted chronologically."""
    output = _run_git(repo_path, ["log", "--all", "--format=%aI"], timeout=60)
    if output is None:
        return []

    dates = []
    for line in output.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            dates.append(_parse_iso_date(line))
        except ValueError:
            continue

    dates.sort()
    return dates


def count_commits_per_month(dates: list[datetime]) -> dict[tuple[int, int], int]:
    """Group commit dates by (year, month) and return counts."""
    return dict(Counter((d.year, d.month) for d in dates))


def _identify_tool(detail: str) -> str:
    """Extract the AI tool name from a detection detail string."""
    # Strip regex syntax for matching (e.g., [Cc]laude -> claude)
    cleaned = re.sub(r"\[.(.)\]", r"\1", detail).lower()
    if ".cursorrules" in cleaned or ".cursor/" in cleaned:
        return "cursor"
    if "copilot" in cleaned:
        return "copilot"
    if "claude" in cleaned:
        return "claude_code"
    if "aider" in cleaned:
        return "aider"
    if "agents.md" in cleaned:
        return "codex"
    return "unknown"


def detect_adoption(
    repo_path: str,
    marker_files: list[str],
    commit_patterns: list[str],
) -> dict | None:
    """Detect AI tool adoption by combining file additions and commit pattern matches.

    Returns dict with: adoption_date, adoption_signal, adoption_detail,
    total_ai_events, ai_tools_detected. Returns None if no AI events found.
    """
    file_events = find_file_additions(repo_path, marker_files)
    pattern_events = find_commit_patterns(repo_path, commit_patterns)

    # Build unified event list
    all_events: list[dict] = []
    for ev in file_events:
        all_events.append({
            "date": ev["date"],
            "signal": "file_add",
            "detail": ev["detail"],
            "commit_hash": ev["commit_hash"],
        })
    for ev in pattern_events:
        all_events.append({
            "date": ev["date"],
            "signal": "commit_pattern",
            "detail": f"pattern:{ev['pattern']}",
            "commit_hash": ev["commit_hash"],
        })

    if not all_events:
        return None

    # Sort by date, earliest first
    all_events.sort(key=lambda e: e["date"])

    first = all_events[0]
    tools_detected = sorted(set(_identify_tool(e["detail"]) for e in all_events))

    return {
        "adoption_date": first["date"].isoformat(),
        "adoption_signal": first["signal"],
        "adoption_detail": first["detail"],
        "total_ai_events": len(all_events),
        "ai_tools_detected": tools_detected,
    }


def validate_windows(
    repo_path: str,
    adoption_date: datetime,
    min_pre_months: int,
    min_post_months: int,
    min_commits_per_month: float,
) -> dict:
    """Validate that a repo has sufficient pre/post adoption commit history.

    Returns dict with: valid, pre_months, post_months, total_commits,
    avg_commits_per_month, first_commit, last_commit, reason.
    """
    dates = get_commit_dates(repo_path)

    if not dates:
        return {
            "valid": False,
            "pre_months": 0,
            "post_months": 0,
            "total_commits": 0,
            "avg_commits_per_month": 0.0,
            "first_commit": None,
            "last_commit": None,
            "reason": "no commits found",
        }

    first_commit = dates[0]
    last_commit = dates[-1]
    total_commits = len(dates)

    # Calculate months between two dates
    def months_between(d1: datetime, d2: datetime) -> int:
        return (d2.year - d1.year) * 12 + (d2.month - d1.month)

    # Make adoption_date offset-aware if needed for comparison
    adoption_naive = adoption_date.replace(tzinfo=None) if adoption_date.tzinfo else adoption_date
    first_naive = first_commit.replace(tzinfo=None) if first_commit.tzinfo else first_commit
    last_naive = last_commit.replace(tzinfo=None) if last_commit.tzinfo else last_commit

    pre_months = months_between(first_naive, adoption_naive)
    post_months = months_between(adoption_naive, last_naive)

    monthly_counts = count_commits_per_month(dates)
    avg_commits_per_month = total_commits / max(len(monthly_counts), 1)

    result = {
        "valid": True,
        "pre_months": pre_months,
        "post_months": post_months,
        "total_commits": total_commits,
        "avg_commits_per_month": round(avg_commits_per_month, 2),
        "first_commit": first_commit.isoformat(),
        "last_commit": last_commit.isoformat(),
        "reason": None,
    }

    if pre_months < min_pre_months:
        result["valid"] = False
        result["reason"] = (
            f"insufficient pre-adoption history ({pre_months} < {min_pre_months} months)"
        )
    elif post_months < min_post_months:
        result["valid"] = False
        result["reason"] = (
            f"insufficient post-adoption history ({post_months} < {min_post_months} months)"
        )
    elif avg_commits_per_month < min_commits_per_month:
        result["valid"] = False
        result["reason"] = (
            f"low commit frequency ({avg_commits_per_month:.1f} < {min_commits_per_month}/month)"
        )

    return result
