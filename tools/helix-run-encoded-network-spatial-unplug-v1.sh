#!/usr/bin/env bash
set -euo pipefail

PINNED_NETWORK_RUNNER_COMMIT="b2111b38e734c3c22c65ca0a3450008afc016edc"
PINNED_NETWORK_RUNNER_PATH="tools/helix-run-encoded-nvenc-torture-network-promotion-v1.sh"
START_DELAY="${HELIX_START_DELAY:-20}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 mktemp grep cp cmp; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
[[ "$START_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_START_DELAY must be a nonnegative integer"
export START_DELAY

orig="$(mktemp)"
runner="$(mktemp)"
trap 'rm -f "$orig" "$runner"' EXIT INT TERM

git cat-file -e "${PINNED_NETWORK_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_NETWORK_RUNNER_COMMIT"
git show "${PINNED_NETWORK_RUNNER_COMMIT}:${PINNED_NETWORK_RUNNER_PATH}" >"$orig"
[[ -s "$orig" ]] || fail "pinned network runner unavailable"
cp "$orig" "$runner"
cmp -s "$orig" "$runner" || fail "pinned network runner copy mismatch"

python3 - "$runner" "$orig" "$START_DELAY" <<'PY'
from pathlib import Path
import sys
runner=Path(sys.argv[1]); original=Path(sys.argv[2]).read_text(); delay=int(sys.argv[3])
s=runner.read_text()
anchor='bash -n "$PATCHED"\n'
if s.count(anchor) != 1:
    raise SystemExit('FAIL: promotion PATCHED syntax-check anchor count='+str(s.count(anchor)))

# PATCHED is the exact proven v3 launcher after only promotion identity rebinding.
# Modify its existing reducer injection so the additional code executes inside
# fix-v2 PY2, where `s` is the fully emitted final runtime script.
block=r'''python3 - "$PATCHED" "$START_DELAY" <<'PY_SPATIAL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); delay=int(sys.argv[2]); s=p.read_text()
old="s=s.replace(anchor, inject+anchor, 1)\n"
if s.count(old) != 1:
    raise SystemExit('FAIL: v3 reducer insertion anchor count='+str(s.count(old)))

pause_code = (
    "pause_old=\"echo '[4/8] Driving 220 graphics-bound Vulkan/OpenXR frames through NVENC'\\n\"\n"
    "pause_new=(\n"
    "    \"echo 'SPATIAL_UNPLUG_GATE=READY trusted-quest-connected network-path-proven unplug-usb-now'\\n\"\n"
    "    \"echo 'UNPLUG USB NOW - WiVRn is connected over WLAN; move to the VR space'\\n\"\n"
    + f"    \"echo 'SPATIAL_START_DELAY seconds={delay}'\\n\"\n"
    + f"    \"for ((remaining={delay}; remaining>0; remaining--)); do\\n\"\n"
    "    \"  printf '\\\\rNVENC spatial workload starts in %2d s ' \\\"$remaining\\\"\\n\"\n"
    "    \"  sleep 1\\n\"\n"
    "    \"done\\n\"\n"
    "    \"printf '\\\\rNVENC spatial workload starts now      \\\\n'\\n\"\n"
    "    + pause_old\n"
    ")\n"
    "if s.count(pause_old) != 1:\n"
    "    raise SystemExit('FAIL: final runtime stimulus anchor count='+str(s.count(pause_old)))\n"
    "s=s.replace(pause_old,pause_new,1)\n\n"
)
new=(
    "pause_inject=" + repr(pause_code) + "\n"
    "s=s.replace(anchor, inject+pause_inject+anchor, 1)\n"
)
s=s.replace(old,new,1)
p.write_text(s)
PY_SPATIAL

grep -Fq 'pause_inject=' "$PATCHED" || fail "spatial final-runtime injection missing"
grep -Fq 'inject+pause_inject+anchor' "$PATCHED" || fail "spatial reducer-layer composition missing"

'''
patched=s.replace(anchor, block+anchor, 1)
runner.write_text(patched)
normalized=patched.replace(block+anchor, anchor, 1)
if normalized != original:
    raise SystemExit('FAIL: spatial wrapper differs from pinned network runner beyond approved final-runtime injection')
print('SPATIAL_WRAPPER_COMPOSITION_AUDIT=PASS pinned-network-runner-plus-v3-final-runtime-pause-injection')
PY

bash -n "$runner"
grep -Fq 'pause_inject=' "$runner" || fail "pause injection transform missing"
grep -Fq 'inject+pause_inject+anchor' "$runner" || fail "pause injection composition missing"
echo "SPATIAL_UNPLUG_WRAPPER_AUDIT=PASS pinned_runner=$PINNED_NETWORK_RUNNER_COMMIT delay=${START_DELAY}s reducer-and-workload-semantics-unchanged"
exec bash "$runner"
