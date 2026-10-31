#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_entropy_spike_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-entropy-spike-v1"
BASE_META="$ROOT/vulkan-stimulus-sustained-5min-entropy-spike-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-stimulus-sustained-5min-entropy-spike-v1-seal.txt"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_texture_bank32_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-texture-bank32-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"

BASE_SOURCE_SHA="e96dbd35d77faacdb98fb8851d6c5d5e21ffbb35b429c3c35b7b358dee08fe03"
BASE_BINARY_SHA="c1ab93c41eb65010b583f9c23fa8a1cb410167bcab1e29038985f76a6676e88e"
BASE_METADATA_SHA="c22c78010716059e13e8c750e380304042aa6dcfa6678601d36df0181c8b6395"
BASE_BUILD_TOOLING="eb47f77d890f6dd10cadaee62dbfb80c37dc3fe2"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen entropy-spike artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen entropy-spike binary is not executable"

[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$BASE_SOURCE_SHA" ]] || fail "frozen entropy-spike source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$BASE_BINARY_SHA" ]] || fail "frozen entropy-spike binary hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_METADATA_SHA" ]] || fail "frozen entropy-spike metadata hash mismatch"
grep -Fqx "build_tooling_commit=$BASE_BUILD_TOOLING" "$BASE_SEAL" || fail "frozen entropy-spike build tooling mismatch"
grep -Fqx "source_sha256=$BASE_SOURCE_SHA" "$BASE_SEAL" || fail "frozen entropy-spike seal source hash mismatch"
grep -Fqx "binary_sha256=$BASE_BINARY_SHA" "$BASE_SEAL" || fail "frozen entropy-spike seal binary hash mismatch"
grep -Fqx "metadata_sha256=$BASE_METADATA_SHA" "$BASE_SEAL" || fail "frozen entropy-spike seal metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$BASE_SEAL" || fail "frozen entropy-spike deadline mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-entropy-spike-v1-frozen-variable-single-content-block-source-binary-metadata-deps' "$BASE_SEAL" || fail "frozen entropy-spike seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-hard-entropy-spike8-sustained360' "$BASE_META" || fail "frozen entropy-spike contract marker missing"
grep -Fqx 'source_delta=PASS frozen-variable-only-pattern-population-block' "$BASE_META" || fail "frozen entropy-spike source delta marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$BASE_SRC" "$SRC" <<'PY'
from pathlib import Path
import sys
base_path=Path(sys.argv[1]); out_path=Path(sys.argv[2])
base=base_path.read_text(); s=out_path.read_text()

replacements = [
    ('const VkDeviceSize upload_bytes = pattern_bytes * 8;',
     'const VkDeviceSize upload_bytes = pattern_bytes * 32;',
     'upload bank 8 to 32'),
    ('const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;',
     'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 32u) * pattern_bytes;',
     'frame selector 8 to 32'),
]
for old,new,label in replacements:
    n=base.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    base=base.replace(old,new,1)

old='''    auto * words = static_cast<uint32_t *>(mapped);\n    const bool max_entropy[8] = {false, false, false, true, true, false, true, false};\n    const uint32_t tile_shifts[8] = {5u, 4u, 5u, 5u, 5u, 4u, 5u, 5u};\n    for (uint32_t pattern = 0; pattern < 8u; ++pattern)\n    {\n        uint32_t seed = 0x6d2b79f5u ^ (0x9e3779b9u * (pattern + 1u));\n        for (uint32_t eye = 0; eye < 2u; ++eye)\n        {\n            for (uint32_t y = 0; y < height; ++y)\n            {\n                for (uint32_t x = 0; x < width; ++x)\n                {\n                    seed ^= seed << 13;\n                    seed ^= seed >> 17;\n                    seed ^= seed << 5;\n                    const uint32_t tile = ((x >> tile_shifts[pattern]) ^\n                                           (y >> tile_shifts[pattern]) ^ eye ^ pattern) & 1u;\n                    const uint32_t base_rgb = tile ? 0x00c06020u : 0x002040c0u;\n                    const uint32_t rgb = max_entropy[pattern]\n                        ? (seed & 0x00ffffffu)\n                        : ((base_rgb & ~0x00030303u) | (seed & 0x00030303u));\n                    const VkDeviceSize pixel =\n                        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +\n                        VkDeviceSize(y) * VkDeviceSize(width) + x;\n                    words[pixel] = 0xff000000u | rgb;\n                }\n            }\n        }\n    }\n'''
new='''    auto * words = static_cast<uint32_t *>(mapped);\n    const bool max_entropy_phase[8] = {false, false, false, true, true, false, true, false};\n    const uint32_t tile_shifts[8] = {5u, 4u, 5u, 5u, 5u, 4u, 5u, 5u};\n    for (uint32_t pattern = 0; pattern < 32u; ++pattern)\n    {\n        const uint32_t phase = pattern % 8u;\n        uint32_t seed = 0x6d2b79f5u ^ (0x9e3779b9u * (pattern + 1u));\n        for (uint32_t eye = 0; eye < 2u; ++eye)\n        {\n            for (uint32_t y = 0; y < height; ++y)\n            {\n                for (uint32_t x = 0; x < width; ++x)\n                {\n                    seed ^= seed << 13;\n                    seed ^= seed >> 17;\n                    seed ^= seed << 5;\n                    const uint32_t tile = ((x >> tile_shifts[phase]) ^\n                                           (y >> tile_shifts[phase]) ^ eye ^ pattern) & 1u;\n                    const uint32_t base_rgb = tile ? 0x00c06020u : 0x002040c0u;\n                    const uint32_t rgb = max_entropy_phase[phase]\n                        ? (seed & 0x00ffffffu)\n                        : ((base_rgb & ~0x00030303u) | (seed & 0x00030303u));\n                    const VkDeviceSize pixel =\n                        (VkDeviceSize(pattern) * 2u + eye) * VkDeviceSize(width) * VkDeviceSize(height) +\n                        VkDeviceSize(y) * VkDeviceSize(width) + x;\n                    words[pixel] = 0xff000000u | rgb;\n                }\n            }\n        }\n    }\n'''
if base.count(old) != 1:
    raise SystemExit(f'FAIL: frozen entropy content anchor count={base.count(old)}')
expected=base.replace(old,new,1)
s=out_path.read_text()
s=s.replace('const VkDeviceSize upload_bytes = pattern_bytes * 8;', 'const VkDeviceSize upload_bytes = pattern_bytes * 32;', 1)
s=s.replace('const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;', 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 32u) * pattern_bytes;', 1)
s=s.replace(old,new,1)
if s != expected:
    raise SystemExit('FAIL: bank32 source differs from entropy-spike source beyond bank-size/selector/content-loop changes')
out_path.write_text(s)
PY

# Audit: only preallocated bank geometry/indexing expands; per-frame copy path and render/event control flow remain frozen.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 32;' "$SRC" || fail "32-pattern upload geometry missing"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 32u) * pattern_bytes;' "$SRC" || fail "32-pattern frame selector missing"
grep -Fq 'for (uint32_t pattern = 0; pattern < 32u; ++pattern)' "$SRC" || fail "32-pattern population loop missing"
grep -Fq 'const uint32_t phase = pattern % 8u;' "$SRC" || fail "8-phase entropy profile repetition missing"
grep -Fq 'const bool max_entropy_phase[8] = {false, false, false, true, true, false, true, false};' "$SRC" || fail "entropy phase schedule missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
! grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "stale 8-pattern upload geometry remains"
! grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "stale 8-pattern selector remains"

OPENXR_LIB="$(awk -F= '$1=="openxr_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from entropy-spike metadata"

echo '[1/2] Compiling 32-pattern texture-bank 5-minute Vulkan stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "texture-bank32 stimulus compile failed"

echo '[2/2] Recording texture-bank32 stimulus metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
[[ "$SRC_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash format"
[[ "$BIN_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid binary hash format"
cat >"$META" <<EOF
base_entropy_source=$BASE_SRC
base_entropy_binary=$BASE_BIN
base_entropy_metadata=$BASE_META
base_entropy_seal=$BASE_SEAL
base_entropy_source_sha256=$BASE_SOURCE_SHA
base_entropy_binary_sha256=$BASE_BINARY_SHA
base_entropy_metadata_sha256=$BASE_METADATA_SHA
base_entropy_build_tooling=$BASE_BUILD_TOOLING
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
render_deadline_seconds=360
texture_bank_patterns=32
texture_bank_multiplier=4
entropy_phase_patterns=8
entropy_profile=easy-easy-easy-max-max-easy-max-easy-repeated-4x
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy-spike-bank32-sustained360
source_delta=PASS frozen-entropy-only-preallocated-bank-8-to-32
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash format"
printf '\nPASS: 32-pattern texture-bank 5-minute stimulus built from frozen entropy-spike stimulus.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nrender_deadline_seconds=360\ntexture_bank_patterns=32\ntexture_bank_multiplier=4\nentropy_profile=easy,easy,easy,MAX,MAX,easy,MAX,easy repeated 4x\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
