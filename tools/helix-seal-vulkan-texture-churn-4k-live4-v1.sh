#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="b5db206941900271be24ffdbefa4dc21b31edb76"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-v1"
META="$ROOT/vulkan-texture-churn-4k-live4-v1-metadata.txt"
SEAL="$ROOT/vulkan-texture-churn-4k-live4-v1-seal.txt"

BASE_SOURCE_SHA="3161d5772aef9cb6c175866aded7f35389d5733fef8c777205664107b6059f18"
BASE_BINARY_SHA="1cd8ef4584968b20d7bff4ee72c7129c095d9977a417246ab2f83c5ce6ff38e2"
BASE_METADATA_SHA="a9514dc5b830e6652b2efe92b003c65b39f5770a437c39b37d85e530fa2b11b1"
BASE_BUILD_TOOLING="397dcd68306978e39bd8960977633ef9776f873a"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing four-live churn artifact: $f"; done
[[ -x "$BIN" ]] || fail "four-live churn binary not executable"

grep -Fqx "base_single_source_sha256=$BASE_SOURCE_SHA" "$META" || fail "base source binding mismatch"
grep -Fqx "base_single_binary_sha256=$BASE_BINARY_SHA" "$META" || fail "base binary binding mismatch"
grep -Fqx "base_single_metadata_sha256=$BASE_METADATA_SHA" "$META" || fail "base metadata binding mismatch"
grep -Fqx "base_single_build_tooling=$BASE_BUILD_TOOLING" "$META" || fail "base tooling binding mismatch"
grep -Fqx 'texture_width=4096' "$META" || fail "texture width mismatch"
grep -Fqx 'texture_height=4096' "$META" || fail "texture height mismatch"
grep -Fqx 'texture_format=VK_FORMAT_R8G8B8A8_UNORM' "$META" || fail "texture format mismatch"
grep -Fqx 'texture_bytes=67108864' "$META" || fail "texture bytes mismatch"
grep -Fqx 'interval_ms=2000' "$META" || fail "interval mismatch"
grep -Fqx 'max_cycles=180' "$META" || fail "cycle cap mismatch"
grep -Fqx 'live_images=4' "$META" || fail "live image count mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$META" || fail "live texture bytes mismatch"
grep -Fqx 'staging_lifecycle=persistent' "$META" || fail "staging lifecycle mismatch"
grep -Fqx 'readback_verification=one-pixel-every-cycle' "$META" || fail "readback verification mismatch"
grep -Fqx 'churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-destroy-free' "$META" || fail "churn lifecycle mismatch"
grep -Fqx 'churn_contract=PASS deterministic-four-live-4k-rgba-device-memory-lifecycle-upload-readback-v1' "$META" || fail "churn contract missing"
grep -Fqx 'source_delta=PASS frozen-single-live-only-retention-ring-1-to-4' "$META" || fail "source delta missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status not NOT_RUN"

# Source re-audit.
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "source live slot count mismatch"
grep -Fq 'const uint32_t slot=cycle%LIVE_SLOTS;' "$SRC" || fail "source slot selector missing"
grep -Fq 'live_images[slot]=image;live_memory[slot]=mem;cycles++;' "$SRC" || fail "source retained assignment missing"
grep -Fq 'constexpr uint32_t INTERVAL_MS=2000;' "$SRC" || fail "source cadence mismatch"
grep -Fq 'constexpr uint32_t MAX_CYCLES=180;' "$SRC" || fail "source cycle cap mismatch"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "source upload path missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "source readback path missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "unexpected source buffer creation count"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "unexpected source image creation call count"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
grep -Fqx "source_sha256=$SRC_SHA" "$META" || fail "metadata source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$META" || fail "metadata binary hash mismatch"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
base_single_source_sha256=$BASE_SOURCE_SHA
base_single_binary_sha256=$BASE_BINARY_SHA
base_single_metadata_sha256=$BASE_METADATA_SHA
base_single_build_tooling=$BASE_BUILD_TOOLING
texture_width=4096
texture_height=4096
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=67108864
interval_ms=2000
max_cycles=180
live_images=4
live_texture_bytes=268435456
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS texture-churn-4k-live4-v1-ring4-256MiB-persistent-staging-upload-readback-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'live_images=4' "$SEAL" || fail "seal live_images mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$SEAL" || fail "seal live bytes mismatch"
grep -Fqx 'artifact_seal=PASS texture-churn-4k-live4-v1-ring4-256MiB-persistent-staging-upload-readback-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: deterministic four-live 4K Vulkan texture churn artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\ntexture=4096x4096 RGBA8\ntexture_bytes=67108864\ninterval_ms=2000\nmax_cycles=180\nlive_images=4\nlive_texture_bytes=268435456\nSTATUS: artifact sealed; runtime not executed.\n' "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
