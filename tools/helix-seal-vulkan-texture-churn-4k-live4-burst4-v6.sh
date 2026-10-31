#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="2719db94169ca714cb4d2de1356843f025956ef7"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_burst4_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-burst4-v1"
META="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-metadata.txt"
SEAL="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing burst4 artifact: $f"; done
[[ -x "$BIN" ]] || fail "burst4 binary not executable"

for kv in \
  'texture_width=4096' \
  'texture_height=4096' \
  'texture_format=VK_FORMAT_R8G8B8A8_UNORM' \
  'texture_bytes=67108864' \
  'live_images=4' \
  'live_texture_bytes=268435456' \
  'burst_size=4' \
  'burst_dwell_ms=8000' \
  'nominal_average_interval_ms=2000' \
  'max_cycles=180' \
  'staging_lifecycle=persistent' \
  'readback_verification=one-pixel-every-cycle' \
  'churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-burst4-dwell8s-destroy-free' \
  'churn_contract=PASS deterministic-live4-burst4-4k-rgba-device-memory-lifecycle-upload-readback-v1' \
  'source_delta=PASS frozen-live4-only-temporal-upload-shape-smooth2s-to-burst4-dwell8s' \
  'runtime_status=NOT_RUN'; do
  grep -Fqx "$kv" "$META" || fail "metadata mismatch: $kv"
done

# Direct generated-source audit.
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "source live slots mismatch"
grep -Fq 'constexpr uint32_t BURST_SIZE=4;' "$SRC" || fail "source burst size mismatch"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' "$SRC" || fail "source burst dwell mismatch"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "source burst dwell transform mismatch"
! grep -Fq 'auto next=' "$SRC" || fail "dead next variable remains"
! grep -Fq 'const auto start=' "$SRC" || fail "dead start variable remains"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload path missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback path missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "buffer creation count changed"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "image creation call count changed"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"
printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"
! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

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
grep -Fqx 'artifact_seal=PASS texture-churn-4k-live4-burst4-v1-ring4-256MiB-burst4-dwell8s-persistent-staging-upload-readback-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: standalone deterministic live4 burst4 4K Vulkan churn artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nburst_size=4\nburst_dwell_ms=8000\nlive_images=4\nlive_texture_bytes=268435456\nmax_cycles=180\nSTATUS: artifact sealed; runtime not executed.\n' "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
