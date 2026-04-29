#!/usr/bin/env bash
# Clone all treatment and control repos as bare repos.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPOS_DIR="$PROJECT_ROOT/repos"
PARALLEL_JOBS=8
LOG_DIR="$PROJECT_ROOT/results/logs"
LOG_FILE="$LOG_DIR/clone.log"
TREATMENT_CSV="$PROJECT_ROOT/config/repo_lists/treatment_final.csv"
CONTROL_CSV="$PROJECT_ROOT/config/repo_lists/control_candidates.csv"

MODE="${1:-all}"

mkdir -p "$REPOS_DIR" "$LOG_DIR"

# Initialize log
echo "=== Clone started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG_FILE"
echo "Mode: $MODE" >> "$LOG_FILE"

# Counters stored in temp files for xargs subshell compatibility
TMPDIR_STATS="$(mktemp -d)"
echo "0" > "$TMPDIR_STATS/success"
echo "0" > "$TMPDIR_STATS/failed"
echo "0" > "$TMPDIR_STATS/skipped"
trap 'rm -rf "$TMPDIR_STATS"' EXIT

clone_repo() {
    local full_name="$1"
    local dir_name="${full_name//\//__}"
    local target_dir="$REPOS_DIR/$dir_name"
    local timestamp
    timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if [ -d "$target_dir" ]; then
        echo "$timestamp [SKIP] $full_name (already exists)" >> "$LOG_FILE"
        # Increment skipped counter atomically
        local lock="$TMPDIR_STATS/skipped.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/skipped"); echo $((val + 1)) > "$TMPDIR_STATS/skipped"
        rmdir "$lock"
        return 0
    fi

    if git clone --bare --single-branch "https://github.com/${full_name}.git" "$target_dir" 2>/dev/null; then
        echo "$timestamp [OK]   $full_name" >> "$LOG_FILE"
        local lock="$TMPDIR_STATS/success.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/success"); echo $((val + 1)) > "$TMPDIR_STATS/success"
        rmdir "$lock"
    else
        echo "$timestamp [FAIL] $full_name" >> "$LOG_FILE"
        local lock="$TMPDIR_STATS/failed.lock"
        while ! mkdir "$lock" 2>/dev/null; do :; done
        local val; val=$(cat "$TMPDIR_STATS/failed"); echo $((val + 1)) > "$TMPDIR_STATS/failed"
        rmdir "$lock"
    fi
}
export -f clone_repo
export REPOS_DIR LOG_FILE TMPDIR_STATS

extract_names() {
    local csv_file="$1"
    if [ ! -f "$csv_file" ]; then
        echo "WARNING: $csv_file not found, skipping." >&2
        echo "WARNING: $csv_file not found" >> "$LOG_FILE"
        return
    fi
    # Column 1 (full_name), skip header
    tail -n +2 "$csv_file" | cut -d',' -f1 | sed 's/"//g' | grep -v '^$'
}

# Build list of repos to clone
REPO_LIST=""

case "$MODE" in
    treatment)
        echo "Cloning treatment repos from $TREATMENT_CSV"
        REPO_LIST="$(extract_names "$TREATMENT_CSV")"
        ;;
    control)
        echo "Cloning control repos from $CONTROL_CSV"
        REPO_LIST="$(extract_names "$CONTROL_CSV")"
        ;;
    all)
        echo "Cloning all repos (treatment + control)"
        TREATMENT_LIST="$(extract_names "$TREATMENT_CSV")"
        CONTROL_LIST="$(extract_names "$CONTROL_CSV")"
        REPO_LIST="$(printf '%s\n%s' "$TREATMENT_LIST" "$CONTROL_LIST" | grep -v '^$' | sort -u)"
        ;;
    *)
        echo "Usage: $0 [treatment|control|all]" >&2
        exit 1
        ;;
esac

TOTAL=$(echo "$REPO_LIST" | grep -c -v '^$' || true)

if [ "$TOTAL" -eq 0 ]; then
    echo "No repos to clone."
    echo "No repos to clone." >> "$LOG_FILE"
    exit 0
fi

echo "Total repos to process: $TOTAL"
echo "Parallel jobs: $PARALLEL_JOBS"
echo "Target directory: $REPOS_DIR"
echo ""

# Clone in parallel using xargs
# set +e locally so xargs doesn't abort on individual clone failures
set +e
echo "$REPO_LIST" | xargs -P "$PARALLEL_JOBS" -I {} bash -c 'clone_repo "$@"' _ {}
set -e

# Read final counters
SUCCESS=$(cat "$TMPDIR_STATS/success")
FAILED=$(cat "$TMPDIR_STATS/failed")
SKIPPED=$(cat "$TMPDIR_STATS/skipped")

# Summary
echo ""
echo "=== Clone Summary ==="
echo "  Total:   $TOTAL"
echo "  Success: $SUCCESS"
echo "  Failed:  $FAILED"
echo "  Skipped: $SKIPPED"

echo "=== Clone finished at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" >> "$LOG_FILE"
echo "Summary: total=$TOTAL success=$SUCCESS failed=$FAILED skipped=$SKIPPED" >> "$LOG_FILE"
