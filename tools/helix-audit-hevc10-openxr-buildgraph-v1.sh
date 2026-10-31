#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
WORKTREE="$OUT_ROOT/worktree"
BUILD_DIR="$WORKTREE/build-server"
SERVER="$OUT_ROOT/wivrn-server-hevc10-recovery-v1"
APK="$OUT_ROOT/helix-hevc10-recovery-392bb662ed20.apk"
META="$OUT_ROOT/runtime-v1-metadata.txt"
SEAL="$OUT_ROOT/runtime-v1-seal.txt"
SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"
APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"
META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
MONADO_REV="8b259763fdd23c46592fd4cdd30b4eea997d4b70"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep find file nm realpath sort python3 mktemp cat; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"

# Rules and exact source/artifact checkpoint.
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "local HEAD is not frozen source commit"
[[ -z "$(git status --short)" ]] || fail "local source tree is dirty"
[[ "$(git show "$SOURCE_COMMIT:AGENTS.md" | sha256sum | awk '{print $1}')" == "c3b21b35998bf333cb7e1e34cffb69f8d67091545efac6dc7134c585e9847376" ]] || fail "AGENTS.md hash mismatch"
[[ -d "$WORKTREE" && -d "$BUILD_DIR" ]] || fail "exact-source worktree/build-server missing"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "build worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --short)" ]] || fail "build worktree is dirty"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$META_SHA256" ]] || fail "metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$SEAL" || fail "base artifact seal mismatch"
grep -Fqx "$MONADO_REV" "$WORKTREE/monado-rev" || fail "Monado revision mismatch"

echo 'AUDIT_A=PASS exact-source-server-apk-metadata-seal-and-rules'

CACHE="$BUILD_DIR/CMakeCache.txt"
NINJA="$BUILD_DIR/build.ninja"
[[ -s "$CACHE" ]] || fail "CMakeCache.txt missing"
[[ -s "$NINJA" ]] || fail "build.ninja missing"
grep -Fqx 'WIVRN_BUILD_SERVER:BOOL=ON' "$CACHE" || fail "server preset not enabled"
grep -Fqx 'WIVRN_BUILD_SERVER_LIBRARY:BOOL=ON' "$CACHE" || fail "server runtime library not enabled"
grep -Fqx 'WIVRN_BUILD_DASHBOARD:BOOL=OFF' "$CACHE" || fail "unexpected dashboard enablement"

echo 'BUILD_CONFIG=PASS server=ON server_library=ON dashboard=OFF'

