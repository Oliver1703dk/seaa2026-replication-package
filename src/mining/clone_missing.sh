#!/usr/bin/env bash
# Clone missing control repos with per-repo timeout
set -uo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPOS_DIR="$PROJECT_ROOT/repos"
MISSING_LIST="/tmp/missing_controls.txt"
TIMEOUT=90  # seconds per repo

ok=0
fail=0
skip=0
total=$(wc -l < "$MISSING_LIST" | tr -d ' ')

echo "Cloning $total missing controls (timeout=${TIMEOUT}s)..."

while IFS= read -r name; do
    dir_name="${name//\//__}"
    target="$REPOS_DIR/$dir_name"

    if [ -d "$target" ]; then
        skip=$((skip + 1))
        continue
    fi

    if timeout "$TIMEOUT" git clone --bare --single-branch "https://github.com/$name.git" "$target" 2>/dev/null; then
        ok=$((ok + 1))
    else
        rm -rf "$target" 2>/dev/null
        fail=$((fail + 1))
    fi

    echo -ne "\r  OK=$ok FAIL=$fail SKIP=$skip / $total"
done < "$MISSING_LIST"

echo ""
echo "=== Clone Summary ==="
echo "  OK:     $ok"
echo "  Failed: $fail"
echo "  Skipped: $skip"
echo "  Total:  $total"
