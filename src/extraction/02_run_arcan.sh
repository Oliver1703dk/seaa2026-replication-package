#!/usr/bin/env bash
# Run Arcan analysis on each snapshot from the manifest.
# Idempotent: skips snapshots that already have CSV output.
# Usage: PARALLEL=4 MEM_LIMIT=4g bash src/extraction/02_run_arcan.sh
#
# NOTE: Arcan's JVM is hardcoded to -Xmx6G internally. When the container
# memory limit is less than 6G, the JVM often hangs after analysis completes
# (GC-thrashing at the cgroup ceiling). We work around this with a per-container
# timeout: once the timeout fires, we kill the container. Success is determined
# by checking if output CSV files were written, not by exit code.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

REPOS_DIR="$PROJECT_ROOT/repos"
MANIFEST="$PROJECT_ROOT/data/interim/snapshot_manifest.csv"
ARCAN_OUT_DIR="$PROJECT_ROOT/data/raw/arcan_output"
STATUS_CSV="$PROJECT_ROOT/data/interim/arcan_status.csv"
LOG_FILE="$PROJECT_ROOT/results/logs/02_run_arcan.log"

PARALLEL=${PARALLEL:-4}
MEM_LIMIT=${MEM_LIMIT:-4g}
DOCKER_TIMEOUT=${DOCKER_TIMEOUT:-900}  # 15 min per container
ARCAN_IMAGE="ghcr.io/arcan-tech/arcan-2-cli-trial@sha256:582e95358473c01ad03b6e74830eb6f6263d1aed9beeae5a454015ae36c9f602"

mkdir -p "$ARCAN_OUT_DIR" "$(dirname "$STATUS_CSV")" "$(dirname "$LOG_FILE")"

# --- Pre-flight checks ---
if ! docker info > /dev/null 2>&1; then
    echo "ERROR: Docker is not running. Start Docker Desktop first." >&2
    exit 1
fi

echo "=== Arcan run started at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee "$LOG_FILE"
echo "Parallel: $PARALLEL, Memory: $MEM_LIMIT, Timeout: ${DOCKER_TIMEOUT}s, Image: $ARCAN_IMAGE" | tee -a "$LOG_FILE"

# Status CSV header (append mode - only write header if file is new)
if [ ! -f "$STATUS_CSV" ]; then
    echo "repo_name,dir_name,month,commit_sha,arcan_status,duration_s" > "$STATUS_CSV"
fi

# Count total and already-completed work
TOTAL=$(tail -n +2 "$MANIFEST" | tr -d '\r' | grep -c ',found$' || true)
ALREADY_DONE=0
if [ -f "$STATUS_CSV" ]; then
    ALREADY_DONE=$(tail -n +2 "$STATUS_CSV" | grep -c ',ok,' || true)
fi
echo "Total found snapshots: $TOTAL, already completed: $ALREADY_DONE" | tee -a "$LOG_FILE"

# Counters
TMPDIR_STATS="$(mktemp -d)"
echo 0 > "$TMPDIR_STATS/done"
echo 0 > "$TMPDIR_STATS/ok"
echo 0 > "$TMPDIR_STATS/failed"
echo 0 > "$TMPDIR_STATS/skipped"
trap 'rm -rf "$TMPDIR_STATS"' EXIT

inc_counter() {
    local name="$1"
    local lock="$TMPDIR_STATS/${name}.lock"
    while ! mkdir "$lock" 2>/dev/null; do :; done
    local val
    val=$(cat "$TMPDIR_STATS/$name")
    echo $((val + 1)) > "$TMPDIR_STATS/$name"
    rmdir "$lock"
}

