#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE="$ROOT/helix-run-encoded-network-sustained-5min-v1.sh"
OUT="$ROOT/helix-run-encoded-network-sustained-15min-v1.sh"
SRC="$ROOT/helix_vulkan_stimulus_sustained_15min_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-15min-v1"
META="$ROOT/vulkan-stimulus-sustained-15min-v1-metadata.txt"
SEAL="$ROOT/vulkan-stimulus-sustained-15min-v1-seal.txt"
SRC_SHA=bc60e975b016363d486daeff5f6146f27dff00206c5db5ff90fbe55a6792fc23
BIN_SHA=60738207fb04b5a8c47bbcda24fc56a853110d724e2b1e9f91d151c3d5bc41bb
META_SHA=81d6251a0cfafaf22832585b6c873a5aac96fb4f7d24ee63071b7029038a89e3
fail(){ echo "FAIL: $*" >&2; exit 2; }
for f in "$BASE" "$SRC" "$BIN" "$META" "$SEAL"; do [[ -s "$f" ]] || fail "missing $f"; done
[[ "$(sha256sum "$SRC"|awk '{print $1}')" == "$SRC_SHA" ]] || fail "source hash"
[[ "$(sha256sum "$BIN"|awk '{print $1}')" == "$BIN_SHA" ]] || fail "binary hash"
[[ "$(sha256sum "$META"|awk '{print $1}')" == "$META_SHA" ]] || fail "metadata hash"
grep -Fqx "source_sha256=$SRC_SHA" "$SEAL" || fail "seal source"
grep -Fqx "binary_sha256=$BIN_SHA" "$SEAL" || fail "seal binary"
grep -Fqx "metadata_sha256=$META_SHA" "$SEAL" || fail "seal metadata"
grep -Fqx 'build_tooling_commit=0b4ba80f4ad912aba7000c581ac5b4f8e621956d' "$SEAL" || fail "seal build tooling"
grep -Fqx 'render_deadline_seconds=1080' "$SEAL" || fail "seal deadline"
cp "$BASE" "$OUT"
python3 - "$OUT" "$SRC_SHA" "$BIN_SHA" "$META_SHA" <<'PY'
from pathlib import Path
import re,sys
p=Path(sys.argv[1]); s=p.read_text(); a,b,c=sys.argv[2:]
def one(x,y):
    global s
    n=s.count(x)
    if n!=1: raise SystemExit(f'FAIL anchor {x!r} count={n}')
    s=s.replace(x,y,1)
def exact(x,y,n):
    global s
    count=s.count(x)
    if count!=n: raise SystemExit(f'FAIL anchor {x!r} count={count} expected={n}')
    s=s.replace(x,y)
one('HELIX_SUSTAINED_FRAMES:-27000','HELIX_SUSTAINED_FRAMES:-81000')
one('HELIX_ENCODED_TORTURE_CYCLES:-30','HELIX_ENCODED_TORTURE_CYCLES:-90')
one('helix_vulkan_stimulus_sustained_v1.cpp','helix_vulkan_stimulus_sustained_15min_v1.cpp')
one('vulkan-stimulus-sustained-v1-seal.txt','vulkan-stimulus-sustained-15min-v1-seal.txt')
one('vulkan-stimulus-sustained-v1-metadata.txt','vulkan-stimulus-sustained-15min-v1-metadata.txt')
one('helix-vulkan-stimulus-sustained-v1','helix-vulkan-stimulus-sustained-15min-v1')
s=re.sub(r'VULKAN_SOURCE_SHA256="[0-9a-f]{64}"',f'VULKAN_SOURCE_SHA256="{a}"',s,count=1)
s=re.sub(r'VULKAN_BINARY_SHA256="[0-9a-f]{64}"',f'VULKAN_BINARY_SHA256="{b}"',s,count=1)
s=re.sub(r'VULKAN_METADATA_SHA256="[0-9a-f]{64}"',f'VULKAN_METADATA_SHA256="{c}"',s,count=1)
one('build_tooling_commit=e5c77bc488ebc4eb3d8c03e66511cd1c60daa271','build_tooling_commit=0b4ba80f4ad912aba7000c581ac5b4f8e621956d')
exact('render_deadline_seconds=360','render_deadline_seconds=1080',2)
one('sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps','sustained-15min-v1-frozen-5min-single-deadline-delta-source-binary-metadata-deps')
one('graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360','graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained1080')
one('frozen-v5-only-render-deadline-20-to-360','frozen-5min-only-render-deadline-360-to-1080')
one('frame-keyed-90-event-reducer-and-bounded-frame-budget','frame-keyed-270-event-reducer-and-bounded-frame-budget')
one('helix-encoded-sustained-5min-runtime-','helix-encoded-sustained-15min-runtime-')
one('timeout --signal=TERM --kill-after=5s 420s','timeout --signal=TERM --kill-after=5s 1140s')
one('ENCODED_NVENC_SUSTAINED_5MIN_PASS','ENCODED_NVENC_SUSTAINED_15MIN_PASS')
p.write_text(s)
PY
chmod +x "$OUT"
bash -n "$OUT" || fail "runner syntax"
grep -Fqx 'grep -Fqx '\''build_tooling_commit=0b4ba80f4ad912aba7000c581ac5b4f8e621956d'\'' "$SEAL" || fail "sustained Vulkan build tooling mismatch"' "$OUT" || fail "runner 15-minute build tooling binding missing"
! grep -Fq 'build_tooling_commit=e5c77bc488ebc4eb3d8c03e66511cd1c60daa271' "$OUT" || fail "stale 5-minute build tooling binding remains"
printf 'PASS: 15-minute runner materialized\nrunner=%s\nframes=81000\ncycles=90\nspacing=300\nexpected=270\n' "$OUT"
