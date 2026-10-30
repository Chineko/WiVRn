#!/usr/bin/env bash
set -euo pipefail

PINNED_NETWORK_RUNNER_COMMIT="b2111b38e734c3c22c65ca0a3450008afc016edc"
PINNED_NETWORK_RUNNER_PATH="tools/helix-run-encoded-nvenc-torture-network-promotion-v1.sh"
START_DELAY="${HELIX_START_DELAY:-20}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 mktemp grep cp; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
[[ "$START_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_START_DELAY must be a nonnegative integer"
export START_DELAY

orig="$(mktemp)"
runner="$(mktemp)"
trap 'rm -f "$orig" "$runner"' EXIT INT TERM

git cat-file -e "${PINNED_NETWORK_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_NETWORK_RUNNER_COMMIT"
git show "${PINNED_NETWORK_RUNNER_COMMIT}:${PINNED_NETWORK_RUNNER_PATH}" >"$orig"
cp "$orig" "$runner"

python3 - "$runner" "$orig" "$START_DELAY" <<'PY'
from pathlib import Path
import sys
runner=Path(sys.argv[1]); original=Path(sys.argv[2]).read_text(); delay=int(sys.argv[3])
s=runner.read_text()
anchor='bash -n "$PATCHED"\n'
if s.count(anchor) != 1:
    raise SystemExit('FAIL: promotion PATCHED syntax-check anchor count='+str(s.count(anchor)))

block=r'''python3 - "$PATCHED" "$START_DELAY" <<'PY_SPATIAL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); delay=int(sys.argv[2]); s=p.read_text()
anchor="s=s.replace(anchor, inject+anchor, 1)\n"
if s.count(anchor) != 1:
    raise SystemExit('FAIL: v3 final-runtime injection anchor count='+str(s.count(anchor)))
pause_old="echo '[4/8] Driving 220 graphics-bound Vulkan/OpenXR frames through NVENC'\n"
pause_new=(
    "echo 'SPATIAL_UNPLUG_GATE=READY trusted-quest-connected network-path-proven unplug-usb-now'\n"
    "echo 'UNPLUG USB NOW - WiVRn is connected over WLAN; move to the VR space'\n"
    + f"echo 'SPATIAL_START_DELAY seconds={delay}'\n"
    + f"for ((remaining={delay}; remaining>0; remaining--)); do\n"
    + "  printf '\\rNVENC spatial workload starts in %2d s ' \"$remaining\"\n"
    + "  sleep 1\n"
    + "done\n"
    + "printf '\\rNVENC spatial workload starts now      \\n'\n"
    + pause_old
)
addition=(
    "pause_old=" + repr(pause_old) + "\n"
    "pause_new=" + repr(pause_new) + "\n"
    "if s.count(pause_old) != 1:\n"
    "    raise SystemExit('FAIL: final runtime stimulus anchor count='+str(s.count(pause_old)))\n"
    "s=s.replace(pause_old,pause_new,1)\n\n"
)
s=s.replace(anchor, addition+anchor, 1)
p.write_text(s)
PY_SPATIAL

grep -Fq 'SPATIAL_UNPLUG_GATE=READY trusted-quest-connected network-path-proven unplug-usb-now' "$PATCHED" || fail "spatial unplug transform marker missing"
grep -Fq 'final runtime stimulus anchor count=' "$PATCHED" || fail "spatial final-runtime anchor guard missing"

'''
patched=s.replace(anchor, block+anchor, 1)
runner.write_text(patched)
normalized=patched.replace(block+anchor, anchor, 1)
if normalized != original:
    raise SystemExit('FAIL: spatial wrapper differs from pinned network runner beyond approved orchestration insertion')
print('SPATIAL_WRAPPER_COMPOSITION_AUDIT=PASS pinned-network-runner-plus-single-final-runtime-pause-transform')
PY

bash -n "$runner"
grep -Fq "$PINNED_NETWORK_RUNNER_COMMIT" "$runner" || fail "pinned network runner commit missing"
grep -Fq 'SPATIAL_UNPLUG_GATE=READY trusted-quest-connected network-path-proven unplug-usb-now' "$runner" || fail "unplug gate missing"
grep -Fq "SPATIAL_START_DELAY seconds=" "$runner" || fail "delay marker missing"
echo "SPATIAL_UNPLUG_WRAPPER_AUDIT=PASS pinned_runner=$PINNED_NETWORK_RUNNER_COMMIT delay=${START_DELAY}s semantics-unchanged"
exec bash "$runner"
