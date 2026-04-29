#!/usr/bin/env bash
# Clone matched control repos that are not yet in repos/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOS_DIR="$PROJECT_ROOT/repos"
MATCHING_CSV="$PROJECT_ROOT/data/processed/matching.csv"
LOG_DIR="$PROJECT_ROOT/results/logs"
LOG_FILE="$LOG_DIR/00_clone_missing_controls.log"
PARALLEL_JOBS=8

mkdir -p "$REPOS_DIR" "$LOG_DIR"
echo "=== Clone missing controls started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee "$LOG_FILE"

# Counters (temp files for xargs subprocess compatibility)
TMPDIR_STATS="$(mktemp -d)"
echo 0 > "$TMPDIR_STATS/success"
echo 0 > "$TMPDIR_STATS/failed"
echo 0 > "$TMPDIR_STATS/skipped"
trap 'rm -rf "$TMPDIR_STATS"' EXIT

clone_repo() {
    local full_name="$1"
    local dir_name="${full_name//\//__}"
    local target_dir="$REPOS_DIR/$dir_name"
    local ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -d "$target_dir" ]; then
        echo "$ts [SKIP] $full_name" >> "$LOG_FILE"
        local lock="$TMPDIR_STATS/skipped.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/skipped"); echo $((val + 1)) > "$TMPDIR_STATS/skipped"
        rmdir "$lock"
        return 0
    fi

    echo "  Cloning $full_name ..."
    if git clone --bare --single-branch \
        "https://github.com/${full_name}.git" "$target_dir" 2>> "$LOG_FILE"; then
        echo "$ts [OK]   $full_name" >> "$LOG_FILE"
        local lock="$TMPDIR_STATS/success.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/success"); echo $((val + 1)) > "$TMPDIR_STATS/success"
        rmdir "$lock"
    else
        echo "$ts [FAIL] $full_name" >> "$LOG_FILE"
        rm -rf "$target_dir"
        local lock="$TMPDIR_STATS/failed.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/failed"); echo $((val + 1)) > "$TMPDIR_STATS/failed"
        rmdir "$lock"
    fi
}
export -f clone_repo
export REPOS_DIR LOG_FILE TMPDIR_STATS

# Find missing control repos
MISSING_REPOS=""
while IFS=',' read -r _treatment control _rest; do
    dir_name="${control//\//__}"
    if [ ! -d "$REPOS_DIR/$dir_name" ]; then
        MISSING_REPOS+="$control"$'\n'
    fi
done < <(tail -n +2 "$MATCHING_CSV")

MISSING_REPOS="$(echo "$MISSING_REPOS" | grep -v '^$' | sort -u)"
TOTAL=$(echo "$MISSING_REPOS" | grep -c -v '^$' || true)

if [ "$TOTAL" -eq 0 ]; then
    echo "All control repos already cloned."
    exit 0
fi

echo "Missing control repos: $TOTAL"
echo "Parallel jobs: $PARALLEL_JOBS"
echo ""

set +e
echo "$MISSING_REPOS" | xargs -P "$PARALLEL_JOBS" -I {} bash -c 'clone_repo "$@"' _ {}
set -e

SUCCESS=$(cat "$TMPDIR_STATS/success")
FAILED=$(cat "$TMPDIR_STATS/failed")
SKIPPED=$(cat "$TMPDIR_STATS/skipped")

echo ""
echo "=== Summary ==="
echo "  Total:   $TOTAL"
echo "  Cloned:  $SUCCESS"
echo "  Failed:  $FAILED"
echo "  Skipped: $SKIPPED"
echo "=== Done at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$LOG_FILE"

if [ "$FAILED" -gt 0 ]; then
    echo ""
    echo "WARNING: $FAILED repos failed. Check $LOG_FILE"
    echo "These repos will be absent from extraction. Re-run to retry."
fi
