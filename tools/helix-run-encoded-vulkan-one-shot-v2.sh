#!/usr/bin/env bash
set -euo pipefail

# One-shot v2: patch the known unbounded Vulkan-stimulus header search before
# running it, then launch the already-prepared encoded runtime harness.
build_tooling="9fe49dbcc65534b08a8537aa85a855aa399b6a98"
runtime_tooling="cfa03d67546f25ed5d074d41f035adbf2918bbcd"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "FAIL: run from inside WiVRn checkout" >&2; exit 2; }
cd "$repo_root"

for c in git python3 timeout grep; do command -v "$c" >/dev/null 2>&1 || { echo "FAIL: missing command $c" >&2; exit 2; }; done

build_script="$(mktemp)"
runtime_script="$(mktemp)"
cleanup(){ rm -f "$build_script" "$runtime_script"; }
trap cleanup EXIT INT TERM

git cat-file -e "${build_tooling}^{commit}" 2>/dev/null || git fetch origin "$build_tooling"
git cat-file -e "${runtime_tooling}^{commit}" 2>/dev/null || git fetch origin "$runtime_tooling"
git show "${build_tooling}:tools/helix-build-encoded-vulkan-stimulus.sh" >"$build_script"
git show "${runtime_tooling}:tools/helix-run-encoded-nvenc-torture-vulkan.sh" >"$runtime_script"

python3 - "$build_script" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''WORKTREE="$BUILD_ROOT/worktree"
hdr=""
for root in /usr/include "$WORKTREE/build-everything" "$WORKTREE"; do
  [[ -e "$root" ]] || continue
  hdr="$(find "$root" -type f -path '*/openxr/openxr_platform.h' -print -quit 2>/dev/null || true)"
  [[ -n "$hdr" ]] && break
done
[[ -n "$hdr" ]] || fail "OpenXR platform headers not found"
inc="$(dirname "$(dirname "$hdr")")"
'''
new='''WORKTREE="$BUILD_ROOT/worktree"
echo '[preflight] Resolving OpenXR headers from bounded locations'
hdr=""
if [[ -f /usr/include/openxr/openxr_platform.h ]]; then
  hdr=/usr/include/openxr/openxr_platform.h
elif [[ -d "$WORKTREE/build-everything/_deps" ]]; then
  hdr="$(timeout 5s find "$WORKTREE/build-everything/_deps" -type f -path '*/openxr/openxr_platform.h' -print -quit 2>/dev/null || true)"
fi
[[ -n "$hdr" ]] || fail "OpenXR platform headers not found in bounded locations"
inc="$(dirname "$(dirname "$hdr")")"
echo "[preflight] OpenXR include root: $inc"
'''
if old not in s:
    raise SystemExit('error: unbounded header-search anchor not found')
s=s.replace(old,new,1)
old2='''echo '[1/3] Compiling graphics-bound Vulkan/OpenXR stimulus'
c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
'''
new2='''echo '[1/3] Compiling graphics-bound Vulkan/OpenXR stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
'''
if old2 not in s:
    raise SystemExit('error: compile anchor not found')
s=s.replace(old2,new2,1)
if 'for root in /usr/include "$WORKTREE/build-everything" "$WORKTREE"' in s:
    raise SystemExit('error: stale unbounded header search remains')
p.write_text(s)
PY

# Whole-wrapper preflight before touching the Quest.
grep -Fq '[preflight] Resolving OpenXR headers from bounded locations' "$build_script"
grep -Fq 'timeout 5s find "$WORKTREE/build-everything/_deps"' "$build_script"
grep -Fq '45s c++' "$build_script"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-projection-layer' "$build_script"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$runtime_script"
! grep -Fq 'XR_MND_headless' "$runtime_script"

echo '[A/2] Building and statically auditing graphics-bound Vulkan stimulus (bounded preflight)'
bash "$build_script"

echo '[B/2] Running encoded NVENC -> Quest recovery gate'
bash "$runtime_script"
