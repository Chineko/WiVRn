#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_texture_churn_4k_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-texture-churn-4k-v1"
BASE_META="$ROOT/vulkan-texture-churn-4k-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-texture-churn-4k-v1-seal.txt"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-v1"
META="$ROOT/vulkan-texture-churn-4k-live4-v1-metadata.txt"

BASE_SOURCE_SHA="3161d5772aef9cb6c175866aded7f35389d5733fef8c777205664107b6059f18"
BASE_BINARY_SHA="1cd8ef4584968b20d7bff4ee72c7129c095d9977a417246ab2f83c5ce6ff38e2"
BASE_METADATA_SHA="a9514dc5b830e6652b2efe92b003c65b39f5770a437c39b37d85e530fa2b11b1"
BASE_BUILD_TOOLING="397dcd68306978e39bd8960977633ef9776f873a"
WIDTH=4096
HEIGHT=4096
INTERVAL_MS=2000
MAX_CYCLES=180
LIVE_IMAGES=4
TEXTURE_BYTES=$((WIDTH * HEIGHT * 4))
LIVE_BYTES=$((TEXTURE_BYTES * LIVE_IMAGES))

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++ file ldd; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen single-live churn artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen single-live churn binary not executable"
[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$BASE_SOURCE_SHA" ]] || fail "single-live source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$BASE_BINARY_SHA" ]] || fail "single-live binary hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_METADATA_SHA" ]] || fail "single-live metadata hash mismatch"
grep -Fqx "source_sha256=$BASE_SOURCE_SHA" "$BASE_SEAL" || fail "single-live seal source mismatch"
grep -Fqx "binary_sha256=$BASE_BINARY_SHA" "$BASE_SEAL" || fail "single-live seal binary mismatch"
grep -Fqx "metadata_sha256=$BASE_METADATA_SHA" "$BASE_SEAL" || fail "single-live seal metadata mismatch"
grep -Fqx "build_tooling_commit=$BASE_BUILD_TOOLING" "$BASE_SEAL" || fail "single-live seal tooling mismatch"
grep -Fqx 'live_images=1' "$BASE_SEAL" || fail "single-live seal live_images mismatch"
grep -Fqx 'artifact_seal=PASS texture-churn-4k-v1-single-live-image-persistent-staging-upload-readback-source-binary-metadata-deps' "$BASE_SEAL" || fail "single-live seal marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def one(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

one('constexpr uint32_t MAX_CYCLES=180;',
    'constexpr uint32_t MAX_CYCLES=180;\n    constexpr uint32_t LIVE_SLOTS=4;',
    'live slot constant')

one('uint32_t cycles=0,allocs=0,uploads=0,frees=0,verify_failures=0,errors=0;const auto start=std::chrono::steady_clock::now();',
    'uint32_t cycles=0,allocs=0,uploads=0,frees=0,verify_failures=0,errors=0;\n    VkImage live_images[LIVE_SLOTS]{}; VkDeviceMemory live_memory[LIVE_SLOTS]{};\n    const auto start=std::chrono::steady_clock::now();',
    'live arrays')

one('for(uint32_t cycle=0;cycle<MAX_CYCLES&&!g_stop;++cycle){\n        auto t0=std::chrono::steady_clock::now();uint32_t seed=0x9e3779b9u^(cycle*0x85ebca6bu);auto *words=static_cast<uint32_t*>(mapped);const size_t count=size_t(BYTES/4u);',
    'for(uint32_t cycle=0;cycle<MAX_CYCLES&&!g_stop;++cycle){\n        auto t0=std::chrono::steady_clock::now();\n        const uint32_t slot=cycle%LIVE_SLOTS;\n        if(live_images[slot]!=VK_NULL_HANDLE){ vkDestroyImage(dev,live_images[slot],nullptr); vkFreeMemory(dev,live_memory[slot],nullptr); live_images[slot]=VK_NULL_HANDLE; live_memory[slot]=VK_NULL_HANDLE; frees++; }\n        uint32_t seed=0x9e3779b9u^(cycle*0x85ebca6bu);auto *words=static_cast<uint32_t*>(mapped);const size_t count=size_t(BYTES/4u);',
    'slot retirement')

one('uploads++;bool verify=(*read_ptr==expected);if(!verify) verify_failures++;vkDestroyImage(dev,image,nullptr);vkFreeMemory(dev,mem,nullptr);frees++;cycles++;',
    'uploads++;bool verify=(*read_ptr==expected);if(!verify) verify_failures++;live_images[slot]=image;live_memory[slot]=mem;cycles++;',
    'retain live image')

one('std::printf("HELIX_CHURN_CYCLE cycle=%u bytes=%llu alloc_bytes=%llu verify=%s elapsed_ms=%lld\\n",cycles,(unsigned long long)BYTES,(unsigned long long)ir.size,verify?"PASS":"FAIL",(long long)ms);',
    'std::printf("HELIX_CHURN_CYCLE cycle=%u bytes=%llu alloc_bytes=%llu live=%u verify=%s elapsed_ms=%lld\\n",cycles,(unsigned long long)BYTES,(unsigned long long)ir.size,(cycles<LIVE_SLOTS?cycles:LIVE_SLOTS),verify?"PASS":"FAIL",(long long)ms);',
    'cycle live count')

one('vkDeviceWaitIdle(dev);vkDestroyFence(dev,fence,nullptr);',
    'vkDeviceWaitIdle(dev);for(uint32_t i=0;i<LIVE_SLOTS;i++){ if(live_images[i]!=VK_NULL_HANDLE){ vkDestroyImage(dev,live_images[i],nullptr); vkFreeMemory(dev,live_memory[i],nullptr); live_images[i]=VK_NULL_HANDLE; live_memory[i]=VK_NULL_HANDLE; frees++; }}vkDestroyFence(dev,fence,nullptr);',
    'final live cleanup')

one('std::printf("HELIX_CHURN_READY gpu_vendor=0x%04x gpu_device=0x%04x width=%u height=%u bytes=%llu interval_ms=%u max_cycles=%u\\n",props.vendorID,props.deviceID,W,H,(unsigned long long)BYTES,INTERVAL_MS,MAX_CYCLES);',
    'std::printf("HELIX_CHURN_READY gpu_vendor=0x%04x gpu_device=0x%04x width=%u height=%u bytes=%llu interval_ms=%u max_cycles=%u live_slots=%u live_bytes=%llu\\n",props.vendorID,props.deviceID,W,H,(unsigned long long)BYTES,INTERVAL_MS,MAX_CYCLES,LIVE_SLOTS,(unsigned long long)(BYTES*LIVE_SLOTS));',
    'ready live markers')

p.write_text(s)
PY

# Audit the intended single-axis delta.
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "4 live slots missing"
grep -Fq 'VkImage live_images[LIVE_SLOTS]{}; VkDeviceMemory live_memory[LIVE_SLOTS]{};' "$SRC" || fail "live image ring missing"
grep -Fq 'const uint32_t slot=cycle%LIVE_SLOTS;' "$SRC" || fail "slot selector missing"
grep -Fq 'live_images[slot]=image;live_memory[slot]=mem;cycles++;' "$SRC" || fail "retained image assignment missing"
grep -Fq 'live_slots=%u live_bytes=%llu' "$SRC" || fail "ready live markers missing"
grep -Fq 'live=%u verify=%s' "$SRC" || fail "cycle live marker missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload copy missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback verify missing"
grep -Fq 'constexpr uint32_t INTERVAL_MS=2000;' "$SRC" || fail "2s cadence changed"
grep -Fq 'constexpr uint32_t MAX_CYCLES=180;' "$SRC" || fail "cycle cap changed"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "unexpected buffer creation count"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "unexpected image creation call count"
! grep -Fq 'vkDestroyImage(dev,image,nullptr);vkFreeMemory(dev,mem,nullptr);frees++;cycles++;' "$SRC" || fail "stale immediate free remains"

VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing"

echo '[1/2] Compiling deterministic four-live 4K Vulkan texture churn companion'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "four-live churn compile failed"
file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "four-live binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

echo '[2/2] Recording four-live churn metadata'
SRC_SHA="$(sha256sum "$SRC"|awk '{print $1}')"; BIN_SHA="$(sha256sum "$BIN"|awk '{print $1}')"; for h in "$SRC_SHA" "$BIN_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
cat >"$META" <<EOF
base_single_source_sha256=$BASE_SOURCE_SHA
base_single_binary_sha256=$BASE_BINARY_SHA
base_single_metadata_sha256=$BASE_METADATA_SHA
base_single_build_tooling=$BASE_BUILD_TOOLING
texture_width=$WIDTH
texture_height=$HEIGHT
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=$TEXTURE_BYTES
interval_ms=$INTERVAL_MS
max_cycles=$MAX_CYCLES
live_images=$LIVE_IMAGES
live_texture_bytes=$LIVE_BYTES
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
churn_contract=PASS deterministic-four-live-4k-rgba-device-memory-lifecycle-upload-readback-v1
source_delta=PASS frozen-single-live-only-retention-ring-1-to-4
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META"|awk '{print $1}')"; [[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"
printf '\nPASS: deterministic four-live 4K Vulkan texture churn companion built.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\ntexture=4096x4096 RGBA8\ntexture_bytes=%s\ninterval_ms=%s\nmax_cycles=%s\nlive_images=%s\nlive_texture_bytes=%s\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$TEXTURE_BYTES" "$INTERVAL_MS" "$MAX_CYCLES" "$LIVE_IMAGES" "$LIVE_BYTES"
