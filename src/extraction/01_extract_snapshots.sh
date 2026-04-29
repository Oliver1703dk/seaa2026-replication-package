#!/usr/bin/env bash
# Wrapper: delegates to Python for snapshot manifest generation.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"
exec uv run python src/extraction/01_build_snapshot_manifest.py "$@"
