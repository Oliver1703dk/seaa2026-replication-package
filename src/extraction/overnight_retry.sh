#!/usr/bin/env bash
# Overnight retry orchestration for Arcan batch.
# Waits for main batch (PID 1283) to finish, then runs tiered retries.
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$PROJECT_ROOT"

LOG="results/logs/overnight_retry.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }

log "=== Overnight Retry Started ==="

# --- Phase 1: Wait for main batch to finish ---
MAIN_PID=1283
if ps -p $MAIN_PID > /dev/null 2>&1; then
    log "Waiting for main batch PID $MAIN_PID to finish..."
    while ps -p $MAIN_PID > /dev/null 2>&1; do
        sleep 60
    done
    log "Main batch PID $MAIN_PID exited."
else
    log "Main batch PID $MAIN_PID already exited."
fi

# Give a moment for any cleanup
sleep 10

# --- Phase 2: Count remaining ---
count_missing() {
    python3 -c "
from pathlib import Path
import csv
manifest = Path('data/interim/snapshot_manifest.csv')
arcan_out = Path('data/raw/arcan_output')
missing = 0
with open(manifest) as f:
    for row in csv.DictReader(f):
        if row['status'].strip() != 'found':
            continue
        snap_id = f\"{row['dir_name']}__{row['month']}\"
        out_dir = arcan_out / snap_id / 'arcanOutput'
        has_csv = False
        if out_dir.is_dir():
            for sub in out_dir.iterdir():
                if sub.is_dir() and any(sub.glob('*.csv')):
                    has_csv = True
                    break
        if not has_csv:
            missing += 1
print(missing)
"
}

MISSING_BEFORE=$(count_missing)
log "Missing snapshots after main batch: $MISSING_BEFORE"

if [ "$MISSING_BEFORE" -eq 0 ]; then
    log "All snapshots have output! No retry needed."
    log "=== Overnight Complete ==="
    exit 0
fi

# --- Phase 3: Retry Tier 1 - PARALLEL=4, MEM=4g, TIMEOUT=1800 (30 min) ---
log "=== Retry Tier 1: PARALLEL=4 MEM_LIMIT=4g DOCKER_TIMEOUT=1800 ==="
PARALLEL=4 MEM_LIMIT=4g DOCKER_TIMEOUT=1800 bash src/extraction/02_run_arcan.sh 2>&1 | tee -a "$LOG" || true

MISSING_AFTER_T1=$(count_missing)
RECOVERED_T1=$((MISSING_BEFORE - MISSING_AFTER_T1))
log "Tier 1 recovered: $RECOVERED_T1 snapshots (remaining: $MISSING_AFTER_T1)"

if [ "$MISSING_AFTER_T1" -eq 0 ]; then
    log "All snapshots recovered after Tier 1!"
else
    # --- Phase 4: Retry Tier 2 - PARALLEL=2, MEM=8g, TIMEOUT=2700 (45 min) ---
    log "=== Retry Tier 2: PARALLEL=2 MEM_LIMIT=8g DOCKER_TIMEOUT=2700 ==="
    PARALLEL=2 MEM_LIMIT=8g DOCKER_TIMEOUT=2700 bash src/extraction/02_run_arcan.sh 2>&1 | tee -a "$LOG" || true

    MISSING_AFTER_T2=$(count_missing)
    RECOVERED_T2=$((MISSING_AFTER_T1 - MISSING_AFTER_T2))
    log "Tier 2 recovered: $RECOVERED_T2 snapshots (remaining: $MISSING_AFTER_T2)"

    if [ "$MISSING_AFTER_T2" -gt 0 ]; then
        # --- Phase 5: Retry Tier 3 - PARALLEL=1, MEM=16g, TIMEOUT=3600 (1 hr) ---
        log "=== Retry Tier 3: PARALLEL=1 MEM_LIMIT=16g DOCKER_TIMEOUT=3600 ==="
        PARALLEL=1 MEM_LIMIT=16g DOCKER_TIMEOUT=3600 bash src/extraction/02_run_arcan.sh 2>&1 | tee -a "$LOG" || true

        MISSING_AFTER_T3=$(count_missing)
        RECOVERED_T3=$((MISSING_AFTER_T2 - MISSING_AFTER_T3))
        log "Tier 3 recovered: $RECOVERED_T3 snapshots (remaining: $MISSING_AFTER_T3)"
    fi
fi

# --- Phase 6: Re-run post-processing ---
log "=== Re-running post-processing pipeline ==="
uv run python src/extraction/03_parse_arcan_output.py 2>&1 | tee -a "$LOG"
uv run python src/extraction/04_compute_metrics.py 2>&1 | tee -a "$LOG"
uv run python src/extraction/05_build_panel.py 2>&1 | tee -a "$LOG"

# --- Phase 7: Final report ---
FINAL_MISSING=$(count_missing)
TOTAL_RECOVERED=$((MISSING_BEFORE - FINAL_MISSING))
log ""
log "=== OVERNIGHT SUMMARY ==="
log "  Started with missing: $MISSING_BEFORE"
log "  Total recovered:      $TOTAL_RECOVERED"
log "  Still missing:        $FINAL_MISSING"

if [ -f "data/processed/panel_monthly.csv" ]; then
    PANEL_ROWS=$(wc -l < "data/processed/panel_monthly.csv" | tr -d ' ')
    log "  Panel rows:           $PANEL_ROWS"
fi

log "=== Overnight Complete: $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="
