#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="e5c77bc488ebc4eb3d8c03e66511cd1c60daa271"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-v1"
META="$ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-v1-seal.txt"

FROZEN_V5_SOURCE_SHA="b10067c6127af12c5d83e7b79f5020830d8722c4c80dc27a4c54635a3adfa901"
FROZEN_V5_BINARY_SHA="5d55b5b522f8408843d9ac83bda7fe6a6fd3a37d135464dd8bd63b115a5409c4"
FROZEN_V5_METADATA_SHA="75a7bcc0570c650680e953fe88f7c8f4d6cece891d585b337c210d38be524a91"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing sustained-v1 artifact: $f"; done
[[ -x "$BIN" ]] || fail "sustained-v1 binary is not executable"

grep -Fqx "base_v5_source_sha256=$FROZEN_V5_SOURCE_SHA" "$META" || fail "base V5 source hash mismatch"
grep -Fqx "base_v5_binary_sha256=$FROZEN_V5_BINARY_SHA" "$META" || fail "base V5 binary hash mismatch"
grep -Fqx "base_v5_metadata_sha256=$FROZEN_V5_METADATA_SHA" "$META" || fail "base V5 metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$META" || fail "sustained render deadline mismatch"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360' "$META" || fail "sustained contract marker missing"
grep -Fqx 'source_delta=PASS frozen-v5-only-render-deadline-20-to-360' "$META" || fail "sustained source delta marker missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "sustained runtime status is not NOT_RUN"

grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "360-second render deadline missing"
! grep -Fq 'std::chrono::seconds(20);' "$SRC" || fail "20-second render deadline remains"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "entropy8 marker missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump marker missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC" || fail "render progress marker missing"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "sustained-v1 binary is not x86-64 ELF"
LD="$(ldd "$BIN")"
printf '%s\n' "$LD" | grep -Fq 'libopenxr_loader.so.1' || fail "OpenXR loader dependency missing"
printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"
! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved sustained-v1 dynamic dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"

grep -Fqx "source_sha256=$SRC_SHA" "$META" || fail "metadata source hash does not match actual source"
grep -Fqx "binary_sha256=$BIN_SHA" "$META" || fail "metadata binary hash does not match actual binary"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
base_v5_source_sha256=$FROZEN_V5_SOURCE_SHA
base_v5_binary_sha256=$FROZEN_V5_BINARY_SHA
base_v5_metadata_sha256=$FROZEN_V5_METADATA_SHA
render_deadline_seconds=360
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

printf 'PASS: sustained-v1 Vulkan stimulus artifact sealed.\nbuild_tooling_commit=%s\nbase_v5_source_sha256=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' \
  "$BUILD_TOOLING" "$FROZEN_V5_SOURCE_SHA" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
