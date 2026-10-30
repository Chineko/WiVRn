#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
TOOLING_COMMIT="1346a215fad30861651bfd054c8e5cd162bca06f"
BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$BUILD_ROOT/helix_vulkan_stimulus.cpp"
BIN="$BUILD_ROOT/helix-vulkan-stimulus"
META="$BUILD_ROOT/vulkan-stimulus-metadata.txt"
SEAL="$BUILD_ROOT/vulkan-stimulus-seal.txt"

fail(){ echo "error: $*" >&2; exit 2; }
for c in file grep ldd readelf sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$BIN" ]] || fail "stimulus is not executable"

grep -Fq "source_commit=$SOURCE_COMMIT" "$META" || fail "stimulus metadata source mismatch"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-projection-layer' "$META" || fail "stimulus contract marker missing"
grep -Fq 'runtime_status=NOT_RUN' "$META" || fail "stimulus runtime state is not NOT_RUN"

for marker in \
  'HELIX_VULKAN_ENTROPY patterns=8' \
  'vkCmdCopyBufferToImage' \
  'XrGraphicsBindingVulkanKHR' \
  'XrSwapchainImageVulkanKHR' \
  'produced % 8u' \
  'HELIX_VULKAN_DONE frames=%u'; do
  grep -Fq "$marker" "$SRC" || fail "generated source marker missing: $marker"
done
for forbidden in 'XR_MND_headless' 'vkCmdClearColorImage' 'XrGraphicsBindingVulkan2KHR' 'XrSwapchainImageVulkan2KHR'; do
  ! grep -Fq "$forbidden" "$SRC" || fail "forbidden generated source marker present: $forbidden"
done

FILE_INFO="$(file "$BIN")"
grep -Eq 'ELF 64-bit.*x86-64' <<<"$FILE_INFO" || fail "unexpected stimulus binary format"
DYNAMIC="$(readelf -d "$BIN")"
grep -Fq 'libopenxr_loader.so.1' <<<"$DYNAMIC" || fail "stimulus does not depend on OpenXR loader"
grep -Fq 'libvulkan.so.1' <<<"$DYNAMIC" || fail "stimulus does not depend on Vulkan loader"
LDD="$(ldd "$BIN")"
! grep -Fq 'not found' <<<"$LDD" || fail "stimulus has unresolved dynamic dependency"
grep -Fq 'libopenxr_loader.so.1' <<<"$LDD" || fail "OpenXR loader missing from resolved dependency set"
grep -Fq 'libvulkan.so.1' <<<"$LDD" || fail "Vulkan loader missing from resolved dependency set"
grep -aFq 'HELIX_VULKAN_ENTROPY patterns=8' "$BIN" || fail "entropy marker missing from compiled binary"
grep -aFq 'HELIX_VULKAN_DONE frames=%u' "$BIN" || fail "completion marker missing from compiled binary"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
cat >"$SEAL" <<EOF
source_commit=$SOURCE_COMMIT
tooling_commit=$TOOLING_COMMIT
stimulus_source=$SRC
stimulus_binary=$BIN
stimulus_metadata=$META
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS exact-generated-source-binary-metadata
runtime_status=NOT_RUN
EOF

printf 'PASS: encoded Vulkan stimulus artifact sealed.\nsource_commit=%s\ntooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' "$SOURCE_COMMIT" "$TOOLING_COMMIT" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
