#!/usr/bin/env bash
set -euo pipefail

BASE_RUNNER_COMMIT="705885628d940950c1234fe4cc8faa8b77f37311"
BASE_RUNNER_PATH="tools/helix-run-encoded-network-sustained-v1.sh"
OUT="${1:-$HOME/helix-encoded-nvenc-build-20261030-160211/helix-run-encoded-network-sustained-5min-v1.sh}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"
git cat-file -e "${BASE_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_RUNNER_COMMIT"
mkdir -p "$(dirname "$OUT")"
git show "${BASE_RUNNER_COMMIT}:${BASE_RUNNER_PATH}" >"$OUT"

python3 - "$OUT" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

once(
'SERVER_SHA256="d9b0b54d8d8ff5d977fa5f25867885b0d11ac433d4467eb66f7435506214f6e79"',
'SERVER_SHA256="d9b0b548ddf8f5d97fa5f25867885b0d11ac433d4467eb66f7435506214f6e79"',
'correct server hash')
once('FRAMES="${HELIX_SUSTAINED_FRAMES:-10800}"','FRAMES="${HELIX_SUSTAINED_FRAMES:-27000}"','5min frames')
once('CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-12}"','CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-30}"','5min cycles')
once(
'''V5_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$V5_ROOT/vulkan-stimulus-v5-seal.txt"
VULKAN_META="$V5_ROOT/vulkan-stimulus-v5-metadata.txt"
DRIVER="$V5_ROOT/helix-vulkan-stimulus-v5"''',
'''VULKAN_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
VULKAN_SRC="$VULKAN_ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
SEAL="$VULKAN_ROOT/vulkan-stimulus-sustained-v1-seal.txt"
VULKAN_META="$VULKAN_ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
DRIVER="$VULKAN_ROOT/helix-vulkan-stimulus-sustained-v1"
VULKAN_SOURCE_SHA256="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
VULKAN_BINARY_SHA256="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8bace15c0c534a85d9a"
VULKAN_METADATA_SHA256="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"''',
'sustained Vulkan binding')
once(
'''for f in "$META" "$SERVER" "$MANIFEST" "$APK" "$SEAL" "$VULKAN_META" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"''',
'''for f in "$META" "$SERVER" "$MANIFEST" "$APK" "$VULKAN_SRC" "$SEAL" "$VULKAN_META" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$VULKAN_SRC" | awk '{print $1}')" == "$VULKAN_SOURCE_SHA256" ]] || fail "sustained Vulkan source hash mismatch"
[[ "$(sha256sum "$DRIVER" | awk '{print $1}')" == "$VULKAN_BINARY_SHA256" ]] || fail "sustained Vulkan binary hash mismatch"
[[ "$(sha256sum "$VULKAN_META" | awk '{print $1}')" == "$VULKAN_METADATA_SHA256" ]] || fail "sustained Vulkan metadata hash mismatch"''',
'sustained Vulkan hash gates')
once(
'''grep -Fq 'artifact_seal=PASS strict-v5-source-binary-metadata-deps' "$SEAL" || fail "v5 stimulus seal missing"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$VULKAN_META" || fail "v5 stimulus contract missing"''',
'''grep -Fqx 'build_tooling_commit=e5c77bc488ebc4eb3d8c03e66511cd1c60daa271' "$SEAL" || fail "sustained Vulkan build tooling mismatch"
grep -Fqx 'render_deadline_seconds=360' "$SEAL" || fail "sustained Vulkan seal deadline mismatch"
grep -Fqx "source_sha256=$VULKAN_SOURCE_SHA256" "$SEAL" || fail "sustained Vulkan seal source mismatch"
grep -Fqx "binary_sha256=$VULKAN_BINARY_SHA256" "$SEAL" || fail "sustained Vulkan seal binary mismatch"
grep -Fqx "metadata_sha256=$VULKAN_METADATA_SHA256" "$SEAL" || fail "sustained Vulkan seal metadata mismatch"
grep -Fqx 'artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps' "$SEAL" || fail "sustained Vulkan seal marker missing"
grep -Fqx 'render_deadline_seconds=360' "$VULKAN_META" || fail "sustained Vulkan metadata deadline mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360' "$VULKAN_META" || fail "sustained Vulkan contract missing"
grep -Fqx 'source_delta=PASS frozen-v5-only-render-deadline-20-to-360' "$VULKAN_META" || fail "sustained Vulkan source delta missing"''',
'sustained Vulkan seal gates')
once(
'''mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t usb < <(printf '%s\\n' "${devs[@]}" | grep -v ':' || true)
if [[ ${#usb[@]} -eq 1 ]]; then SERIAL="${usb[0]}"; elif [[ ${#devs[@]} -eq 1 ]]; then SERIAL="${devs[0]}"; else fail "expected one usable ADB device"; fi''',
'''mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
usb=()
for d in "${devs[@]}"; do [[ "$d" != *:* ]] && usb+=("$d"); done
if [[ ${#usb[@]} -eq 1 ]]; then SERIAL="${usb[0]}"; elif [[ ${#devs[@]} -eq 1 ]]; then SERIAL="${devs[0]}"; else fail "expected one usable ADB device"; fi
[[ -n "$SERIAL" ]] || fail "ADB device serial is empty"''',
'empty ADB guard')
once("echo 'SUSTAINED_AUDIT_A=PASS exact-source-server-apk-sealed-vulkan-lan-path'","echo 'SUSTAINED_AUDIT_A=PASS exact-source-server-apk-sealed-sustained-vulkan-lan-path'",'audit A label')
once("echo 'SUSTAINED_AUDIT_B=PASS frame-keyed-36-event-reducer-and-bounded-frame-budget'","echo 'SUSTAINED_AUDIT_B=PASS frame-keyed-90-event-reducer-and-bounded-frame-budget'",'audit B label')
once('OUT="$HOME/helix-encoded-sustained-runtime-$STAMP"','OUT="$HOME/helix-encoded-sustained-5min-runtime-$STAMP"','evidence directory')
once('vulkan_stimulus=$DRIVER\nframes=$FRAMES','vulkan_stimulus=$DRIVER\nvulkan_source_sha256=$VULKAN_SOURCE_SHA256\nvulkan_binary_sha256=$VULKAN_BINARY_SHA256\nvulkan_metadata_sha256=$VULKAN_METADATA_SHA256\nframes=$FRAMES','runtime metadata Vulkan hashes')
once('timeout --signal=TERM --kill-after=5s 240s "$DRIVER" "$FRAMES"','timeout --signal=TERM --kill-after=5s 420s "$DRIVER" "$FRAMES"','5min timeout')
once("echo 'verdict=ENCODED_NVENC_SUSTAINED_PASS'","echo 'verdict=ENCODED_NVENC_SUSTAINED_5MIN_PASS'",'5min verdict')

