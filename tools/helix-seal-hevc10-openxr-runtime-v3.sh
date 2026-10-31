#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="16fe9cca088c836abc4c73700c4ebd21ca2d58ab"
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
HELPER_ROOT="$OUT_ROOT/openxr-runtime-v3"
META="$HELPER_ROOT/metadata.txt"
SEAL="$HELPER_ROOT/seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep find realpath file nm python3 sort tail cat ninja; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done

[[ -d "$WORKTREE" && -d "$BUILD_DIR" ]] || fail "exact-source worktree/build-server missing"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --short)" ]] || fail "worktree source dirty"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_META_SHA256" ]] || fail "base metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$BASE_SEAL" || fail "base artifact seal mismatch"
grep -Fqx "$MONADO_REV" "$WORKTREE/monado-rev" || fail "Monado revision mismatch"
[[ -s "$META" ]] || fail "helper metadata missing"
[[ ! -e "$SEAL" ]] || fail "helper seal already exists"

getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
[[ "$(getm source_commit)" == "$SOURCE_COMMIT" ]] || fail "helper metadata source mismatch"
[[ "$(getm base_server_sha256)" == "$SERVER_SHA256" ]] || fail "helper metadata server binding mismatch"
[[ "$(getm base_apk_sha256)" == "$APK_SHA256" ]] || fail "helper metadata APK binding mismatch"
[[ "$(getm base_metadata_sha256)" == "$BASE_META_SHA256" ]] || fail "helper metadata base-meta binding mismatch"
[[ "$(getm monado_rev)" == "$MONADO_REV" ]] || fail "helper metadata Monado revision mismatch"
[[ "$(getm runtime_target)" == 'openxr_wivrn' ]] || fail "helper metadata runtime target mismatch"
[[ "$(getm runtime_target_query)" == 'PASS ninja-query-openxr_wivrn' ]] || fail "helper target query mismatch"
[[ "$(getm runtime_export_gate)" == 'PASS xrNegotiateLoaderRuntimeInterface' ]] || fail "helper export gate mismatch"
[[ "$(getm manifest_binding)" == 'PASS generated-dev-manifest-resolves-exact-runtime-elf' ]] || fail "helper manifest binding mismatch"
[[ "$(getm artifact_gate)" == 'PASS exact-source-openxr_wivrn-runtime-and-generated-dev-manifest' ]] || fail "helper artifact gate mismatch"
[[ "$(getm runtime_status)" == 'NOT_RUN' ]] || fail "helper runtime status mismatch"

ninja -C "$BUILD_DIR" -t query openxr_wivrn >/dev/null 2>&1 || fail "configured graph lost openxr_wivrn target"
LIB="$(getm openxr_runtime)"
MANIFEST="$(getm openxr_manifest)"
[[ -s "$LIB" && -s "$MANIFEST" ]] || fail "helper runtime/manifest missing"
mapfile -t lib_candidates < <(find "$BUILD_DIR" \( -type f -o -type l \) -name 'libopenxr_wivrn.so' -print | while read -r p; do realpath "$p"; done | sort -u)
[[ ${#lib_candidates[@]} -eq 1 && "${lib_candidates[0]}" == "$(realpath "$LIB")" ]] || fail "runtime ELF identity mismatch"
mapfile -t manifest_candidates < <(find "$BUILD_DIR" -type f -name 'openxr_wivrn-dev.json' -print | sort -u)
[[ ${#manifest_candidates[@]} -eq 1 && "${manifest_candidates[0]}" == "$MANIFEST" ]] || fail "generated manifest identity mismatch"

file_out="$(file -b "$LIB")"
[[ "$file_out" == *"ELF 64-bit"* && "$file_out" == *"x86-64"* ]] || fail "sealed OpenXR runtime architecture mismatch: $file_out"
nm_out="$(nm -D --defined-only "$LIB" 2>/dev/null)"
[[ "$nm_out" == *"xrNegotiateLoaderRuntimeInterface"* ]] || fail "sealed OpenXR negotiation export missing"
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
manifest, lib = sys.argv[1:]
with open(manifest, encoding='utf-8') as f:
    j=json.load(f)
if j.get('file_format_version') != '1.0.0':
    raise SystemExit('FAIL: manifest version mismatch')
runtime=j.get('runtime')
if not isinstance(runtime, dict):
    raise SystemExit('FAIL: runtime object missing')
lp=runtime.get('library_path')
if not isinstance(lp, str) or not lp:
    raise SystemExit('FAIL: library_path missing')
resolved=os.path.realpath(lp if os.path.isabs(lp) else os.path.join(os.path.dirname(manifest), lp))
if resolved != os.path.realpath(lib):
    raise SystemExit('FAIL: manifest does not resolve runtime ELF')
PY

LIB_SHA="$(sha256sum "$LIB" | awk '{print $1}')"
MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA256: $h"; done
[[ "$LIB_SHA" == "$(getm openxr_runtime_sha256)" ]] || fail "runtime hash mismatch"
[[ "$MANIFEST_SHA" == "$(getm openxr_manifest_sha256)" ]] || fail "manifest hash mismatch"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server changed before helper seal"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK changed before helper seal"

cat > "$SEAL" <<EOF
artifact_seal=PASS hevc10-openxr-runtime-v3-exact-openxr_wivrn-no-pipefail-false-gates
source_commit=$SOURCE_COMMIT
build_tooling_commit=$BUILD_TOOLING_COMMIT
base_server_sha256=$SERVER_SHA256
base_apk_sha256=$APK_SHA256
base_metadata_sha256=$BASE_META_SHA256
monado_rev=$MONADO_REV
runtime_target=openxr_wivrn
openxr_runtime=$LIB
openxr_runtime_sha256=$LIB_SHA
openxr_manifest=$MANIFEST
openxr_manifest_sha256=$MANIFEST_SHA
metadata_sha256=$META_SHA
runtime_target_query=PASS ninja-query-openxr_wivrn
runtime_export_gate=PASS xrNegotiateLoaderRuntimeInterface
manifest_binding=PASS generated-dev-manifest-resolves-exact-runtime-elf
runtime_status=NOT_RUN
EOF

printf 'OPENXR_HELPER_V3_SEAL=PASS exact-openxr_wivrn-no-pipefail-false-gates\nsource_commit=%s\nbuild_tooling_commit=%s\nopenxr_runtime_sha256=%s\nopenxr_manifest_sha256=%s\nmetadata_sha256=%s\nseal=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA" "$SEAL"
