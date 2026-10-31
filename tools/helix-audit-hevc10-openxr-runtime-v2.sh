#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="999b6a0d0a693720ef243fb3a9e4e2d90b71f74b"
SEAL_TOOLING_COMMIT="8f36cf75d1879dca503afd6e645100ac230ef76c"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
WORKTREE="$OUT_ROOT/worktree"
BUILD_DIR="$WORKTREE/build-server"
SERVER="$OUT_ROOT/wivrn-server-hevc10-recovery-v1"
APK="$OUT_ROOT/helix-hevc10-recovery-392bb662ed20.apk"
BASE_META="$OUT_ROOT/runtime-v1-metadata.txt"
BASE_SEAL="$OUT_ROOT/runtime-v1-seal.txt"
SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"
APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"
BASE_META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
MONADO_REV="8b259763fdd23c46592fd4cdd30b4eea997d4b70"
HELPER_ROOT="$OUT_ROOT/openxr-runtime-v2"
META="$HELPER_ROOT/metadata.txt"
SEAL="$HELPER_ROOT/seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep find realpath file nm python3 sort tail ninja; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "local HEAD is not frozen source commit"
[[ -z "$(git status --short)" ]] || fail "local source tree dirty"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --short)" ]] || fail "worktree source dirty"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_META_SHA256" ]] || fail "base metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$BASE_SEAL" || fail "base artifact seal mismatch"
grep -Fqx "$MONADO_REV" "$WORKTREE/monado-rev" || fail "Monado revision mismatch"

[[ -s "$META" && -s "$SEAL" ]] || fail "helper metadata/seal missing"
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }
[[ "$(gets source_commit)" == "$SOURCE_COMMIT" ]] || fail "seal source mismatch"
[[ "$(gets build_tooling_commit)" == "$BUILD_TOOLING_COMMIT" ]] || fail "seal builder binding mismatch"
[[ "$(gets runtime_target)" == 'openxr_wivrn' ]] || fail "seal runtime target mismatch"
grep -Fqx 'artifact_seal=PASS hevc10-openxr-runtime-v2-exact-openxr_wivrn-generated-dev-manifest' "$SEAL" || fail "helper seal marker mismatch"
[[ "$(getm runtime_target)" == 'openxr_wivrn' ]] || fail "metadata runtime target mismatch"
[[ "$(getm runtime_export_gate)" == 'PASS xrNegotiateLoaderRuntimeInterface' ]] || fail "metadata export gate mismatch"
[[ "$(getm manifest_binding)" == 'PASS generated-dev-manifest-resolves-exact-runtime-elf' ]] || fail "metadata manifest binding mismatch"
[[ "$(getm runtime_status)" == 'NOT_RUN' && "$(gets runtime_status)" == 'NOT_RUN' ]] || fail "runtime status mismatch"

LIB="$(getm openxr_runtime)"
MANIFEST="$(getm openxr_manifest)"
[[ -s "$LIB" && -s "$MANIFEST" ]] || fail "helper runtime/manifest missing"
mapfile -t libs < <(find "$BUILD_DIR" \( -type f -o -type l \) -name 'libopenxr_wivrn.so' -print | while read -r p; do realpath "$p"; done | sort -u)
mapfile -t manifests < <(find "$BUILD_DIR" -type f -name 'openxr_wivrn-dev.json' -print | sort -u)
[[ ${#libs[@]} -eq 1 && "${libs[0]}" == "$(realpath "$LIB")" ]] || fail "exact runtime ELF count/identity mismatch"
[[ ${#manifests[@]} -eq 1 && "${manifests[0]}" == "$MANIFEST" ]] || fail "exact dev manifest count/identity mismatch"
ninja -C "$BUILD_DIR" -t targets all | grep -Eq '(^|/)openxr_wivrn:' || fail "configured graph lost openxr_wivrn target"
file "$LIB" | grep -Eq 'ELF 64-bit.*x86-64' || fail "OpenXR runtime architecture mismatch"
nm -D --defined-only "$LIB" | grep -Fq 'xrNegotiateLoaderRuntimeInterface' || fail "negotiation export absent"
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
manifest,lib=sys.argv[1:]
with open(manifest,encoding='utf-8') as f:j=json.load(f)
if j.get('file_format_version')!='1.0.0': raise SystemExit('FAIL: manifest version mismatch')
r=j.get('runtime')
if not isinstance(r,dict): raise SystemExit('FAIL: runtime object missing')
lp=r.get('library_path')
if not isinstance(lp,str) or not lp: raise SystemExit('FAIL: library_path missing')
resolved=os.path.realpath(lp if os.path.isabs(lp) else os.path.join(os.path.dirname(manifest),lp))
if resolved!=os.path.realpath(lib): raise SystemExit('FAIL: manifest does not resolve runtime ELF')
PY

LIB_SHA="$(sha256sum "$LIB" | awk '{print $1}')"
MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA256 $h"; done
[[ "$LIB_SHA" == "$(getm openxr_runtime_sha256)" && "$LIB_SHA" == "$(gets openxr_runtime_sha256)" ]] || fail "runtime hash binding mismatch"
[[ "$MANIFEST_SHA" == "$(getm openxr_manifest_sha256)" && "$MANIFEST_SHA" == "$(gets openxr_manifest_sha256)" ]] || fail "manifest hash binding mismatch"
[[ "$META_SHA" == "$(gets metadata_sha256)" ]] || fail "metadata hash binding mismatch"

# Reassert source-level distinction that invalidated v1 helper.
grep -Fq 'RUNTIME_TARGET ${RUNTIME_TARGET}' "$WORKTREE/server/CMakeLists.txt" || fail "WiVRn runtime-target manifest binding missing"
grep -Fq 'LIBMONADO monado_wivrn' "$WORKTREE/server/CMakeLists.txt" || fail "WiVRn libmonado binding missing"

echo 'AUDIT_A=PASS exact-source-server-apk-plus-openxr-v2-hashes-and-seals'
echo 'AUDIT_B=PASS resolved-openxr_wivrn-loader-export-generated-dev-manifest-no-libmonado-confusion'
echo "source_commit=$SOURCE_COMMIT"
echo "build_tooling_commit=$BUILD_TOOLING_COMMIT"
echo "seal_tooling_commit=$SEAL_TOOLING_COMMIT"
echo "openxr_runtime_sha256=$LIB_SHA"
echo "openxr_manifest_sha256=$MANIFEST_SHA"
echo "metadata_sha256=$META_SHA"
echo 'RUNTIME=NOT_RUN'
