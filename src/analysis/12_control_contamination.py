"""
12_control_contamination.py - Check control repos for AI tool adoption during study windows.

Scans each control repo's bare clone for:
  1. AI config files appearing in monthly snapshots (git ls-tree)
  2. Co-Authored-By commit trailers indicating AI tool usage (git log)

Outputs: data/interim/control_contamination.csv

NOTE: This is a full-pipeline (mining/extraction) validation step, NOT part of the
analysis-only path. It requires the bare clones in repos/, which are not shipped in
the replication package. If repos/ is absent it exits without writing, so it can never
overwrite the shipped frozen data/interim/control_contamination.csv.
"""

import csv
import logging
import re
import subprocess
from pathlib import Path

import yaml
from tqdm import tqdm

# ── Setup ──────────────────────────────────────────────────────────────────

ROOT = Path(__file__).resolve().parents[2]
cfg = yaml.safe_load((ROOT / "config/config.yaml").read_text())

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    handlers=[
        logging.StreamHandler(),
        logging.FileHandler(ROOT / "results/logs/12_control_contamination.log", mode="w"),
    ],
)
log = logging.getLogger(__name__)

# AI marker files to check in git tree
MARKER_FILES: list[str] = [
    ".cursorrules",
    ".github/copilot-instructions.md",
    "CLAUDE.md",
    "claude.md",
    ".aider.conf.yml",
    ".aider.model.settings.yml",
    "AGENTS.md",
]
# Prefix match for directories (any file under .cursor/rules/)
MARKER_PREFIXES: list[str] = [
    ".cursor/rules/",
]

# Commit body patterns
COMMIT_PATTERNS: list[re.Pattern] = [
    re.compile(r"Co-[Aa]uthored-[Bb]y:.*[Cc]laude", re.IGNORECASE),
    re.compile(r"Co-[Aa]uthored-[Bb]y:.*aider", re.IGNORECASE),
    re.compile(r"Co-[Aa]uthored-[Bb]y:.*[Cc]opilot", re.IGNORECASE),
    re.compile(r"\(aider\)"),
]

REPOS_DIR = ROOT / "repos"


def repo_dir_name(repo_name: str) -> str:
    """Convert 'owner/repo' to 'owner__repo' directory name."""
    return repo_name.replace("/", "__")


def git_cmd(git_dir: Path, args: list[str], timeout: int = 30) -> subprocess.CompletedProcess:
    """Run a git command on a bare repo."""
    cmd = ["git", f"--git-dir={git_dir}", *args]
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def get_snapshot_commit(git_dir: Path, date_str: str) -> str | None:
    """Get the latest commit before a given date (YYYY-MM-01 format)."""
    result = git_cmd(git_dir, [
        "rev-list", "-n", "1", "--first-parent", f"--before={date_str}", "HEAD"
    ])
    if result.returncode == 0 and result.stdout.strip():
        return result.stdout.strip()
    return None


def check_tree_for_markers(git_dir: Path, commit: str) -> list[tuple[str, str]]:
    """Check git tree at a commit for AI marker files. Returns list of (marker_type, path)."""
    result = git_cmd(git_dir, ["ls-tree", "-r", "--name-only", commit])
    if result.returncode != 0:
        return []

    files = set(result.stdout.strip().split("\n")) if result.stdout.strip() else set()
    found: list[tuple[str, str]] = []

    for marker in MARKER_FILES:
        if marker in files:
            found.append(("config_file", marker))

    for prefix in MARKER_PREFIXES:
        for f in files:
            if f.startswith(prefix):
                found.append(("config_file", f))
                break  # one match per prefix is enough

    return found


def check_commits_for_patterns(
    git_dir: Path, after_date: str, before_date: str
) -> list[tuple[str, str]]:
    """Scan commit messages in a date range for AI co-author patterns.
    Returns list of (pattern_label, commit_hash + subject)."""
    result = git_cmd(git_dir, [
        "log", "--format=%H%n%B%n---COMMIT_END---",
        "--first-parent",
        f"--after={after_date}",
        f"--before={before_date}",
    ], timeout=60)

    if result.returncode != 0 or not result.stdout.strip():
        return []

    found: list[tuple[str, str]] = []
    commits = result.stdout.split("---COMMIT_END---")

    for block in commits:
        block = block.strip()
        if not block:
            continue
        lines = block.split("\n")
        commit_hash = lines[0][:12] if lines else "unknown"

        for pattern in COMMIT_PATTERNS:
            if pattern.search(block):
                # Extract the matching line for details
                for line in lines:
                    if pattern.search(line):
                        found.append(("commit_pattern", f"{commit_hash}: {line.strip()}"))
                        break
                else:
                    found.append(("commit_pattern", f"{commit_hash}: (pattern in body)"))

    return found


def next_month(ym: str) -> str:
    """Given 'YYYY-MM', return the next month as 'YYYY-MM'."""
    y, m = int(ym[:4]), int(ym[5:7])
    m += 1
    if m > 12:
        m = 1
        y += 1
    return f"{y:04d}-{m:02d}"