required = [
 'SERVER_SHA256="d9b0b548ddf8f5d97fa5f25867885b0d11ac433d4467eb66f7435506214f6e79"',
 'HELIX_SUSTAINED_FRAMES:-27000',
 'HELIX_ENCODED_TORTURE_CYCLES:-30',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300',
 'helix-vulkan-stimulus-sustained-v1',
 '619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082',
 'dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8bace15c0c534a85d9a',
 '9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef',
 'frame-keyed-90-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 420s',
 'ENCODED_NVENC_SUSTAINED_5MIN_PASS',
]
for x in required:
    if x not in s: raise SystemExit('FAIL: generated runner requirement missing: '+x)
for x in [
 'd9b0b54d8d8ff5d977fa5f25867885b0d11ac433d4467eb66f7435506214f6e79',
 'HELIX_SUSTAINED_FRAMES:-10800',
 'HELIX_ENCODED_TORTURE_CYCLES:-12',
 'vulkan-stimulus-v5-seal.txt',
 'helix-vulkan-stimulus-v5',
 'frame-keyed-36-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 240s',
]:
    if x in s: raise SystemExit('FAIL: stale runner pattern remains: '+x)
p.write_text(s)
PY

chmod +x "$OUT"
bash -n "$OUT" || fail "generated 5-minute runner syntax invalid"
RUNNER_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
printf 'PASS: deterministic 5-minute sustained runner materialized.\nbase_runner_commit=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=30\nspacing=300\nexpected=90\ndriver_timeout_seconds=420\n' "$BASE_RUNNER_COMMIT" "$OUT" "$RUNNER_SHA"
