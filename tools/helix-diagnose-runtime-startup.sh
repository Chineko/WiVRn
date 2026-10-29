#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
SELF_PATH="tools/helix-diagnose-runtime-startup.sh"

fail() { echo "Helix startup diagnostic: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in awk cut find git grep head python3 sort tail; do need "$cmd"; done

[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH"
HEAD_SELF_BLOB=$(git rev-parse "HEAD:$SELF_PATH" 2>/dev/null || true)
[[ "$HEAD_SELF_BLOB" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve $SELF_PATH at HEAD"
SELF_BLOB=$(git hash-object "$SELF_PATH")
[[ "$SELF_BLOB" == "$HEAD_SELF_BLOB" ]] || fail "local diagnostic helper differs from HEAD artifact"

OUT=${1:-}
if [[ -z "$OUT" ]]; then
    OUT=$(find "$HOME" -maxdepth 1 -type d -name 'helix-bounded-recovery-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[[ -n "$OUT" && -d "$OUT" ]] || fail "bounded-recovery output directory not found"

DASH_OUT="$OUT/dashboard-stdout.txt"
[[ -s "$DASH_OUT" ]] || fail "missing or empty $DASH_OUT"

SERVER_LOG=$(python3 - "$DASH_OUT" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
m = re.findall(r'Saving logs in\s+"([^"]*server_logs_[^"]+\.txt)"', text)
print(m[-1] if m else '')
PY
)

printf 'output_dir=%s\n' "$OUT"
printf 'dashboard_stdout=%s\n' "$DASH_OUT"
if [[ -n "$SERVER_LOG" ]]; then
    printf 'server_log=%s\n' "$SERVER_LOG"
else
    echo 'server_log=<not reported by dashboard>'
fi

echo
echo '=== dashboard stdout tail ==='
tail -n 120 "$DASH_OUT"

if [[ -n "$SERVER_LOG" && -s "$SERVER_LOG" ]]; then
    echo
echo '=== server log tail ==='
    tail -n 200 "$SERVER_LOG"

    echo
echo '=== startup failure markers ==='
    grep -Ein 'fatal|error|failed|failure|exception|terminate|abort|vulkan|openxr|monado|dbus|socket|bind|permission|config|encoder|nvenc' "$SERVER_LOG" | tail -n 120 || true
else
    echo
echo 'No readable authoritative server log was found.'
fi
