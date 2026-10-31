#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_v1.cpp"
BASE_BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-v1"
BASE_META="$ROOT/vulkan-texture-churn-4k-live4-v1-metadata.txt"
BASE_SEAL="$ROOT/vulkan-texture-churn-4k-live4-v1-seal.txt"
BANK_META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_burst4_v1.cpp"
BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-burst4-v1"
META="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-metadata.txt"

EXPECTED_BASE_TOOLING="90842e13d58bcec6c788f4eb0bb345a632833ed1"
EXPECTED_BASE_SEAL="artifact_seal=PASS texture-churn-4k-live4-v1-ring4-256MiB-persistent-staging-upload-readback-source-binary-metadata-deps"
BANK_METADATA_SHA="c8de14bec0d1e46fc1dd059ff6b80f033e8f69dae9db880d58cbe69e87286ccf"
BURST_SIZE=4
BURST_DWELL_MS=8000
LIVE_IMAGES=4
TEXTURE_BYTES=67108864
LIVE_BYTES=268435456
MAX_CYCLES=180

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk c++ file grep ldd python3 sha256sum timeout; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL" "$BANK_META"; do [[ -s "$f" ]] || fail "missing frozen artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "base live4 binary not executable"

meta_get(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1; }
BASE_SRC_SHA="$(meta_get source_sha256)"
BASE_BIN_SHA="$(meta_get binary_sha256)"
BASE_META_SHA="$(sha256sum "$BASE_META" | awk '{print $1}')"
for h in "$BASE_SRC_SHA" "$BASE_BIN_SHA" "$BASE_META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid base hash: $h"; done
[[ "$(sha256sum "$BASE_SRC" | awk '{print $1}')" == "$BASE_SRC_SHA" ]] || fail "base source hash mismatch"
[[ "$(sha256sum "$BASE_BIN" | awk '{print $1}')" == "$BASE_BIN_SHA" ]] || fail "base binary hash mismatch"
grep -Fqx "source_sha256=$BASE_SRC_SHA" "$BASE_SEAL" || fail "base seal source mismatch"
grep -Fqx "binary_sha256=$BASE_BIN_SHA" "$BASE_SEAL" || fail "base seal binary mismatch"
grep -Fqx "metadata_sha256=$BASE_META_SHA" "$BASE_SEAL" || fail "base seal metadata mismatch"
grep -Fqx "build_tooling_commit=$EXPECTED_BASE_TOOLING" "$BASE_SEAL" || fail "base tooling mismatch"
grep -Fqx "$EXPECTED_BASE_SEAL" "$BASE_SEAL" || fail "base seal marker mismatch"
grep -Fqx 'live_images=4' "$BASE_META" || fail "base live image count mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$BASE_META" || fail "base live bytes mismatch"
grep -Fqx 'interval_ms=2000' "$BASE_META" || fail "base cadence mismatch"
grep -Fqx 'max_cycles=180' "$BASE_META" || fail "base cycle cap mismatch"
[[ "$(sha256sum "$BANK_META" | awk '{print $1}')" == "$BANK_METADATA_SHA" ]] || fail "bank32 metadata hash mismatch"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BANK_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing from frozen bank32 metadata"

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

one('constexpr uint32_t MAX_CYCLES=180;',
    'constexpr uint32_t MAX_CYCLES=180;\n    constexpr uint32_t BURST_SIZE=4;\n    constexpr uint32_t BURST_DWELL_MS=8000;',
    'MAX_CYCLES anchor')
one('const auto start=std::chrono::steady_clock::now();','', 'start anchor')
one('auto next=start+std::chrono::milliseconds(uint64_t(cycle+1)*INTERVAL_MS);std::this_thread::sleep_until(next);',
    'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));',
    'verified old timing line')

if 'auto next=' in s: raise SystemExit('FAIL: stale next declaration remains')
if 'const auto start=' in s: raise SystemExit('FAIL: stale start declaration remains')
if s.count('std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS))') != 1: raise SystemExit('FAIL: burst dwell call count mismatch')
if s.count('constexpr uint32_t LIVE_SLOTS=4;') != 1: raise SystemExit('FAIL: live slot invariant changed')
p.write_text(s)
PY

grep -Fq 'constexpr uint32_t BURST_SIZE=4;' "$SRC" || fail "burst size constant missing"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' "$SRC" || fail "burst dwell constant missing"
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "live slots changed"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "burst dwell transform missing"
! grep -Fq 'auto next=' "$SRC" || fail "dead next variable remains"
! grep -Fq 'const auto start=' "$SRC" || fail "dead start variable remains"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "upload path missing"
grep -Fq 'vkCmdCopyImageToBuffer' "$SRC" || fail "readback path missing"
[[ "$(grep -c 'vkCreateBuffer(dev' "$SRC")" -eq 2 ]] || fail "buffer lifecycle changed"
[[ "$(grep -c 'vkCreateImage(dev' "$SRC")" -eq 1 ]] || fail "image creation call count changed"

echo '[1/2] Compiling deterministic live4 burst4 4K Vulkan churn companion'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "burst4 compile failed"
file "$BIN" | grep -Eq 'ELF 64-bit.*x86-64' || fail "burst4 binary is not x86-64 ELF"
LD="$(ldd "$BIN")"; printf '%s\n' "$LD" | grep -Fq 'libvulkan.so.1' || fail "Vulkan loader dependency missing"; ! printf '%s\n' "$LD" | grep -Fq 'not found' || fail "unresolved dependency"

echo '[2/2] Recording burst4 metadata'
SRC_SHA="$(sha256sum "$SRC"|awk '{print $1}')"; BIN_SHA="$(sha256sum "$BIN"|awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid generated hash: $h"; done
cat >"$META" <<EOF
base_live4_source_sha256=$BASE_SRC_SHA
base_live4_binary_sha256=$BASE_BIN_SHA
base_live4_metadata_sha256=$BASE_META_SHA
base_live4_build_tooling=$EXPECTED_BASE_TOOLING
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
churn_lifecycle=create-image-allocate-bind-upload-transition-readback-retain-ring4-burst4-dwell8s-destroy-free
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
churn_contract=PASS deterministic-live4-burst4-4k-rgba-device-memory-lifecycle-upload-readback-v1
source_delta=PASS frozen-live4-only-temporal-upload-shape-smooth2s-to-burst4-dwell8s
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META"|awk '{print $1}')"; [[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"
printf '\nPASS: deterministic live4 burst4 artifact built.\nsource_sha256=%s\nbinary_sha256=%s\nmetadata_sha256=%s\nburst_size=4\nburst_dwell_ms=8000\nlive_images=4\nlive_texture_bytes=268435456\nmax_cycles=180\nSTATUS: built only; runtime not executed.\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
