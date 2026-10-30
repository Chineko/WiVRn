#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE="$ROOT/helix-run-encoded-network-sustained-5min-variable-torture-v1.sh"
OUT="$ROOT/helix-run-encoded-network-sustained-5min-variable-torture-40f-v1.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in bash python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$BASE" && -x "$BASE" ]] || fail "passing variable-complexity torture runner missing"

BASE_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
[[ "$BASE_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid base runner hash format"

cp "$BASE" "$OUT"
python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def one(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

one('CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-90}"','CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-225}"','cycles 90 to 225')
one('SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100}"','SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-40}"','spacing 100 to 40')
one('SUSTAINED_AUDIT_B=PASS frame-keyed-270-event-reducer-and-bounded-frame-budget','SUSTAINED_AUDIT_B=PASS frame-keyed-675-event-reducer-and-bounded-frame-budget','audit B label')
one('helix-encoded-sustained-5min-variable-torture-runtime-','helix-encoded-sustained-5min-variable-torture-40f-runtime-','evidence directory')
one('ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_PASS','ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_40F_PASS','final verdict')

required=[
 'HELIX_SUSTAINED_FRAMES:-27000',
 'HELIX_ENCODED_TORTURE_CYCLES:-225',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-40',
 'frame-keyed-675-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 420s',
 'ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_40F_PASS',
]
for x in required:
    if x not in s:
        raise SystemExit('FAIL: generated 40f runner requirement missing: '+x)

for x in [
 'HELIX_ENCODED_TORTURE_CYCLES:-90',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100',
 'frame-keyed-270-event-reducer-and-bounded-frame-budget',
 'helix-encoded-sustained-5min-variable-torture-runtime-',
 'ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_PASS',
]:
    if x in s:
        raise SystemExit('FAIL: stale 100f profile marker remains: '+x)

p.write_text(s)
PY

chmod +x "$OUT"
bash -n "$OUT" || fail "generated 40f runner syntax invalid"
RUNNER_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
[[ "$RUNNER_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid runner hash format"
printf 'PASS: 40-frame variable-complexity torture runner materialized.\nbase_runner_sha256=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=225\nspacing=40\nexpected=675\ndriver_timeout_seconds=420\n' \
  "$BASE_SHA" "$OUT" "$RUNNER_SHA"
