#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="dbfea104b250d9271839d0912b6b4a50a6170dcd"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_burst4_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-burst4-v1"
META="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-metadata.txt"
SEAL="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing burst4 artifact: $f"; done
[[ -x "$BIN" ]] || fail "burst4 binary not executable"

grep -Fqx 'texture_width=4096' "$META" || fail "width mismatch"
grep -Fqx 'texture_height=4096' "$META" || fail "height mismatch"
grep -Fqx 'texture_format=VK_FORMAT_R8G8B8A8_UNORM' "$META" || fail "format mismatch"
grep -Fqx 'texture_bytes=67108864' "$META" || fail "texture bytes mismatch"
grep -Fqx 'live_images=4' "$META" || fail "live image count mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$META" || fail "live bytes mismatch"
grep -Fqx 'burst_size=4' "$META" || fail "burst size mismatch"
grep -Fqx 'burst_dwell_ms=8000' "$META" || fail "burst dwell mismatch"
grep -Fqx 'nominal_average_interval_ms=2000' "$META" || fail "nominal average cadence mismatch"
grep -Fqx 'max_cycles=180' "$META" || fail "cycle cap mismatch"
grep -Fqx 'staging_lifecycle=persistent' "$META" || fail "staging lifecycle mismatch"
grep -Fqx 'readback_verification=one-pixel-every-cycle' "$META" || fail "readback verification mismatch"
grep -Fqx 'churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-burst4-dwell8s-destroy-free' "$META" || fail "lifecycle mismatch"
grep -Fqx 'churn_contract=PASS deterministic-live4-burst4-4k-rgba-device-memory-lifecycle-upload-readback-v1' "$META" || fail "contract mismatch"
grep -Fqx 'source_delta=PASS frozen-live4-only-temporal-upload-shape-smooth2s-to-burst4-dwell8s' "$META" || fail "source delta mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime status mismatch"

grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "source live slots mismatch"
grep -Fq 'constexpr uint32_t BURST_SIZE=4;' "$SRC" || fail "source burst size mismatch"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' "$SRC" || fail "source dwell mismatch"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "source burst sleep mismatch"
[[ "$(grep -c 'std::this_thread::sleep_' "$SRC")" -eq 1 ]] || fail "unexpected sleep call count"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload path missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback path missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "buffer creation count changed"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "image creation call count changed"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

meta_get(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
[[ "$(meta_get source_sha256)" == "$SRC_SHA" ]] || fail "metadata source hash mismatch"
[[ "$(meta_get binary_sha256)" == "$BIN_SHA" ]] || fail "metadata binary hash mismatch"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
texture_width=4096
texture_height=4096
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=67108864
live_images=4
live_texture_bytes=268435456
burst_size=4
burst_dwell_ms=8000
nominal_average_interval_ms=2000
max_cycles=180
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-burst4-dwell8s-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS texture-churn-4k-live4-burst4-v1-ring4-256MiB-burst4-dwell8s-persistent-staging-upload-readback-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata mismatch"
grep -Fqx 'live_images=4' "$SEAL" || fail "seal live image mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$SEAL" || fail "seal live bytes mismatch"
grep -Fqx 'burst_size=4' "$SEAL" || fail "seal burst size mismatch"
grep -Fqx 'burst_dwell_ms=8000' "$SEAL" || fail "seal burst dwell mismatch"
grep -Fqx 'artifact_seal=PASS texture-churn-4k-live4-burst4-v1-ring4-256MiB-burst4-dwell8s-persistent-staging-upload-readback-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: deterministic live4 burst4 4K Vulkan churn artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nburst_size=4\nburst_dwell_ms=8000\nlive_images=4\nlive_texture_bytes=268435456\nmax_cycles=180\nSTATUS: artifact sealed; runtime not executed.\n' "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
