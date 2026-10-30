#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-stimulus-sustained-v1"
BASE_META="$ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-stimulus-sustained-v1-seal.txt"
SRC="$ROOT/helix_vulkan_stimulus_sustained_15min_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-15min-v1"
META="$ROOT/vulkan-stimulus-sustained-15min-v1-metadata.txt"

FROZEN_5MIN_SOURCE_SHA="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
FROZEN_5MIN_BINARY_SHA="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
FROZEN_5MIN_METADATA_SHA="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"
RENDER_DEADLINE_SECONDS=1080

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen 5-minute artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen 5-minute binary is not executable"

base_src_sha="$(sha256sum "$BASE_SRC" | awk '{print $1}')"
base_bin_sha="$(sha256sum "$BASE_BIN" | awk '{print $1}')"
base_meta_sha="$(sha256sum "$BASE_META" | awk '{print $1}')"
[[ "$base_src_sha" == "$FROZEN_5MIN_SOURCE_SHA" ]] || fail "frozen 5-minute source hash mismatch"
[[ "$base_bin_sha" == "$FROZEN_5MIN_BINARY_SHA" ]] || fail "frozen 5-minute binary hash mismatch"
[[ "$base_meta_sha" == "$FROZEN_5MIN_METADATA_SHA" ]] || fail "frozen 5-minute metadata hash mismatch"
grep -Fqx "source_sha256=$FROZEN_5MIN_SOURCE_SHA" "$BASE_SEAL" || fail "frozen 5-minute seal source hash mismatch"
grep -Fqx "binary_sha256=$FROZEN_5MIN_BINARY_SHA" "$BASE_SEAL" || fail "frozen 5-minute seal binary hash mismatch"
grep -Fqx "metadata_sha256=$FROZEN_5MIN_METADATA_SHA" "$BASE_SEAL" || fail "frozen 5-minute seal metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$BASE_SEAL" || fail "frozen 5-minute seal deadline mismatch"
grep -Fqx 'artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps' "$BASE_SEAL" || fail "frozen 5-minute seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360' "$BASE_META" || fail "frozen 5-minute contract marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(360);'
new='auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1080);'
n=s.count(old)
if n != 1:
    raise SystemExit(f'FAIL: 15-minute deadline anchor count={n}')
s=s.replace(old,new,1)
p.write_text(s)
PY

python3 - "$BASE_SRC" "$SRC" <<'PY'
from pathlib import Path
import sys
base=Path(sys.argv[1]).read_text()
sustained=Path(sys.argv[2]).read_text()
expected=base.replace(
    'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(360);',
    'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(1080);',
    1,
)
if sustained != expected:
    raise SystemExit('FAIL: 15-minute source differs from frozen 5-minute source beyond deadline change')
PY

grep -Fq 'std::chrono::seconds(1080)' "$SRC" || fail "15-minute deadline missing"
! grep -Fq 'std::chrono::seconds(360);' "$SRC" || fail "5-minute deadline remains"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "entropy8 source marker missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump source marker missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC" || fail "render progress marker missing"

OPENXR_LIB="$(awk -F= '$1=="openxr_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from frozen 5-minute metadata"

echo '[1/2] Compiling 15-minute sustained Vulkan stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "15-minute stimulus compile failed"

echo '[2/2] Recording 15-minute stimulus metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
cat >"$META" <<EOF
base_5min_source=$BASE_SRC
base_5min_binary=$BASE_BIN
base_5min_metadata=$BASE_META
base_5min_seal=$BASE_SEAL
base_5min_source_sha256=$FROZEN_5MIN_SOURCE_SHA
base_5min_binary_sha256=$FROZEN_5MIN_BINARY_SHA
base_5min_metadata_sha256=$FROZEN_5MIN_METADATA_SHA
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
render_deadline_seconds=$RENDER_DEADLINE_SECONDS
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained1080
source_delta=PASS frozen-5min-only-render-deadline-360-to-1080
runtime_status=NOT_RUN
EOF

printf '\nPASS: 15-minute sustained Vulkan stimulus built from frozen 5-minute stimulus.\nbase_5min_source_sha256=%s\nbase_5min_binary_sha256=%s\nbase_5min_metadata_sha256=%s\nrender_deadline_seconds=%s\nstimulus_source=%s\nsource_sha256=%s\nvulkan_stimulus=%s\nbinary_sha256=%s\nmetadata=%s\nSTATUS: built only; runtime not executed.\n' \
  "$FROZEN_5MIN_SOURCE_SHA" "$FROZEN_5MIN_BINARY_SHA" "$FROZEN_5MIN_METADATA_SHA" "$RENDER_DEADLINE_SECONDS" "$SRC" "$SRC_SHA" "$BIN" "$BIN_SHA" "$META"
