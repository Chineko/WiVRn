#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="eb47f77d890f6dd10cadaee62dbfb80c37dc3fe2"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_entropy_spike_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-entropy-spike-v1"
META="$ROOT/vulkan-stimulus-sustained-5min-entropy-spike-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-5min-entropy-spike-v1-seal.txt"

BASE_SOURCE_SHA="e106d7b0ed0127c5fcead1de86b1529ae0bee11382cce938c78f348caaca40c0"
BASE_BINARY_SHA="04e8d53508879620a1cbb1415a35338eebf619183e1a6e3e57d8cfa21e820b8e"
BASE_METADATA_SHA="93f4e1611737e5953a13e7835f19a541be9dd034629a6a78cfd79a4429acf348"
BASE_BUILD_TOOLING="79339d9cffa4c2afa738d7eecc919481e61d3325"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing entropy-spike artifact: $f"; done
[[ -x "$BIN" ]] || fail "entropy-spike binary is not executable"

grep -Fqx "base_variable_source_sha256=$BASE_SOURCE_SHA" "$META" || fail "base variable source hash mismatch"
grep -Fqx "base_variable_binary_sha256=$BASE_BINARY_SHA" "$META" || fail "base variable binary hash mismatch"
grep -Fqx "base_variable_metadata_sha256=$BASE_METADATA_SHA" "$META" || fail "base variable metadata hash mismatch"
grep -Fqx "base_variable_build_tooling=$BASE_BUILD_TOOLING" "$META" || fail "base variable tooling mismatch"
grep -Fqx 'render_deadline_seconds=360' "$META" || fail "render deadline mismatch"
grep -Fqx 'complexity_levels=8' "$META" || fail "complexity level count mismatch"
grep -Fqx 'complexity_profile=hard-low-max-entropy-spikes-easy-easy-easy-max-max-easy-max-easy' "$META" || fail "complexity profile mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-hard-entropy-spike8-sustained360' "$META" || fail "stimulus contract marker missing"
grep -Fqx 'source_delta=PASS frozen-variable-only-pattern-population-block' "$META" || fail "source delta marker missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status is not NOT_RUN"

# Re-audit that only content severity changed; all control-flow/resource geometry remains frozen.
grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second deadline missing"
grep -Fq 'const VkDeviceSize upload_bytes = pattern_bytes * 8;' "$SRC" || fail "upload geometry mismatch"
grep -Fq 'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;' "$SRC" || fail "frame selector mismatch"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "copy path missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'const bool max_entropy[8] = {false, false, false, true, true, false, true, false};' "$SRC" || fail "entropy-spike pattern schedule missing"
grep -Fq '? (seed & 0x00ffffffu)' "$SRC" || fail "max-entropy path missing"
grep -Fq ': ((base_rgb & ~0x00030303u) | (seed & 0x00030303u));' "$SRC" || fail "low-complexity path missing"
! grep -Fq 'const uint32_t noise_masks[8]' "$SRC" || fail "stale graduated-complexity masks remain"

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
base_variable_source_sha256=$BASE_SOURCE_SHA
base_variable_binary_sha256=$BASE_BINARY_SHA
base_variable_metadata_sha256=$BASE_METADATA_SHA
base_variable_build_tooling=$BASE_BUILD_TOOLING
render_deadline_seconds=360
complexity_levels=8
complexity_profile=hard-low-max-entropy-spikes-easy-easy-easy-max-max-easy-max-easy
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS sustained-5min-entropy-spike-v1-frozen-variable-single-content-block-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-entropy-spike-v1-frozen-variable-single-content-block-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: entropy-spike 5-minute Vulkan stimulus artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' \
  "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
