#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_burst4_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-burst4-v1"
BASE_META="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-seal.txt"
BANK_META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live8_burst8_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live8-burst8-v1"
META="$ROOT/vulkan-texture-churn-4k-live8-burst8-v1-metadata.txt"

BASE_SOURCE_SHA="29e240b491d562bc1b1feea577b14c326d397a422854708173e6ccc7a8cd184f"
BASE_BINARY_SHA="7256f5b3e744baa397374c8584c660b32a3aadb501180c93b058ae7c1166b807"
BASE_METADATA_SHA="ee0884f3aa2221a4782a73565cc24920d8d9380a3d382e48cd2fc68706ff61e2"
BASE_BUILD_TOOLING="ac0bf36313f10a928a758aed10efadf54ae78810"
BASE_SEAL_MARKER="artifact_seal=PASS texture-churn-4k-live4-burst4-v1-ring4-256MiB-burst4-dwell8s-persistent-staging-upload-readback-source-binary-metadata-deps"
BANK_METADATA_SHA="c8de14bec0d1e46fc1dd059ff6b80f033e8f69dae9db880d58cbe69e87286ccf"
TEXTURE_BYTES=67108864
LIVE_IMAGES=8
LIVE_BYTES=536870912
BURST_SIZE=8
BURST_DWELL_MS=16000
MAX_CYCLES=180

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk c++ cp file grep ldd python3 sha256sum timeout; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL" "$BANK_META"; do [[ -s "$f" ]] || fail "missing frozen artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "base burst4 binary not executable"

[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$BASE_SOURCE_SHA" ]] || fail "base source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$BASE_BINARY_SHA" ]] || fail "base binary hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_METADATA_SHA" ]] || fail "base metadata hash mismatch"
for h in "$BASE_SOURCE_SHA" "$BASE_BINARY_SHA" "$BASE_METADATA_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid frozen hash: $h"; done
grep -Fqx "source_sha256=$BASE_SOURCE_SHA" "$BASE_SEAL" || fail "base seal source mismatch"
grep -Fqx "binary_sha256=$BASE_BINARY_SHA" "$BASE_SEAL" || fail "base seal binary mismatch"
grep -Fqx "metadata_sha256=$BASE_METADATA_SHA" "$BASE_SEAL" || fail "base seal metadata mismatch"
grep -Fqx "build_tooling_commit=$BASE_BUILD_TOOLING" "$BASE_SEAL" || fail "base seal tooling mismatch"
grep -Fqx "$BASE_SEAL_MARKER" "$BASE_SEAL" || fail "base seal marker mismatch"
for kv in \
  'live_images=4' \
  'live_texture_bytes=268435456' \
  'burst_size=4' \
  'burst_dwell_ms=8000' \
  'nominal_average_interval_ms=2000' \
  'max_cycles=180'; do grep -Fqx "$kv" "$BASE_META" || fail "base metadata mismatch: $kv"; done

[[ "$(sha256sum "$BANK_META" | awk '{print $1}')" == "$BANK_METADATA_SHA" ]] || fail "bank32 metadata hash mismatch"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BANK_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing"

cp "$BASE_SRC" "$SRC"
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def one(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} count={n}')
    s=s.replace(old,new,1)

one('constexpr uint32_t LIVE_SLOTS=4;', 'constexpr uint32_t LIVE_SLOTS=8;', 'live slots')
one('constexpr uint32_t BURST_SIZE=4;', 'constexpr uint32_t BURST_SIZE=8;', 'burst size')
one('constexpr uint32_t BURST_DWELL_MS=8000;', 'constexpr uint32_t BURST_DWELL_MS=16000;', 'burst dwell')

if 'constexpr uint32_t LIVE_SLOTS=4;' in s: raise SystemExit('FAIL: stale live4 remains')
if 'constexpr uint32_t BURST_SIZE=4;' in s: raise SystemExit('FAIL: stale burst4 remains')
if 'constexpr uint32_t BURST_DWELL_MS=8000;' in s: raise SystemExit('FAIL: stale dwell8s remains')
if s.count('constexpr uint32_t LIVE_SLOTS=8;') != 1: raise SystemExit('FAIL: live8 count mismatch')
if s.count('constexpr uint32_t BURST_SIZE=8;') != 1: raise SystemExit('FAIL: burst8 count mismatch')
if s.count('constexpr uint32_t BURST_DWELL_MS=16000;') != 1: raise SystemExit('FAIL: dwell16s count mismatch')
p.write_text(s)
PY

grep -Fq 'constexpr uint32_t LIVE_SLOTS=8;' "$SRC" || fail "live8 missing"
grep -Fq 'constexpr uint32_t BURST_SIZE=8;' "$SRC" || fail "burst8 missing"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=16000;' "$SRC" || fail "dwell16s missing"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "burst dwell logic changed"
grep -Fq 'const uint32_t slot=cycle%LIVE_SLOTS;' "$SRC" || fail "slot ring selector changed"
grep -Fq 'live_images[slot]=image;live_memory[slot]=mem;cycles++;' "$SRC" || fail "retention assignment changed"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload path missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback path missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "buffer creation count changed"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "image creation call count changed"
! grep -Fq 'auto next=' "$SRC" || fail "stale absolute timing variable"
! grep -Fq 'const auto start=' "$SRC" || fail "stale timing origin"

echo '[1/2] Compiling deterministic live8 burst8 4K Vulkan churn companion'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "live8 burst8 compile failed"
file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

echo '[2/2] Recording live8 burst8 metadata'
SRC_SHA="$(sha256sum "$SRC"|awk '{print $1}')"; BIN_SHA="$(sha256sum "$BIN"|awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
cat >"$META" <<EOF
base_burst4_source_sha256=$BASE_SOURCE_SHA
base_burst4_binary_sha256=$BASE_BINARY_SHA
base_burst4_metadata_sha256=$BASE_METADATA_SHA
base_burst4_build_tooling=$BASE_BUILD_TOOLING
texture_width=4096
texture_height=4096
texture_format=VK_FORMAT_R8G8B8A8_UNORM
texture_bytes=$TEXTURE_BYTES
live_images=$LIVE_IMAGES
live_texture_bytes=$LIVE_BYTES
burst_size=$BURST_SIZE
burst_dwell_ms=$BURST_DWELL_MS
nominal_average_interval_ms=2000
max_cycles=$MAX_CYCLES
staging_lifecycle=persistent
readback_verification=one-pixel-every-cycle
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring8-burst8-dwell16s-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
churn_contract=PASS deterministic-live8-burst8-4k-rgba-device-memory-lifecycle-upload-readback-v1
source_delta=PASS frozen-burst4-only-shotgun-magnitude-live4-burst4-to-live8-burst8-average2s
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META"|awk '{print $1}')"; [[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"
printf '\nPASS: deterministic live8 burst8 artifact built.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nburst_size=8\nburst_dwell_ms=16000\nlive_images=8\nlive_texture_bytes=536870912\nmax_cycles=180\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
