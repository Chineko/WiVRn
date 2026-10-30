#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="79339d9cffa4c2afa738d7eecc919481e61d3325"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_variable_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-variable-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-variable-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-5min-variable-v1-seal.txt"

FROZEN_SOURCE_SHA="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
FROZEN_BINARY_SHA="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
FROZEN_METADATA_SHA="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing variable-complexity artifact: $f"; done
[[ -x "$BIN" ]] || fail "variable-complexity binary is not executable"

# Bind the derivative to the exact frozen 5-minute artifact set.
grep -Fqx "base_5min_source_sha256=$FROZEN_SOURCE_SHA" "$META" || fail "base source hash mismatch"
grep -Fqx "base_5min_binary_sha256=$FROZEN_BINARY_SHA" "$META" || fail "base binary hash mismatch"
grep -Fqx "base_5min_metadata_sha256=$FROZEN_METADATA_SHA" "$META" || fail "base metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$META" || fail "render deadline mismatch"
grep -Fqx 'complexity_levels=8' "$META" || fail "complexity level count mismatch"
grep -Fqx 'complexity_profile=structured-tiles-plus-deterministic-noise-2-to-8-bits' "$META" || fail "complexity profile mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-variable-complexity8-sustained360' "$META" || fail "stimulus contract marker missing"
grep -Fqx 'source_delta=PASS frozen-5min-only-pattern-population-block' "$META" || fail "source delta marker missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status is not NOT_RUN"

# Re-audit the exact source properties that must remain frozen around the content-only delta.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "upload geometry mismatch"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "frame selector mismatch"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'const uint32_t noise_masks[8]' "$SRC" || fail "noise masks missing"
grep -Fq 'const uint32_t tile_shifts[8]' "$SRC" || fail "tile shifts missing"
grep -Fq 'words[pixel] = 0xff000000u | rgb;' "$SRC" || fail "variable pixel write missing"
! grep -Fq 'const VkDeviceSize word_count = upload_bytes / sizeof(uint32_t);' "$SRC" || fail "stale uniform-random fill remains"

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
base_5min_source_sha256=$FROZEN_SOURCE_SHA
base_5min_binary_sha256=$FROZEN_BINARY_SHA
base_5min_metadata_sha256=$FROZEN_METADATA_SHA
render_deadline_seconds=360
complexity_levels=8
complexity_profile=structured-tiles-plus-deterministic-noise-2-to-8-bits
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS sustained-5min-variable-v1-frozen-base-single-content-block-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

# Read back the seal so a malformed write cannot be reported as success.
grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-variable-v1-frozen-base-single-content-block-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: variable-complexity 5-minute Vulkan stimulus artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' \
  "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
