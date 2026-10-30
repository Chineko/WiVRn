#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_variable_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-variable-v1"
BASE_META="$ROOT/vulkan-stimulus-sustained-5min-variable-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-stimulus-sustained-5min-variable-v1-seal.txt"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_entropy_spike_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-entropy-spike-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-entropy-spike-v1-metadata.txt"

BASE_SOURCE_SHA="e106d7b0ed0127c5fcead1de86b1529ae0bee11382cce938c78f348caaca40c0"
BASE_BINARY_SHA="04e8d53508879620a1cbb1415a35338eebf619183e1a6e3e57d8cfa21e820b8e"
BASE_METADATA_SHA="93f4e1611737e5953a13e7835f19a541be9dd034629a6a78cfd79a4429acf348"
BASE_BUILD_TOOLING="79339d9cffa4c2afa738d7eecc919481e61d3325"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen variable artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen variable binary is not executable"

[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$BASE_SOURCE_SHA" ]] || fail "frozen variable source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$BASE_BINARY_SHA" ]] || fail "frozen variable binary hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_METADATA_SHA" ]] || fail "frozen variable metadata hash mismatch"
grep -Fqx "build_tooling_commit=$BASE_BUILD_TOOLING" "$BASE_SEAL" || fail "frozen variable build tooling mismatch"
grep -Fqx "source_sha256=$BASE_SOURCE_SHA" "$BASE_SEAL" || fail "frozen variable seal source hash mismatch"
grep -Fqx "binary_sha256=$BASE_BINARY_SHA" "$BASE_SEAL" || fail "frozen variable seal binary hash mismatch"
grep -Fqx "metadata_sha256=$BASE_METADATA_SHA" "$BASE_SEAL" || fail "frozen variable seal metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$BASE_SEAL" || fail "frozen variable deadline mismatch"
grep -Fqx 'complexity_levels=8' "$BASE_SEAL" || fail "frozen variable complexity level mismatch"
grep -Fqx 'complexity_profile=structured-tiles-plus-deterministic-noise-2-to-8-bits' "$BASE_SEAL" || fail "frozen variable profile mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-variable-v1-frozen-base-single-content-block-source-binary-metadata-deps' "$BASE_SEAL" || fail "frozen variable seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-variable-complexity8-sustained360' "$BASE_META" || fail "frozen variable contract marker missing"
grep -Fqx 'source_delta=PASS frozen-5min-only-pattern-population-block' "$BASE_META" || fail "frozen variable source delta marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$BASE_SRC" "$SRC" <<'PY'
from pathlib import Path
import sys
base_path=Path(sys.argv[1]); out_path=Path(sys.argv[2])
base=base_path.read_text(); s=out_path.read_text()
old='''    auto * words = static_cast<uint32_t *>(mapped);\n    const uint32_t noise_masks[8] = {\n        0x00030303u, 0x00070707u, 0x000f0f0fu, 0x001f1f1fu,\n        0x003f3f3fu, 0x007f7f7fu, 0x00ffffffu, 0x00ffffffu,\n    };\n    const uint32_t tile_shifts[8] = {5u, 4u, 4u, 3u, 3u, 2u, 2u, 1u};\n    for (uint32_t pattern = 0; pattern < 8u; ++pattern)\n    {\n        uint32_t seed = 0x6d2b79f5u ^ (0x9e3779b9u * (pattern + 1u));\n        for (uint32_t eye = 0; eye < 2u; ++eye)\n        {\n            for (uint32_t y = 0; y < height; ++y)\n            {\n                for (uint32_t x = 0; x < width; ++x)\n                {\n                    seed ^= seed << 13;\n                    seed ^= seed >> 17;\n                    seed ^= seed << 5;\n                    const uint32_t tile = ((x >> tile_shifts[pattern]) ^\n                                           (y >> tile_shifts[pattern]) ^ eye ^ pattern) & 1u;\n                    const uint32_t base_rgb = tile ? 0x00c06020u : 0x002040c0u;\n                    const uint32_t mask = noise_masks[pattern];\n                    const uint32_t rgb = (base_rgb & ~mask) | (seed & mask);\n                    const VkDeviceSize pixel =\n                        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +\n                        VkDeviceSize(y) * VkDeviceSize(width) + x;\n                    words[pixel] = 0xff000000u | rgb;\n                }\n            }\n        }\n    }\n'''
new='''    auto * words = static_cast<uint32_t *>(mapped);\n    const bool max_entropy[8] = {false, false, false, true, true, false, true, false};\n    const uint32_t tile_shifts[8] = {5u, 4u, 5u, 5u, 5u, 4u, 5u, 5u};\n    for (uint32_t pattern = 0; pattern < 8u; ++pattern)\n    {\n        uint32_t seed = 0x6d2b79f5u ^ (0x9e3779b9u * (pattern + 1u));\n        for (uint32_t eye = 0; eye < 2u; ++eye)\n        {\n            for (uint32_t y = 0; y < height; ++y)\n            {\n                for (uint32_t x = 0; x < width; ++x)\n                {\n                    seed ^= seed << 13;\n                    seed ^= seed >> 17;\n                    seed ^= seed << 5;\n                    const uint32_t tile = ((x >> tile_shifts[pattern]) ^\n                                           (y >> tile_shifts[pattern]) ^ eye ^ pattern) & 1u;\n                    const uint32_t base_rgb = tile ? 0x00c06020u : 0x002040c0u;\n                    const uint32_t rgb = max_entropy[pattern]\n                        ? (seed & 0x00ffffffu)\n                        : ((base_rgb & ~0x00030303u) | (seed & 0x00030303u));\n                    const VkDeviceSize pixel =\n                        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +\n                        VkDeviceSize(y) * VkDeviceSize(width) + x;\n                    words[pixel] = 0xff000000u | rgb;\n                }\n            }\n        }\n    }\n'''
if base.count(old) != 1:
    raise SystemExit(f'FAIL: frozen variable content anchor count={base.count(old)}')
expected=base.replace(old,new,1)
s=s.replace(old,new,1)
if s != expected:
    raise SystemExit('FAIL: entropy-spike source differs from frozen variable source beyond pattern-population block')
out_path.write_text(s)
PY

# Source-only audit: deadline, upload geometry, frame selector, copy path and render/event control flow stay frozen.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "8-pattern upload geometry changed"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "8-pattern frame selector changed"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'const bool max_entropy[8] = {false, false, false, true, true, false, true, false};' "$SRC" || fail "entropy-spike pattern schedule missing"
grep -Fq '? (seed & 0x00ffffffu)' "$SRC" || fail "max-entropy RGB path missing"
grep -Fq ': ((base_rgb & ~0x00030303u) | (seed & 0x00030303u));' "$SRC" || fail "low-complexity RGB path missing"
! grep -Fq 'const uint32_t noise_masks[8]' "$SRC" || fail "stale graduated-complexity masks remain"

OPENXR_LIB="$(awk -F= '$1=="openxr_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from frozen variable metadata"

echo '[1/2] Compiling entropy-spike 5-minute Vulkan stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "entropy-spike stimulus compile failed"

echo '[2/2] Recording entropy-spike stimulus metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
[[ "$SRC_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash format"
[[ "$BIN_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid binary hash format"
cat >"$META" <<EOF
base_variable_source=$BASE_SRC
base_variable_binary=$BASE_BIN
base_variable_metadata=$BASE_META
base_variable_seal=$BASE_SEAL
base_variable_source_sha256=$BASE_SOURCE_SHA
base_variable_binary_sha256=$BASE_BINARY_SHA
base_variable_metadata_sha256=$BASE_METADATA_SHA
base_variable_build_tooling=$BASE_BUILD_TOOLING
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
render_deadline_seconds=360
complexity_levels=8
complexity_profile=hard-low-max-entropy-spikes-easy-easy-easy-max-max-easy-max-easy
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-hard-entropy-spike8-sustained360
source_delta=PASS frozen-variable-only-pattern-population-block
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash format"
printf '\nPASS: entropy-spike 5-minute stimulus built from frozen variable-complexity stimulus.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nrender_deadline_seconds=360\ncomplexity_levels=8\npattern_profile=easy,easy,easy,MAX,MAX,easy,MAX,easy\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
