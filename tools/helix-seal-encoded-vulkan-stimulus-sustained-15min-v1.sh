#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="0b4ba80f4ad912aba7000c581ac5b4f8e621956d"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_sustained_15min_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-15min-v1"
META="$ROOT/vulkan-stimulus-sustained-15min-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-15min-v1-seal.txt"

FROZEN_5MIN_SOURCE_SHA="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
FROZEN_5MIN_BINARY_SHA="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
FROZEN_5MIN_METADATA_SHA="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing 15-minute artifact: $f"; done
[[ -x "$BIN" ]] || fail "15-minute binary is not executable"

grep -Fqx "base_5min_source_sha256=$FROZEN_5MIN_SOURCE_SHA" "$META" || fail "base 5-minute source hash mismatch"
grep -Fqx "base_5min_binary_sha256=$FROZEN_5MIN_BINARY_SHA" "$META" || fail "base 5-minute binary hash mismatch"
grep -Fqx "base_5min_metadata_sha256=$FROZEN_5MIN_METADATA_SHA" "$META" || fail "base 5-minute metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=1080' "$META" || fail "15-minute render deadline mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained1080' "$META" || fail "15-minute contract marker missing"
grep -Fqx 'source_delta=PASS frozen-5min-only-render-deadline-360-to-1080' "$META" || fail "15-minute source delta marker missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "15-minute runtime status is not NOT_RUN"

grep -Fq 'std::chrono::seconds(1080)' "$SRC" || fail "1080-second render deadline missing"
! grep -Fq 'std::chrono::seconds(360);' "$SRC" || fail "360-second deadline remains"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "entropy8 marker missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump marker missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC" || fail "render progress marker missing"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "15-minute binary is not x86-64 ELF"
LD="$(ldd "$BIN")"
printf '%s\n' "$LD" | grep -Fq 'libopenxr_loader.so.1' || fail "OpenXR loader dependency missing"
printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"
! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved 15-minute dynamic dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"

grep -Fqx "source_sha256=$SRC_SHA" "$META" || fail "metadata source hash does not match actual source"
grep -Fqx "binary_sha256=$BIN_SHA" "$META" || fail "metadata binary hash does not match actual binary"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
base_5min_source_sha256=$FROZEN_5MIN_SOURCE_SHA
base_5min_binary_sha256=$FROZEN_5MIN_BINARY_SHA
base_5min_metadata_sha256=$FROZEN_5MIN_METADATA_SHA
render_deadline_seconds=1080
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS sustained-15min-v1-frozen-5min-single-deadline-delta-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

printf 'PASS: 15-minute sustained Vulkan stimulus artifact sealed.\nbuild_tooling_commit=%s\nbase_5min_source_sha256=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' \
  "$BUILD_TOOLING" "$FROZEN_5MIN_SOURCE_SHA" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
