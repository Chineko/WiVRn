#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE="$ROOT/helix-run-encoded-network-sustained-5min-variable-torture-v1.sh"
OUT="$ROOT/helix-run-encoded-network-sustained-5min-variable-torture-20f-v1.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in bash python3 sha256sum grep; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$BASE" && -x "$BASE" ]] || fail "passing variable-complexity torture runner missing"

BASE_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
[[ "$BASE_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid base runner hash format"

# Validate the exact passing 100f profile and its frozen variable-complexity artifact bindings before deriving.
for x in \
 'HELIX_SUSTAINED_FRAMES:-27000' \
 'HELIX_ENCODED_TORTURE_CYCLES:-90' \
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100' \
 'frame-keyed-270-event-reducer-and-bounded-frame-budget' \
 'timeout --signal=TERM --kill-after=5s 420s' \
 'helix_vulkan_stimulus_sustained_5min_variable_v1.cpp' \
 'helix-vulkan-stimulus-sustained-5min-variable-v1' \
 'vulkan-stimulus-sustained-5min-variable-v1-metadata.txt' \
 'vulkan-stimulus-sustained-5min-variable-v1-seal.txt' \
 'e106d7b0ed0127c5fcead1de86b1529ae0bee11382cce938c78f348caaca40c0' \
 '04e8d53508879620a1cbb1415a35338eebf619183e1a6e3e57d8cfa21e820b8e' \
 '93f4e1611737e5953a13e7835f19a541be9dd034629a6a78cfd79a4429acf348' \
 '79339d9cffa4c2afa738d7eecc919481e61d3325' \
 'ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_PASS'
do
  grep -Fq "$x" "$BASE" || fail "base runner binding/profile marker missing: $x"
done

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

one('CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-90}"','CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-449}"','cycles 90 to 449')
one('SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-100}"','SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20}"','spacing 100 to 20')
one('SUSTAINED_AUDIT_B=PASS frame-keyed-270-event-reducer-and-bounded-frame-budget','SUSTAINED_AUDIT_B=PASS frame-keyed-1347-event-reducer-and-bounded-frame-budget','audit B label')
one('helix-encoded-sustained-5min-variable-torture-runtime-','helix-encoded-sustained-5min-variable-torture-20f-runtime-','evidence directory')
one('ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_PASS','ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_20F_PASS','final verdict')

required=[
 'HELIX_SUSTAINED_FRAMES:-27000',
 'HELIX_ENCODED_TORTURE_CYCLES:-449',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20',
 'frame-keyed-1347-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 420s',
 'helix_vulkan_stimulus_sustained_5min_variable_v1.cpp',
 'helix-vulkan-stimulus-sustained-5min-variable-v1',
 'vulkan-stimulus-sustained-5min-variable-v1-metadata.txt',
 'vulkan-stimulus-sustained-5min-variable-v1-seal.txt',
 'e106d7b0ed0127c5fcead1de86b1529ae0bee11382cce938c78f348caaca40c0',
 '04e8d53508879620a1cbb1415a35338eebf619183e1a6e3e57d8cfa21e820b8e',
 '93f4e1611737e5953a13e7835f19a541be9dd034629a6a78cfd79a4429acf348',
 '79339d9cffa4c2afa738d7eecc919481e61d3325',
 'ENCODED_NVENC_SUSTAINED_5MIN_VARIABLE_TORTURE_20F_PASS',
]
for x in required:
    if x not in s:
        raise SystemExit('FAIL: generated 20f runner requirement missing: '+x)

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
bash -n "$OUT" || fail "generated 20f runner syntax invalid"
RUNNER_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
[[ "$RUNNER_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid runner hash format"
printf 'PASS: 20-frame variable-complexity torture runner materialized.\nbase_runner_sha256=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=449\nspacing=20\nexpected=1347\ndriver_timeout_seconds=420\n' \
  "$BASE_SHA" "$OUT" "$RUNNER_SHA"
