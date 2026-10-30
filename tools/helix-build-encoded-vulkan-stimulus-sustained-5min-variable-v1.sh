#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-stimulus-sustained-v1"
BASE_META="$ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-stimulus-sustained-v1-seal.txt"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_variable_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-variable-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-variable-v1-metadata.txt"

FROZEN_SOURCE_SHA="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
FROZEN_BINARY_SHA="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
FROZEN_METADATA_SHA="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen 5-minute artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen 5-minute binary is not executable"

[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$FROZEN_SOURCE_SHA" ]] || fail "frozen source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$FROZEN_BINARY_SHA" ]] || fail "frozen binary hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$FROZEN_METADATA_SHA" ]] || fail "frozen metadata hash mismatch"
grep -Fqx "source_sha256=$FROZEN_SOURCE_SHA" "$BASE_SEAL" || fail "frozen seal source hash mismatch"
grep -Fqx "binary_sha256=$FROZEN_BINARY_SHA" "$BASE_SEAL" || fail "frozen seal binary hash mismatch"
grep -Fqx "metadata_sha256=$FROZEN_METADATA_SHA" "$BASE_SEAL" || fail "frozen seal metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$BASE_SEAL" || fail "frozen deadline mismatch"
grep -Fqx 'artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps' "$BASE_SEAL" || fail "frozen seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360' "$BASE_META" || fail "frozen contract marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$BASE_SRC" "$SRC" <<'PY'
from pathlib import Path
import sys
base_path=Path(sys.argv[1]); out_path=Path(sys.argv[2])
base=base_path.read_text(); s=out_path.read_text()
old='''    uint32_t seed = 0x6d2b79f5u;\n    auto * words = static_cast<uint32_t *>(mapped);\n    const VkDeviceSize word_count = upload_bytes / sizeof(uint32_t);\n    for (VkDeviceSize i = 0; i < word_count; ++i)\n    {\n        seed ^= seed << 13;\n        seed ^= seed >> 17;\n        seed ^= seed << 5;\n        words[i] = seed | 0xff000000u;\n    }\n'''
new='''    auto * words = static_cast<uint32_t *>(mapped);\n    const uint32_t noise_masks[8] = {\n        0x00030303u, 0x00070707u, 0x000f0f0fu, 0x001f1f1fu,\n        0x003f3f3fu, 0x007f7f7fu, 0x00ffffffu, 0x00ffffffu,\n    };\n    const uint32_t tile_shifts[8] = {5u, 4u, 4u, 3u, 3u, 2u, 2u, 1u};\n    for (uint32_t pattern = 0; pattern < 8u; ++pattern)\n    {\n        uint32_t seed = 0x6d2b79f5u ^ (0x9e3779b9u * (pattern + 1u));\n        for (uint32_t eye = 0; eye < 2u; ++eye)\n        {\n            for (uint32_t y = 0; y < height; ++y)\n            {\n                for (uint32_t x = 0; x < width; ++x)\n                {\n                    seed ^= seed << 13;\n                    seed ^= seed >> 17;\n                    seed ^= seed << 5;\n                    const uint32_t tile = ((x >> tile_shifts[pattern]) ^\n                                           (y >> tile_shifts[pattern]) ^ eye ^ pattern) & 1u;\n                    const uint32_t base_rgb = tile ? 0x00c06020u : 0x002040c0u;\n                    const uint32_t mask = noise_masks[pattern];\n                    const uint32_t rgb = (base_rgb & ~mask) | (seed & mask);\n                    const VkDeviceSize pixel =\n                        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +\n                        VkDeviceSize(y) * VkDeviceSize(width) + x;\n                    words[pixel] = 0xff000000u | rgb;\n                }\n            }\n        }\n    }\n'''
if base.count(old) != 1:
    raise SystemExit(f'FAIL: frozen complexity anchor count={base.count(old)}')
expected=base.replace(old,new,1)
s=s.replace(old,new,1)
if s != expected:
    raise SystemExit('FAIL: variable source differs from frozen source beyond complexity block')
out_path.write_text(s)
PY

# Source-only audit: control flow, deadline, upload/copy schedule and frame selector remain frozen.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "8-pattern upload geometry changed"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "8-pattern frame selector changed"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'const uint32_t noise_masks[8]' "$SRC" || fail "variable complexity masks missing"
grep -Fq 'const uint32_t tile_shifts[8]' "$SRC" || fail "variable complexity tiles missing"
grep -Fq 'words[pixel] = 0xff000000u | rgb;' "$SRC" || fail "variable complexity pixel write missing"
! grep -Fq 'const VkDeviceSize word_count = upload_bytes / sizeof(uint32_t);' "$SRC" || fail "stale uniform-random fill remains"

OPENXR_LIB="$(awk -F= '$1=="openxr_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from frozen metadata"

echo '[1/2] Compiling variable-complexity 5-minute Vulkan stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "variable-complexity stimulus compile failed"

echo '[2/2] Recording variable-complexity stimulus metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
[[ "$SRC_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash format"
[[ "$BIN_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid binary hash format"
cat >"$META" <<EOF
base_5min_source=$BASE_SRC
base_5min_binary=$BASE_BIN
base_5min_metadata=$BASE_META
base_5min_seal=$BASE_SEAL
base_5min_source_sha256=$FROZEN_SOURCE_SHA
base_5min_binary_sha256=$FROZEN_BINARY_SHA
base_5min_metadata_sha256=$FROZEN_METADATA_SHA
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
render_deadline_seconds=360
complexity_levels=8
complexity_profile=structured-tiles-plus-deterministic-noise-2-to-8-bits
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-variable-complexity8-sustained360
source_delta=PASS frozen-5min-only-pattern-population-block
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash format"
printf '\nPASS: variable-complexity 5-minute stimulus built from frozen 5-minute stimulus.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nrender_deadline_seconds=360\ncomplexity_levels=8\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"