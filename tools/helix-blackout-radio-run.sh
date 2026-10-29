#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BASE="$ROOT/tools/helix-blackout-usb-detached-run.sh"
PATCH="$ROOT/tools/helix-blackout-radio-patch-v2.py"
[[ -f "$BASE" ]] || { echo "missing $BASE" >&2; exit 1; }
[[ -f "$PATCH" ]] || { echo "missing $PATCH" >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/helix-blackout-radio-run.XXXXXX.sh")
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

python3 - "$BASE" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1]).read_text()
out = Path(sys.argv[2])
old = '''bash -n "$TMP_CAPTURE"
bash -n "$TMP_RUN"

bash "$TMP_RUN"
'''
new = '''python3 "$ROOT/tools/helix-blackout-radio-patch-v2.py" "$TMP_CAPTURE"
bash -n "$TMP_CAPTURE"
bash -n "$TMP_RUN"

echo "Quest WLAN datapath trace will be collected in the same USB-detached blackout run."
echo "After the first real blackout, end the workload promptly so the bounded in-RAM trace retains that event."

bash "$TMP_RUN"
'''
count = src.count(old)
if count != 1:
    raise SystemExit(f"radio wrapper: expected one validation/launch tail, found {count}")
out.write_text(src.replace(old, new, 1))
PY

bash -n "$TMP"
bash "$TMP"
