#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="8ad7de213960a4fcbe1d43522e938cb1aee16dfb"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-v1"
META="$ROOT/vulkan-texture-churn-4k-v1-metadata.txt"
SEAL="$ROOT/vulkan-texture-churn-4k-v1-seal.txt"
BANK_SOURCE_SHA="8cb614a1bdff0be412b58503c301674372272ff9485a963122eb8d9f3e22fecb"
BANK_BINARY_SHA="3e7aa0d617fcbbd933eea54ed4edee66e966a76c82db6ae11a5ef8afa4b0f0f9"
BANK_METADATA_SHA="c8de14bec0d1e46fc1dd059ff6b80f033e8f69dae9db880d58cbe69e87286ccf"
BANK_BUILD_TOOLING="ec7661c38898e0c1faab5374e2057014866b4ba8"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing churn artifact: $f"; done
[[ -x "$BIN" ]] || fail "churn binary is not executable"

grep -Fqx "bank32_source_sha256=$BANK_SOURCE_SHA" "$META" || fail "bank32 source binding mismatch"
grep -Fqx "bank32_binary_sha256=$BANK_BINARY_SHA" "$META" || fail "bank32 binary binding mismatch"
grep -Fqx "bank32_metadata_sha256=$BANK_METADATA_SHA" "$META" || fail "bank32 metadata binding mismatch"
grep -Fqx "bank32_build_tooling=$BANK_BUILD_TOOLING" "$META" || fail "bank32 tooling binding mismatch"
grep -Fqx 'texture_width=4096' "$META" || fail "texture width mismatch"
grep -Fqx 'texture_height=4096' "$META" || fail "texture height mismatch"
grep -Fqx 'texture_format=VK_FORMAT_R8G8B8A8_UNORM' "$META" || fail "texture format mismatch"
grep -Fqx 'texture_bytes=67108864' "$META" || fail "texture bytes mismatch"
grep -Fqx 'interval_ms=2000' "$META" || fail "interval mismatch"
grep -Fqx 'max_cycles=180' "$META" || fail "cycle cap mismatch"
grep -Fqx 'live_images=1' "$META" || fail "live image count mismatch"
grep -Fqx 'staging_lifecycle=persistent' "$META" || fail "staging lifecycle mismatch"
grep -Fqx 'readback_verification=one-pixel-every-cycle' "$META" || fail "readback contract mismatch"
grep -Fqx 'churn_lifecycle=create-image-allocate-bind-upload-transition-readback-destroy-free' "$META" || fail "lifecycle contract mismatch"
grep -Fqx 'churn_contract=PASS deterministic-single-4k-rgba-device-memory-lifecycle-upload-readback-v1' "$META" || fail "churn contract missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status is not NOT_RUN"

# Re-audit the source so a matching metadata file cannot hide a stale or widened workload.
grep -Fq 'constexpr uint32_t W=4096, H=4096;' "$SRC" || fail "source 4K geometry missing"
grep -Fq 'constexpr uint32_t INTERVAL_MS=2000;' "$SRC" || fail "source interval missing"
grep -Fq 'constexpr uint32_t MAX_CYCLES=180;' "$SRC" || fail "source cycle cap missing"
grep -Fq 'VK_IMAGE_USAGE_TRANSFER_DST_BIT|VK_IMAGE_USAGE_TRANSFER_SRC_BIT' "$SRC" || fail "source image usage missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "source upload missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "source readback missing"
grep -Fq 'vkDestroyImage(dev,image,nullptr);vkFreeMemory(dev,mem,nullptr);frees++;cycles++;' "$SRC" || fail "source destroy/free lifecycle missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "unexpected source buffer creation count"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "unexpected source image creation call count"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dynamic dependency"

SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
grep -Fqx "source_sha256=$SRC_SHA" "$META" || fail "metadata source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$META" || fail "metadata binary hash mismatch"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
bank32_source_sha256=$BANK_SOURCE_SHA
bank32_binary_sha256=$BANK_BINARY_SHA
bank32_metadata_sha256=$BANK_METADATA_SHA
bank32_build_tooling=$BANK_BUILD_TOOLING
texture_width=4096
texture_height=4096
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=67108864
interval_ms=2000
max_cycles=180
live_images=1
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS texture-churn-4k-v1-single-live-image-persistent-staging-upload-readback-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS texture-churn-4k-v1-single-live-image-persistent-staging-upload-readback-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"
printf 'PASS: deterministic 4K Vulkan texture churn artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\ntexture=4096x4096 RGBA8\ntexture_bytes=67108864\ninterval_ms=2000\nmax_cycles=180\nlive_images=1\nSTATUS: artifact sealed; runtime not executed.\n' "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
