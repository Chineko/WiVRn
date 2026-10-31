#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE="$ROOT/helix-run-encoded-network-sustained-5min-v1.sh"
OUT="$ROOT/helix-run-encoded-network-sustained-5min-texture-bank32-20f-v1.sh"
BANK_SRC="$ROOT/helix_vulkan_stimulus_sustained_5min_texture_bank32_v1.cpp"
BANK_BIN="$ROOT/helix-vulkan-stimulus-sustained-5min-texture-bank32-v1"
BANK_META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
BANK_SEAL="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-seal.txt"
BASE_RUNNER_SHA256="42590ad156339300796862317b0c0f81a97f592a2ac88c7900586aa89bc99892"
BANK_BUILD_TOOLING="ec7661c38898e0c1faab5374e2057014866b4ba8"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk bash grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE" "$BANK_SRC" "$BANK_BIN" "$BANK_META" "$BANK_SEAL"; do [[ -s "$f" ]] || fail "missing artifact: $f"; done
[[ -x "$BASE" && -x "$BANK_BIN" ]] || fail "required executable missing"
[[ "$(sha256sum "$BASE" | awk '{print $1}')" == "$BASE_RUNNER_SHA256" ]] || fail "frozen 5-minute runner hash mismatch"

read_meta(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$BANK_META" | tail -1; }
SRC_SHA="$(read_meta source_sha256)"
BIN_SHA="$(read_meta binary_sha256)"
for value in "$SRC_SHA" "$BIN_SHA"; do [[ "$value" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash format: $value"; done
META_SHA="$(sha256sum "$BANK_META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata file hash format"
[[ "$(sha256sum "$BANK_SRC" | awk '{print $1}')" == "$SRC_SHA" ]] || fail "bank32 source hash mismatch"
[[ "$(sha256sum "$BANK_BIN" | awk '{print $1}')" == "$BIN_SHA" ]] || fail "bank32 binary hash mismatch"
grep -Fqx "build_tooling_commit=$BANK_BUILD_TOOLING" "$BANK_SEAL" || fail "bank32 seal tooling binding mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$BANK_SEAL" || fail "bank32 seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$BANK_SEAL" || fail "bank32 seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$BANK_SEAL" || fail "bank32 seal metadata hash mismatch"
grep -Fqx 'render_deadline_seconds=360' "$BANK_SEAL" || fail "bank32 seal deadline mismatch"
grep -Fqx 'texture_bank_patterns=32' "$BANK_SEAL" || fail "bank32 seal pattern count mismatch"
grep -Fqx 'texture_bank_multiplier=4' "$BANK_SEAL" || fail "bank32 seal multiplier mismatch"
grep -Fqx 'artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps' "$BANK_SEAL" || fail "bank32 seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy-spike-bank32-sustained360' "$BANK_META" || fail "bank32 contract marker missing"
grep -Fqx 'source_delta=PASS frozen-entropy-only-preallocated-bank-8-to-32' "$BANK_META" || fail "bank32 source delta marker missing"

cp "$BASE" "$OUT"
python3 - "$OUT" "$SRC_SHA" "$BIN_SHA" "$META_SHA" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); src_sha,bin_sha,meta_sha=sys.argv[2:]

def one(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

one('CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-30}"','CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-449}"','torture cycles')
one('SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300}"','SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20}"','torture spacing')
one('helix_vulkan_stimulus_sustained_v1.cpp','helix_vulkan_stimulus_sustained_5min_texture_bank32_v1.cpp','bank32 source path')
one('vulkan-stimulus-sustained-v1-seal.txt','vulkan-stimulus-sustained-5min-texture-bank32-v1-seal.txt','bank32 seal path')
one('vulkan-stimulus-sustained-v1-metadata.txt','vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt','bank32 metadata path')
one('helix-vulkan-stimulus-sustained-v1','helix-vulkan-stimulus-sustained-5min-texture-bank32-v1','bank32 binary path')

patterns=[
 (r'VULKAN_SOURCE_SHA256="[0-9a-f]{64}"',f'VULKAN_SOURCE_SHA256="{src_sha}"','source hash binding'),
 (r'VULKAN_BINARY_SHA256="[0-9a-f]{64}"',f'VULKAN_BINARY_SHA256="{bin_sha}"','binary hash binding'),
 (r'VULKAN_METADATA_SHA256="[0-9a-f]{64}"',f'VULKAN_METADATA_SHA256="{meta_sha}"','metadata hash binding'),
]
for pattern,repl,label in patterns:
    s2,n=re.subn(pattern,repl,s,count=1)
    if n != 1: raise SystemExit(f'FAIL: {label} replacement count={n}')
    s=s2

one('build_tooling_commit=e5c77bc488ebc4eb3d8c03e66511cd1c60daa271','build_tooling_commit=ec7661c38898e0c1faab5374e2057014866b4ba8','bank32 build tooling')
one('artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps','artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps','bank32 seal marker')
one('stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360','stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy-spike-bank32-sustained360','bank32 contract')
one('source_delta=PASS frozen-v5-only-render-deadline-20-to-360','source_delta=PASS frozen-entropy-only-preallocated-bank-8-to-32','bank32 source delta')
one('SUSTAINED_AUDIT_B=PASS frame-keyed-90-event-reducer-and-bounded-frame-budget','SUSTAINED_AUDIT_B=PASS frame-keyed-1347-event-reducer-and-bounded-frame-budget','audit B label')
one('helix-encoded-sustained-5min-runtime-','helix-encoded-sustained-5min-texture-bank32-20f-runtime-','evidence directory')
one('ENCODED_NVENC_SUSTAINED_5MIN_PASS','ENCODED_NVENC_SUSTAINED_5MIN_TEXTURE_BANK32_20F_PASS','final verdict')

required=[
 'HELIX_SUSTAINED_FRAMES:-27000',
 'HELIX_ENCODED_TORTURE_CYCLES:-449',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20',
 'helix_vulkan_stimulus_sustained_5min_texture_bank32_v1.cpp',
 'helix-vulkan-stimulus-sustained-5min-texture-bank32-v1',
 'vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt',
 'vulkan-stimulus-sustained-5min-texture-bank32-v1-seal.txt',
 src_sha,bin_sha,meta_sha,
 'build_tooling_commit=ec7661c38898e0c1faab5374e2057014866b4ba8',
 'artifact_seal=PASS sustained-5min-texture-bank32-v1-frozen-entropy-preallocated-bank4x-source-binary-metadata-deps',
 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy-spike-bank32-sustained360',
 'source_delta=PASS frozen-entropy-only-preallocated-bank-8-to-32',
 'frame-keyed-1347-event-reducer-and-bounded-frame-budget',
 'timeout --signal=TERM --kill-after=5s 420s',
 'ENCODED_NVENC_SUSTAINED_5MIN_TEXTURE_BANK32_20F_PASS',
]
for x in required:
    if x not in s: raise SystemExit('FAIL: generated bank32 20f runner requirement missing: '+x)
for x in [
 'HELIX_ENCODED_TORTURE_CYCLES:-30',
 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300',
 'helix_vulkan_stimulus_sustained_v1.cpp',
 'helix-vulkan-stimulus-sustained-v1',
 'vulkan-stimulus-sustained-v1-seal.txt',
 'vulkan-stimulus-sustained-v1-metadata.txt',
 'build_tooling_commit=e5c77bc488ebc4eb3d8c03e66511cd1c60daa271',
 'frame-keyed-90-event-reducer-and-bounded-frame-budget',
 'ENCODED_NVENC_SUSTAINED_5MIN_PASS',
]:
    if x in s: raise SystemExit('FAIL: stale baseline marker remains: '+x)
p.write_text(s)
PY

chmod +x "$OUT"
bash -n "$OUT" || fail "generated bank32 20f runner syntax invalid"
RUNNER_SHA="$(sha256sum "$OUT" | awk '{print $1}')"
[[ "$RUNNER_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid runner hash format"
printf 'PASS: bank32 20-frame 5-minute torture runner materialized.\nbase_runner_sha256=%s\nbank32_source_sha256=%s\nbank32_binary_sha256=%s\nbank32_metadata_sha256=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=449\nspacing=20\nexpected=1347\ndriver_timeout_seconds=420\n' \
  "$BASE_RUNNER_SHA256" "$SRC_SHA" "$BIN_SHA" "$META_SHA" "$OUT" "$RUNNER_SHA"
