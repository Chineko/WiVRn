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
AGENTS_SHA256="06f177622d2fa7d78b02843195f1ebe9fe24e931cebe71b3a4e3fa4b40dd35c8"
MONADO_REV="8b259763fdd23c46592fd4cdd30b4eea997d4b70"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep find sort python3 ninja; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"

# Re-establish rules/source/artifact checkpoint before reading the configured graph.
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "local HEAD is not frozen source commit"
[[ -z "$(git status --short)" ]] || fail "local source tree is dirty"
[[ "$(git show "$SOURCE_COMMIT:AGENTS.md" | sha256sum | awk '{print $1}')" == "$AGENTS_SHA256" ]] || fail "AGENTS.md hash mismatch"
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
NINJA_FILE="$BUILD_DIR/build.ninja"
[[ -s "$CACHE" && -s "$NINJA_FILE" ]] || fail "configured Ninja graph missing"
grep -Fqx 'WIVRN_BUILD_SERVER:BOOL=ON' "$CACHE" || fail "server preset not enabled"
grep -Fqx 'WIVRN_BUILD_SERVER_LIBRARY:BOOL=ON' "$CACHE" || fail "server runtime library not enabled"
grep -Fqx 'WIVRN_BUILD_DASHBOARD:BOOL=OFF' "$CACHE" || fail "unexpected dashboard enablement"

mapfile -t monado_srcs < <(find "$BUILD_DIR" -type d -name monado-src -print | sort -u)
[[ ${#monado_srcs[@]} -eq 1 ]] || fail "expected one configured monado-src, found ${#monado_srcs[@]}"
MONADO_SRC="${monado_srcs[0]}"
ACTIVE="$MONADO_SRC/src/xrt/targets/openxr/active_runtime.cmake"
OPENXR_CMAKE="$MONADO_SRC/src/xrt/targets/openxr/CMakeLists.txt"
[[ -s "$ACTIVE" && -s "$OPENXR_CMAKE" ]] || fail "Monado OpenXR CMake sources missing"

echo "monado_source=$MONADO_SRC"
echo '--- ACTIVE_RUNTIME_CMAKE ---'
grep -n -E 'RUNTIME_TARGET|MANIFEST|configure_file|set\(' "$ACTIVE" || true
echo '--- OPENXR_CMAKELISTS_RUNTIME_LINES ---'
grep -n -E 'RUNTIME_TARGET|oxr_api_negotiate|xrNegotiateLoaderRuntimeInterface|add_library|add_executable|active_runtime' "$OPENXR_CMAKE" || true

echo '--- NINJA_TARGETS_FILTERED ---'
ninja -C "$BUILD_DIR" -t targets all | grep -E '(^|/|:)(openxr|oxr|runtime)|openxr|oxr|runtime' | sort -u || true

echo '--- NINJA_GRAPH_RESOLUTION ---'
python3 - "$NINJA_FILE" "$BUILD_DIR" <<'PY'
from pathlib import Path
import re, sys
ninja=Path(sys.argv[1])
build=Path(sys.argv[2])
lines=ninja.read_text(errors='replace').splitlines()
edges=[]
for lineno,line in enumerate(lines,1):
    if not line.startswith('build '):
        continue
    body=line[6:]
    if ':' not in body:
        continue
    lhs,rhs=body.split(':',1)
    outs=[x for x in lhs.split() if x not in {'|'}]
    parts=rhs.strip().split()
    if not parts:
        continue
    rule=parts[0]
    ins=[x for x in parts[1:] if x not in {'|','||'}]
    edges.append((lineno,outs,rule,ins,line))

seed_edges=[e for e in edges if 'oxr_api_negotiate.c.o' in e[4]]
print(f'OXR_NEGOTIATE_OBJECT_EDGE_COUNT={len(seed_edges)}')
for e in seed_edges:
    print(f'OXR_NEGOTIATE_EDGE line={e[0]} rule={e[2]} outputs={" ".join(e[1])}')

seeds=[]
for _,outs,_,_,_ in seed_edges:
    for o in outs:
        if 'oxr_api_negotiate.c.o' in o:
            seeds.append(o)
print(f'OXR_NEGOTIATE_OBJECT_OUTPUT_COUNT={len(set(seeds))}')
for s in sorted(set(seeds)):
    print(f'OXR_NEGOTIATE_OBJECT {s}')
    m=re.search(r'CMakeFiles/([^/]+)\.dir/',s)
    if m:
        print(f'RUNTIME_TARGET_CANDIDATE_FROM_OBJECT={m.group(1)}')

front=set(seeds)
seen=set(front)
for depth in range(1,8):
    nxt=set()
    for lineno,outs,rule,ins,line in edges:
        if front.intersection(ins):
            print(f'DOWNSTREAM_EDGE depth={depth} line={lineno} rule={rule} outputs={" ".join(outs)}')
            for o in outs:
                if o not in seen:
                    nxt.add(o); seen.add(o)
    if not nxt:
        break
    front=nxt

shared=[]
for lineno,outs,rule,ins,line in edges:
    for o in outs:
        if ('.so' in o or 'openxr' in o.lower()) and ('CXX_SHARED_LIBRARY_LINKER' in rule or 'C_SHARED_LIBRARY_LINKER' in rule or 'openxr' in o.lower()):
            shared.append((lineno,o,rule))
print(f'OPENXR_SHARED_OUTPUT_CANDIDATE_COUNT={len(shared)}')
for lineno,o,rule in shared:
    p=build/o
    print(f'OPENXR_SHARED_OUTPUT_CANDIDATE line={lineno} output={o} rule={rule} exists={int(p.exists())}')
PY

# Build graph must contain the negotiate translation unit even if its final runtime ELF is not built yet.
grep -Fq 'oxr_api_negotiate.c.o' "$NINJA_FILE" || fail "configured graph lacks oxr_api_negotiate object"

echo 'AUDIT_B_TARGET_RESOLUTION=PASS read-only-configured-ninja-graph'
echo "source_commit=$SOURCE_COMMIT"
echo 'RUNTIME=NOT_RUN'