mapfile -t monado_srcs < <(find "$BUILD_DIR" -type d -name monado-src -print | sort -u)
[[ ${#monado_srcs[@]} -eq 1 ]] || fail "expected one configured monado-src, found ${#monado_srcs[@]}"
MONADO_SRC="${monado_srcs[0]}"

echo "monado_source=$MONADO_SRC"

# Source-level target/export inventory from the exact fetched Monado revision.
python3 - "$MONADO_SRC" <<'PY'
from pathlib import Path
import re, sys
root=Path(sys.argv[1])
rt=[]; sym=[]
for p in root.rglob('*'):
    if not p.is_file():
        continue
    if p.suffix not in {'.cmake','.txt','.c','.cc','.cpp','.h','.hpp'} and p.name != 'CMakeLists.txt':
        continue
    try: s=p.read_text(errors='replace')
    except Exception: continue
    if 'RUNTIME_TARGET' in s:
        for i,line in enumerate(s.splitlines(),1):
            if 'RUNTIME_TARGET' in line:
                rt.append((str(p.relative_to(root)),i,line.strip()))
    if 'xrNegotiateLoaderRuntimeInterface' in s:
        for i,line in enumerate(s.splitlines(),1):
            if 'xrNegotiateLoaderRuntimeInterface' in line:
                sym.append((str(p.relative_to(root)),i,line.strip()))
print(f'MONADO_RUNTIME_TARGET_REFERENCES={len(rt)}')
for p,i,l in rt:
    print(f'RUNTIME_TARGET_REF {p}:{i}: {l}')
print(f'MONADO_NEGOTIATION_SYMBOL_REFERENCES={len(sym)}')
for p,i,l in sym:
    print(f'NEGOTIATION_SYMBOL_REF {p}:{i}: {l}')
defs=[]
pat=re.compile(r'set\s*\(\s*RUNTIME_TARGET\s+([^\s\)]+)', re.I)
for p,i,l in rt:
    m=pat.search(l)
    if m: defs.append((p,i,m.group(1)))
print(f'RUNTIME_TARGET_DEFINITIONS={len(defs)}')
for p,i,v in defs:
    print(f'RUNTIME_TARGET_DEF {p}:{i}: {v}')
PY

# Report stale runner assumptions as facts, not gates.
manifest_count="$(find "$BUILD_DIR" -type f -name 'openxr_wivrn-dev.json' -print | awk 'END{print NR+0}')"
prefix_count="$(find "$BUILD_DIR" -type f -path '*/dashboard/prefix.sh' -print | awk 'END{print NR+0}')"
echo "stale_openxr_wivrn_dev_manifest_count=$manifest_count"
echo "stale_dashboard_prefix_count=$prefix_count"

# Enumerate every built shared-library ELF and identify the actual loader-facing export.
nm_tmp="$(mktemp)"
elf_tmp="$(mktemp)"
trap 'rm -f "$nm_tmp" "$elf_tmp"' EXIT INT TERM
: > "$elf_tmp"
while IFS= read -r -d '' p; do
  if file "$p" | grep -Fq 'ELF 64-bit'; then
    real="$(realpath "$p")"
    printf '%s\n' "$real" >> "$elf_tmp"
  fi
done < <(find "$BUILD_DIR" \( -type f -o -type l \) -name '*.so*' -print0)
sort -u "$elf_tmp" -o "$elf_tmp"
elf_count="$(awk 'END{print NR+0}' "$elf_tmp")"
echo "built_shared_elf_count=$elf_count"

export_count=0
while IFS= read -r p; do
  [[ -n "$p" ]] || continue
  : > "$nm_tmp"
  nm -D --defined-only "$p" > "$nm_tmp" 2>/dev/null || true
  if grep -Fq 'xrNegotiateLoaderRuntimeInterface' "$nm_tmp"; then
    export_count=$((export_count+1))
    h="$(sha256sum "$p" | awk '{print $1}')"
    echo "OPENXR_NEGOTIATION_EXPORT path=$p sha256=$h"
  fi
done < "$elf_tmp"
echo "openxr_negotiation_export_elf_count=$export_count"

# Inventory libmonado_wivrn separately so alias/output-name cannot be confused with runtime target.
mapfile -t monado_libs < <(find "$BUILD_DIR" \( -type f -o -type l \) -name 'libmonado_wivrn.so*' -print | while read -r p; do realpath "$p"; done | sort -u)
echo "libmonado_wivrn_real_count=${#monado_libs[@]}"
for p in "${monado_libs[@]}"; do
  echo "LIBMONADO_WIVRN path=$p sha256=$(sha256sum "$p" | awk '{print $1}')"
done

# Inventory install-generation evidence without running install.
install_refs="$(grep -R -n -E 'openxr_wivrn|generate_openxr_runtime_manifest|RUNTIME_TARGET|monado_wivrn' "$BUILD_DIR" --include='cmake_install.cmake' --include='*.cmake' 2>/dev/null | awk 'END{print NR+0}')"
echo "build_install_runtime_reference_lines=$install_refs"

echo 'AUDIT_B_INVENTORY=PASS read-only-buildgraph-and-export-enumeration'
echo "source_commit=$SOURCE_COMMIT"
echo 'RUNTIME=NOT_RUN'
