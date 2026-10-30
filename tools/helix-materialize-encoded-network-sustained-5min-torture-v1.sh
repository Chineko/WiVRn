#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE="$ROOT/helix-run-encoded-network-sustained-5min-v1.sh"
OUT="$ROOT/helix-run-encoded-network-sustained-5min-torture-v1.sh"
BASE_SHA256="42590ad156339300796862317b0c0f81a97f592a2ac88c7900586aa89bc99892"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in bash grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$BASE" && -x "$BASE" ]] || fail "frozen 5-minute runner missing"
[[ "$(sha256sum "$BASE" | awk '{print $1}')" == "$BASE_SHA256" ]] || fail "frozen 5-minute runner hash mismatch"

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

one('CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-30}"','CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-90}"','torture cycles')
one('SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300}"','SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100}"','torture spacing')
one('SUSTAINED_AUDIT_B=PASS frame-keyed-90-event-reducer-and-bounded-frame-budget','SUSTAINED_AUDIT_B=PASS frame-keyed-270-event-reducer-and-bounded-frame-budget','audit B label')
one('helix-encoded-sustained-5min-runtime-','helix-encoded-sustained-5min-torture-runtime-','evidence directory')
one('ENCODED_NVENC_SUSTAINED_5MIN_PASS','ENCODED_NVENC_SUSTAINED_5MIN_TORTURE_PASS','final verdict')

required=[
 'HELIX_SUSTAINED_FRAMES:-27000',
 'HELIX_ENCODED_TORTURE_CYCLES:-90',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100',
 'frame-keyed-270-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 420s',
 'ENCODED_NVENC_SUSTAINED_5MIN_TORTURE_PASS',
]
for x in required:
    if x not in s: raise SystemExit('FAIL: torture runner requirement missing: '+x)
for x in [
 'HELIX_ENCODED_TORTURE_CYCLES:-30',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300',
 'frame-keyed-90-event-reducer-and-bounded-frame-budget',
 'ENCODED_NVENC_SUSTAINED_5MIN_PASS',
]:
    if x in s: raise SystemExit('FAIL: stale baseline schedule marker remains: '+x)
p.write_text(s)
PY

chmod +x "$OUT"
bash -n "$OUT" || fail "torture runner syntax invalid"
RUNNER_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
printf 'PASS: frozen 5-minute torture runner materialized.\nbase_runner_sha256=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=90\nspacing=100\nexpected=270\ndriver_timeout_seconds=420\n' "$BASE_SHA256" "$OUT" "$RUNNER_SHA"