def main() -> None:
    # ── Guard: require bare clones in repos/ ───────────────────────────
    # repos/ is not shipped with the replication package. Without it every
    # control would be marked 'unknown', so we must NOT write (it would clobber
    # the shipped frozen data/interim/control_contamination.csv). Exit cleanly.
    if not REPOS_DIR.exists():
        log.warning(
            "repos/ not found at %s; skipping contamination scan and leaving the "
            "shipped data/interim/control_contamination.csv untouched. This step is "
            "part of the full mining/extraction pipeline, not the analysis-only path.",
            REPOS_DIR,
        )
        return

    # ── Load matching.csv ──────────────────────────────────────────────
    matching_path = ROOT / "data/processed/matching.csv"
    with open(matching_path) as f:
        reader = csv.DictReader(f)
        control_repos = [row["control_repo"] for row in reader]
    log.info("Loaded %d control repos from matching.csv", len(control_repos))

    # ── Load panel_monthly.csv → get study window per control repo ─────
    panel_path = ROOT / "data/processed/panel_monthly.csv"
    control_windows: dict[str, tuple[str, str]] = {}  # repo_name → (min_month, max_month)
    with open(panel_path) as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row["is_treatment"] == "0":
                name = row["repo_name"]
                month = row["month"]
                if name not in control_windows:
                    control_windows[name] = (month, month)
                else:
                    mn, mx = control_windows[name]
                    if month < mn:
                        mn = month
                    if month > mx:
                        mx = month
                    control_windows[name] = (mn, mx)

    log.info("Found study windows for %d control repos in panel", len(control_windows))

    # ── Scan each control repo ─────────────────────────────────────────
    results: list[dict] = []
    contaminated_count = 0
    missing_count = 0

    for repo_name in tqdm(control_repos, desc="Scanning controls"):
        dir_name = repo_dir_name(repo_name)
        git_dir = REPOS_DIR / dir_name

        if not git_dir.exists():
            log.warning("Missing clone for %s (expected %s)", repo_name, git_dir)
            results.append({
                "repo_name": repo_name,
                "contaminated": "unknown",
                "first_ai_month": "",
                "marker_type": "",
                "details": "clone not found",
            })
            missing_count += 1
            continue

        # Get study window
        if repo_name not in control_windows:
            log.warning("No panel data for control %s", repo_name)
            results.append({
                "repo_name": repo_name,
                "contaminated": "unknown",
                "first_ai_month": "",
                "marker_type": "",
                "details": "not in panel",
            })
            continue

        min_month, max_month = control_windows[repo_name]
        all_markers: list[tuple[str, str, str]] = []  # (month, marker_type, detail)

        # Check each month's snapshot for config files
        current = min_month
        while current <= max_month:
            date_str = f"{current}-01"
            commit = get_snapshot_commit(git_dir, date_str)
            if commit:
                tree_markers = check_tree_for_markers(git_dir, commit)
                for mtype, detail in tree_markers:
                    all_markers.append((current, mtype, detail))
            current = next_month(current)

        # Check commits in the full window for AI patterns
        after_date = f"{min_month}-01"
        # Go one month past max to capture commits in the last month
        end_month = next_month(max_month)
        before_date = f"{end_month}-01"

        commit_markers = check_commits_for_patterns(git_dir, after_date, before_date)
        for mtype, detail in commit_markers:
            # Approximate month from commit - use first month as conservative
            all_markers.append(("window", mtype, detail))

        if all_markers:
            contaminated_count += 1
            # Sort to find earliest month
            sorted_markers = sorted(all_markers, key=lambda x: x[0])
            first_month = sorted_markers[0][0]
            marker_types = sorted(set(m[1] for m in all_markers))
            details = "; ".join(f"[{m[0]}] {m[1]}: {m[2]}" for m in sorted_markers[:5])
            if len(all_markers) > 5:
                details += f"; ... and {len(all_markers) - 5} more"

            results.append({
                "repo_name": repo_name,
                "contaminated": "yes",
                "first_ai_month": first_month,
                "marker_type": "|".join(marker_types),
                "details": details,
            })
            log.info("CONTAMINATED: %s - first=%s, types=%s", repo_name, first_month, marker_types)
        else:
            results.append({
                "repo_name": repo_name,
                "contaminated": "no",
                "first_ai_month": "",
                "marker_type": "",
                "details": "",
            })

    # ── Write output ───────────────────────────────────────────────────
    output_path = ROOT / "data/interim/control_contamination.csv"
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with open(output_path, "w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=[
            "repo_name", "contaminated", "first_ai_month", "marker_type", "details"
        ])
        writer.writeheader()
        writer.writerows(results)

    log.info("Wrote %s", output_path)

    # ── Summary ────────────────────────────────────────────────────────
    total = len(control_repos)
    clean = sum(1 for r in results if r["contaminated"] == "no")
    unknown = sum(1 for r in results if r["contaminated"] == "unknown")

    print("\n" + "=" * 60)
    print("CONTROL CONTAMINATION CHECK - SUMMARY")
    print("=" * 60)
    print(f"Total control repos:    {total}")
    print(f"Clean (no AI markers):  {clean}")
    print(f"Contaminated:           {contaminated_count}")
    print(f"Unknown (missing):      {unknown}")
    print(f"Contamination rate:     {contaminated_count}/{total - unknown} = "
          f"{contaminated_count / max(total - unknown, 1) * 100:.1f}%")
    print()

    if contaminated_count > 0:
        print("Contaminated repos:")
        for r in results:
            if r["contaminated"] == "yes":
                print(f"  - {r['repo_name']}: first={r['first_ai_month']}, "
                      f"type={r['marker_type']}")
        print()

    print(f"Output: {output_path}")
    print("=" * 60)


if __name__ == "__main__":
    main()