process_snapshot() {
    local line="$1"
    IFS=',' read -r repo_name dir_name month commit_sha is_treatment first_treat status <<< "$line"

    local snapshot_id="${dir_name}__${month}"
    local output_dir="$ARCAN_OUT_DIR/$snapshot_id"

    # Idempotent: skip if CSV output already exists
    if ls "$output_dir/arcanOutput/"*/*.csv >/dev/null 2>&1; then
        inc_counter skipped
        inc_counter done
        return 0
    fi

    local tmp_dir="/tmp/arcan_${snapshot_id}"
    local repo_path="$REPOS_DIR/$dir_name"
    local start_ts
    start_ts=$(date +%s)

    # Extract source tree from bare repo into a 'project' subdir
    rm -rf "$tmp_dir"
    mkdir -p "$tmp_dir/project"
    if ! git -C "$repo_path" archive "$commit_sha" 2>/dev/null | tar -x -C "$tmp_dir/project" 2>/dev/null; then
        local end_ts
        end_ts=$(date +%s)
        echo "$repo_name,$dir_name,$month,$commit_sha,fail_extract,$((end_ts - start_ts))" >> "$STATUS_CSV"
        echo "$(date -u +%H:%M:%S) [FAIL_EXTRACT] $repo_name $month" >> "$LOG_FILE"
        inc_counter failed
        inc_counter done
        rm -rf "$tmp_dir"
        return 0
    fi

    mkdir -p "$output_dir"

    # Unique container name for timeout management
    local container_name="arcan_${snapshot_id//[^a-zA-Z0-9_.-]/_}"

    # Run Arcan Docker with a background timeout watchdog.
    # Arcan's JVM has -Xmx6G hardcoded; when container memory < 6G the JVM
    # often hangs after analysis completes. The watchdog kills it.
    docker run --rm --platform linux/amd64 \
        --name "$container_name" \
        --memory="$MEM_LIMIT" \
        -v "$tmp_dir/project":/data/project:ro \
        -v "$output_dir":/data/output \
        "$ARCAN_IMAGE" \
        analyze -i /data/project -o /data/output -l JAVA --all >> "$LOG_FILE" 2>&1 &
    local docker_pid=$!

    # Watchdog: kill container after DOCKER_TIMEOUT seconds
    ( sleep "$DOCKER_TIMEOUT" && docker kill "$container_name" >/dev/null 2>&1 ) &
    local timer_pid=$!

    # Wait for docker to exit (either naturally or killed by watchdog)
    wait $docker_pid 2>/dev/null
    local docker_exit=$?

    # Cancel the watchdog if docker exited before timeout
    kill $timer_pid 2>/dev/null
    wait $timer_pid 2>/dev/null

    local end_ts
    end_ts=$(date +%s)
    local duration=$((end_ts - start_ts))

    # Success = output CSV files exist (regardless of exit code, since
    # the JVM may hang after writing output and get killed by watchdog)
    if ls "$output_dir/arcanOutput/"*/*.csv >/dev/null 2>&1; then
        echo "$repo_name,$dir_name,$month,$commit_sha,ok,$duration" >> "$STATUS_CSV"
        if [ $docker_exit -ne 0 ]; then
            echo "$(date -u +%H:%M:%S) [OK_KILLED] $repo_name $month (exit=$docker_exit, ${duration}s - output exists)" >> "$LOG_FILE"
        fi
        inc_counter ok
    else
        echo "$repo_name,$dir_name,$month,$commit_sha,fail_arcan,$duration" >> "$STATUS_CSV"
        echo "$(date -u +%H:%M:%S) [FAIL_ARCAN] $repo_name $month (exit=$docker_exit, ${duration}s)" >> "$LOG_FILE"
        inc_counter failed
    fi

    # Progress
    inc_counter done
    local done_count
    done_count=$(cat "$TMPDIR_STATS/done")
    printf "\r  Progress: %d / %d snapshots" "$done_count" "$TOTAL" >&2

    # Cleanup
    rm -rf "$tmp_dir"
}
export -f process_snapshot inc_counter
export REPOS_DIR ARCAN_OUT_DIR STATUS_CSV LOG_FILE MEM_LIMIT DOCKER_TIMEOUT ARCAN_IMAGE TMPDIR_STATS TOTAL

# --- Run in parallel ---
echo "" >&2
# Shuffle to interleave repos - prevents large repos from blocking all slots
tail -n +2 "$MANIFEST" | tr -d '\r' | grep ',found$' | sort -R | \
    xargs -P "$PARALLEL" -I {} bash -c 'process_snapshot "$@"' _ {}
echo "" >&2

# --- Summary ---
OK_COUNT=$(cat "$TMPDIR_STATS/ok")
FAILED_COUNT=$(cat "$TMPDIR_STATS/failed")
SKIPPED_COUNT=$(cat "$TMPDIR_STATS/skipped")

echo "" | tee -a "$LOG_FILE"
echo "=== Arcan Summary ===" | tee -a "$LOG_FILE"
echo "  OK:      $OK_COUNT" | tee -a "$LOG_FILE"
echo "  Failed:  $FAILED_COUNT" | tee -a "$LOG_FILE"
echo "  Skipped: $SKIPPED_COUNT (already done)" | tee -a "$LOG_FILE"
echo "=== Done at $(date -u +%Y-%m-%dT%H:%M:%SZ) ===" | tee -a "$LOG_FILE"

if [ "$FAILED_COUNT" -gt 0 ]; then
    echo ""
    echo "TIP: Re-run this script to retry failed snapshots (idempotent)."
    echo "     Failures logged in $STATUS_CSV and $LOG_FILE"
fi
