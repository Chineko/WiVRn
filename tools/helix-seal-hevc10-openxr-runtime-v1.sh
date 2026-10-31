#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="99aeae6e6aa213b07ff32385297b8d0743b270aa"
BASE_META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
MONADO_REV="8b259763fdd23c46592fd4cdd30b4eea997d4b70"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
WORKTREE="$OUT_ROOT/worktree"
HELPER_ROOT="$OUT_ROOT/openxr-runtime-v1"
LIB="$HELPER_ROOT/libmonado_wivrn.so"
MANIFEST="$HELPER_ROOT/openxr_wivrn.json"
META="$HELPER_ROOT/metadata.txt"
SEAL="$HELPER_ROOT/seal.txt"
TEMPLATE_REL="server/dist/openxr_manifest.in.json"
SERVER_CMAKE_REL="server/CMakeLists.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep python3 file nm tail; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$LIB" "$MANIFEST" "$META" "$WORKTREE/$TEMPLATE_REL" "$WORKTREE/$SERVER_CMAKE_REL"; do [[ -s "$f" ]] || fail "missing helper artifact/source: $f"; done
[[ ! -e "$SEAL" ]] || fail "helper seal already exists: $SEAL"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || fail "worktree source dirty"
grep -Fqx "$MONADO_REV" "$WORKTREE/monado-rev" || fail "Monado revision mismatch"

grep -Fq 'set_target_properties(monado PROPERTIES OUTPUT_NAME "monado_wivrn")' "$WORKTREE/$SERVER_CMAKE_REL" || fail "monado output-name binding missing"
grep -Fq 'generate_openxr_runtime_manifest_at_install(' "$WORKTREE/$SERVER_CMAKE_REL" || fail "install-time manifest generator missing"
grep -Fq 'MANIFEST_TEMPLATE "${CMAKE_CURRENT_SOURCE_DIR}/dist/openxr_manifest.in.json"' "$WORKTREE/$SERVER_CMAKE_REL" || fail "manifest template binding missing"
grep -Fq '"library_path": "@target_path@"@extra_fields@' "$WORKTREE/$TEMPLATE_REL" || fail "manifest template contract missing"

getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
[[ "$(getm source_commit)" == "$SOURCE_COMMIT" ]] || fail "helper metadata source mismatch"
[[ "$(getm base_metadata_sha256)" == "$BASE_META_SHA256" ]] || fail "base metadata binding mismatch"
[[ "$(getm monado_rev)" == "$MONADO_REV" ]] || fail "helper metadata Monado revision mismatch"
[[ "$(getm openxr_runtime)" == "$LIB" ]] || fail "helper runtime path mismatch"
[[ "$(getm openxr_manifest)" == "$MANIFEST" ]] || fail "helper manifest path mismatch"
[[ "$(getm manifest_contract)" == 'absolute-path-exact-copied-monado_wivrn-runtime' ]] || fail "manifest contract mismatch"
[[ "$(getm runtime_export_gate)" == 'PASS xrNegotiateLoaderRuntimeInterface' ]] || fail "runtime export gate mismatch"
[[ "$(getm artifact_gate)" == 'PASS exact-source-monado-openxr-runtime-plus-absolute-manifest' ]] || fail "helper artifact gate mismatch"
[[ "$(getm runtime_status)" == 'NOT_RUN' ]] || fail "helper metadata runtime status mismatch"

TEMPLATE_SHA="$(sha256sum "$WORKTREE/$TEMPLATE_REL" | awk '{print $1}')"
SERVER_CMAKE_SHA="$(sha256sum "$WORKTREE/$SERVER_CMAKE_REL" | awk '{print $1}')"
LIB_SHA="$(sha256sum "$LIB" | awk '{print $1}')"
MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$TEMPLATE_SHA" "$SERVER_CMAKE_SHA" "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA256: $h"; done
[[ "$TEMPLATE_SHA" == "$(getm source_manifest_template_sha256)" ]] || fail "template hash mismatch"
[[ "$SERVER_CMAKE_SHA" == "$(getm source_server_cmake_sha256)" ]] || fail "server CMake hash mismatch"
[[ "$LIB_SHA" == "$(getm openxr_runtime_sha256)" ]] || fail "OpenXR runtime hash mismatch"
[[ "$MANIFEST_SHA" == "$(getm openxr_manifest_sha256)" ]] || fail "OpenXR manifest hash mismatch"

file "$LIB" | grep -Eq 'ELF 64-bit.*x86-64' || fail "sealed Monado runtime is not x86-64 ELF"
nm -D "$LIB" | grep -Fq 'xrNegotiateLoaderRuntimeInterface' || fail "sealed OpenXR negotiation export missing"
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
p, lib = sys.argv[1:]
with open(p, encoding='utf-8') as f: j=json.load(f)
expected={"file_format_version":"1.0.0","runtime":{"name":"WiVRn","library_path":os.path.realpath(lib)}}
if j != expected:
    raise SystemExit('FAIL: sealed manifest semantic mismatch')
if not os.path.isabs(j['runtime']['library_path']):
    raise SystemExit('FAIL: sealed manifest runtime path is not absolute')
PY

cat > "$SEAL" <<EOF
artifact_seal=PASS hevc10-openxr-runtime-v1-exact-source-monado-absolute-manifest
source_commit=$SOURCE_COMMIT
build_tooling_commit=$BUILD_TOOLING_COMMIT
base_metadata_sha256=$BASE_META_SHA256
monado_rev=$MONADO_REV
source_server_cmake_sha256=$SERVER_CMAKE_SHA
source_manifest_template_sha256=$TEMPLATE_SHA
openxr_runtime_sha256=$LIB_SHA
openxr_manifest_sha256=$MANIFEST_SHA
metadata_sha256=$META_SHA
runtime_export_gate=PASS xrNegotiateLoaderRuntimeInterface
manifest_contract=absolute-path-exact-copied-monado_wivrn-runtime
runtime_status=NOT_RUN
EOF

printf 'OPENXR_HELPER_SEAL=PASS hevc10-openxr-runtime-v1-exact-source-monado-absolute-manifest\nsource_commit=%s\nbuild_tooling_commit=%s\nmonado_rev=%s\nopenxr_runtime_sha256=%s\nopenxr_manifest_sha256=%s\nmetadata_sha256=%s\nseal=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$MONADO_REV" "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA" "$SEAL"
