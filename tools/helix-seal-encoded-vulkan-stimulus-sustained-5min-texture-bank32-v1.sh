#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="ec7661c38898e0c1faab5374e2057014866b4ba8"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_texture_bank32_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-texture-bank32-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-seal.txt"

BASE_SOURCE_SHA="e96dbd35d77faacdb98fb8851d6c5d5e21ffbb35b429c3c35b7b358dee08fe03"
BASE_BINARY_SHA="c1ab93c41eb65010b583f9c23fa8a1cb410167bcab1e29038985f76a6676e88e"
BASE_METADATA_SHA="c22c78010716059e13e8c750e380304042aa6dcfa6678601d36df0181c8b6395"
BASE_BUILD_TOOLING="eb47f77d890f6dd10cadaee62dbfb80c37dc3fe2"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing texture-bank32 artifact: $f"; done
[[ -x "$BIN" ]] || fail "texture-bank32 binary is not executable"

grep -Fqx "base_entropy_source_sha256=$BASE_SOURCE_SHA" "$META" || fail "base entropy source hash mismatch"
grep -Fqx "base_entropy_binary_sha256=$BASE_BINARY_SHA" "$META" || fail "base entropy binary hash mismatch"
grep -Fqx "base_entropy_metadata_sha256=$BASE_METADATA_SHA" "$META" || fail "base entropy metadata hash mismatch"
grep -Fqx "base_entropy_build_tooling=$BASE_BUILD_TOOLING" "$META" || fail "base entropy tooling mismatch"
grep -Fqx 'render_deadline_seconds=360' "$META" || fail "render deadline mismatch"
grep -Fqx 'texture_bank_patterns=32' "$META" || fail "texture bank pattern count mismatch"
grep -Fqx 'texture_bank_multiplier=4' "$META" || fail "texture bank multiplier mismatch"
grep -Fqx 'entropy_phase_patterns=8' "$META" || fail "entropy phase pattern count mismatch"
grep -Fqx 'entropy_profile=easy-easy-easy-max-max-easy-max-easy-repeated-4x' "$META" || fail "entropy profile mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy-spike-bank32-sustained360' "$META" || fail "stimulus contract marker missing"
grep -Fqx 'source_delta=PASS frozen-entropy-only-preallocated-bank-8-to-32' "$META" || fail "source delta marker missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status is not NOT_RUN"

# Re-audit geometry/indexing and frozen control flow.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 32;' "$SRC" || fail "32-pattern upload geometry missing"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 32u) * pattern_bytes;' "$SRC" || fail "32-pattern frame selector missing"
grep -Fq 'for (uint32_t pattern = 0; pattern < 32u; ++pattern)' "$SRC" || fail "32-pattern population loop missing"
grep -Fq 'const uint32_t phase = pattern % 8u;' "$SRC" || fail "entropy phase repetition missing"
grep -Fq 'const bool max_entropy_phase[8] = {false, false, false, true, true, false, true, false};' "$SRC" || fail "entropy phase schedule missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
! grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "stale 8-pattern geometry remains"
! grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "stale 8-pattern selector remains"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"
printf '%s\n' "$LD" | grep -Fq 'libopenxr_loader.so.1' || fail "OpenXR loader dependency missing"
printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"
! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dynamic dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for value in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash format: $value"; done

grep -Fqx "source_sha256=$SRC_SHA" "$META" || fail "metadata source hash does not match actual source"
grep -Fqx "binary_sha256=$BIN_SHA" "$META" || fail "metadata binary hash does not match actual binary"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
base_entropy_source_sha256=$BASE_SOURCE_SHA
base_entropy_binary_sha256=$BASE_BINARY_SHA
base_entropy_metadata_sha256=$BASE_METADATA_SHA
base_entropy_build_tooling=$BASE_BUILD_TOOLING
render_deadline_seconds=360
texture_bank_patterns=32
texture_bank_multiplier=4
entropy_phase_patterns=8
entropy_profile=easy-easy-easy-max-max-easy-max-easy-repeated-4x
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'texture_bank_patterns=32' "$SEAL" || fail "seal bank size mismatch"
grep -Fqx 'texture_bank_multiplier=4' "$SEAL" || fail "seal bank multiplier mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: 32-pattern texture-bank 5-minute Vulkan stimulus artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\ntexture_bank_patterns=32\ntexture_bank_multiplier=4\nSTATUS: artifact sealed; runtime not executed.\n' \
  "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
