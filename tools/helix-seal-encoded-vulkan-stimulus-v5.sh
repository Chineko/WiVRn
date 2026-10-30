#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
BUILD_TOOLING="8430f775e0d5f2847683406a70c9695e22ac36df"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus_v5.cpp"
BIN="$ROOT/helix-vulkan-stimulus-v5"
META="$ROOT/vulkan-stimulus-v5-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-v5-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in grep sha256sum file ldd awk sed; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing v5 artifact: $f"; done
[[ -x "$BIN" ]] || fail "v5 binary is not executable"

grep -Fq "source_commit=$SOURCE_COMMIT" "$META" || fail "v5 metadata source mismatch"
grep -Fq "base_generator_commit=1346a215fad30861651bfd054c8e5cd162bca06f" "$META" || fail "v5 metadata generator mismatch"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$META" || fail "v5 contract marker missing"
grep -Fq 'runtime_status=NOT_RUN' "$META" || fail "v5 runtime status is not NOT_RUN"

grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "entropy8 source marker missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump source marker missing"
grep -Fq 'xrEndFrame_idle' "$SRC" || fail "idle frame cadence source marker missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC" || fail "render-only progress marker missing"
! grep -Fq 'for (; produced < target_frames; ++produced)' "$SRC" || fail "stale unconditional frame counter remains"
! grep -Fq 'XR_MND_headless' "$SRC" || fail "headless path leaked into v5 source"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "v5 binary is not x86-64 ELF"
LD="$(ldd "$BIN")"
printf '%s\n' "$LD" | grep -Fq 'libopenxr_loader.so.1' || fail "OpenXR loader dependency missing"
printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"
! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved v5 dynamic dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
cat >"$SEAL" <<EOF
source_commit=$SOURCE_COMMIT
build_tooling_commit=$BUILD_TOOLING
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS strict-v5-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

printf 'PASS: strict-v5 Vulkan stimulus artifact sealed.\nsource_commit=%s\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' "$SOURCE_COMMIT" "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
