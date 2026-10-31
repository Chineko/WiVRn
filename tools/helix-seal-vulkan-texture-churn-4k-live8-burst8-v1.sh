#!/usr/bin/env bash
set -euo pipefail

BUILD_TOOLING="35bd3a9aed82a1b63ab1016aefdb0bcc39e07f0a"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live8_burst8_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live8-burst8-v1"
META="$ROOT/vulkan-texture-churn-4k-live8-burst8-v1-metadata.txt"
SEAL="$ROOT/vulkan-texture-churn-4k-live8-burst8-v1-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk file grep ldd sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "missing live8 burst8 artifact: $f"; done
[[ -x "$BIN" ]] || fail "binary not executable"

for kv in \
  'texture_width=4096' \
  'texture_height=4096' \
  'texture_format=VK_FORMAT_R8G8B8A8_UNORM' \
  'texture_bytes=67108864' \
  'live_images=8' \
  'live_texture_bytes=536870912' \
  'burst_size=8' \
  'burst_dwell_ms=16000' \
  'nominal_average_interval_ms=2000' \
  'max_cycles=180' \
  'staging_lifecycle=persistent' \
  'readback_verification=one-pixel-every-cycle' \
  'churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring8-burst8-dwell16s-destroy-free' \
  'churn_contract=PASS deterministic-live8-burst8-4k-rgba-device-memory-lifecycle-upload-readback-v1' \
  'source_delta=PASS frozen-burst4-only-shotgun-magnitude-live4-burst4-to-live8-burst8-average2s' \
  'runtime_status=NOT_RUN'; do grep -Fqx "$kv" "$META" || fail "metadata mismatch: $kv"; done

grep -Fq 'constexpr uint32_t LIVE_SLOTS=8;' "$SRC" || fail "source live8 mismatch"
grep -Fq 'constexpr uint32_t BURST_SIZE=8;' "$SRC" || fail "source burst8 mismatch"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=16000;' "$SRC" || fail "source dwell mismatch"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "source burst dwell logic mismatch"
! grep -Fq 'auto next=' "$SRC" || fail "stale absolute timing variable"
! grep -Fq 'const auto start=' "$SRC" || fail "stale timing origin"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "buffer creation count changed"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "image creation count changed"

file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

meta_get(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"; BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"; META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
[[ "$(meta_get source_sha256)" == "$SRC_SHA" ]] || fail "metadata source hash mismatch"
[[ "$(meta_get binary_sha256)" == "$BIN_SHA" ]] || fail "metadata binary hash mismatch"

cat >"$SEAL" <<EOF
build_tooling_commit=$BUILD_TOOLING
texture_width=4096
texture_height=4096
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=67108864
live_images=8
live_texture_bytes=536870912
burst_size=8
burst_dwell_ms=16000
nominal_average_interval_ms=2000
max_cycles=180
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring8-burst8-dwell16s-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS texture-churn-4k-live8-burst8-v1-ring8-512MiB-burst8-dwell16s-persistent-staging-upload-readback-source-binary-metadata-deps
runtime_status=NOT_RUN
EOF

grep -Fqx "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "seal tooling mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata mismatch"
grep -Fqx 'artifact_seal=PASS texture-churn-4k-live8-burst8-v1-ring8-512MiB-burst8-dwell16s-persistent-staging-upload-readback-source-binary-metadata-deps' "$SEAL" || fail "seal marker missing"

printf 'PASS: deterministic live8 burst8 artifact sealed.\nbuild_tooling_commit=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nseal=%s\nburst_size=8\nburst_dwell_ms=16000\nlive_images=8\nlive_texture_bytes=536870912\nmax_cycles=180\nSTATUS: artifact sealed; runtime not executed.\n' "$BUILD_TOOLING" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$SEAL"
