#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
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

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git cmake ninja find realpath file nm sha256sum awk grep python3 mkdir sort; do
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
grep -Fqx 'WIVRN_BUILD_SERVER_LIBRARY:BOOL=ON' "$BUILD_DIR/CMakeCache.txt" || fail "server runtime library not configured"
grep -Fqx 'WIVRN_BUILD_DASHBOARD:BOOL=OFF' "$BUILD_DIR/CMakeCache.txt" || fail "unexpected dashboard configuration"
ninja -C "$BUILD_DIR" -t targets all | grep -Eq '(^|/)openxr_wivrn:' || fail "openxr_wivrn target missing from configured graph"

[[ ! -e "$HELPER_ROOT" ]] || fail "helper artifact root already exists: $HELPER_ROOT"
mkdir -p "$HELPER_ROOT"

echo '[1/4] Building only the resolved loader-facing OpenXR runtime target'
cmake --build "$BUILD_DIR" --target openxr_wivrn -j 2

echo '[2/4] Resolving exact generated ELF and development manifest'
mapfile -t lib_candidates < <(find "$BUILD_DIR" \( -type f -o -type l \) -name 'libopenxr_wivrn.so' -print | while read -r p; do realpath "$p"; done | sort -u)
[[ ${#lib_candidates[@]} -eq 1 ]] || fail "libopenxr_wivrn realpath count=${#lib_candidates[@]}"
LIB="${lib_candidates[0]}"
mapfile -t manifest_candidates < <(find "$BUILD_DIR" -type f -name 'openxr_wivrn-dev.json' -print | sort -u)
[[ ${#manifest_candidates[@]} -eq 1 ]] || fail "openxr_wivrn-dev.json count=${#manifest_candidates[@]}"
MANIFEST="${manifest_candidates[0]}"

file "$LIB" | grep -Eq 'ELF 64-bit.*x86-64' || fail "OpenXR runtime is not x86-64 ELF"
nm -D --defined-only "$LIB" | grep -Fq 'xrNegotiateLoaderRuntimeInterface' || fail "OpenXR negotiation export missing from libopenxr_wivrn.so"
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
manifest, lib = sys.argv[1:]
with open(manifest, encoding='utf-8') as f:
    j=json.load(f)
if j.get('file_format_version') != '1.0.0':
    raise SystemExit('FAIL: unexpected manifest file_format_version')
runtime=j.get('runtime')
if not isinstance(runtime, dict):
    raise SystemExit('FAIL: manifest runtime object missing')
lp=runtime.get('library_path')
if not isinstance(lp, str) or not lp:
    raise SystemExit('FAIL: manifest library_path missing')
resolved=os.path.realpath(lp if os.path.isabs(lp) else os.path.join(os.path.dirname(manifest), lp))
expected=os.path.realpath(lib)
if resolved != expected:
    raise SystemExit(f'FAIL: manifest library_path resolves to {resolved}, expected {expected}')
print(f'manifest_runtime_name={runtime.get("name", "<missing>")}')
print(f'manifest_library_path={lp}')
print(f'manifest_library_resolved={resolved}')
PY

echo '[3/4] Freezing exact helper hashes and provenance'
LIB_SHA="$(sha256sum "$LIB" | awk '{print $1}')"
MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
for h in "$LIB_SHA" "$MANIFEST_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA256: $h"; done
cat > "$META" <<EOF
source_commit=$SOURCE_COMMIT
base_server_sha256=$SERVER_SHA256
base_apk_sha256=$APK_SHA256
base_metadata_sha256=$BASE_META_SHA256
monado_rev=$MONADO_REV
runtime_target=openxr_wivrn
openxr_runtime=$LIB
openxr_runtime_sha256=$LIB_SHA
openxr_manifest=$MANIFEST
openxr_manifest_sha256=$MANIFEST_SHA
runtime_export_gate=PASS xrNegotiateLoaderRuntimeInterface
manifest_binding=PASS generated-dev-manifest-resolves-exact-runtime-elf
artifact_gate=PASS exact-source-openxr_wivrn-runtime-and-generated-dev-manifest
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid helper metadata SHA256"

echo '[4/4] OpenXR helper v2 build gate complete'
printf 'OPENXR_HELPER_V2_BUILD=PASS exact-source-openxr_wivrn-generated-dev-manifest\nsource_commit=%s\nmonado_rev=%s\nopenxr_runtime_sha256=%s\nopenxr_manifest_sha256=%s\nmetadata_sha256=%s\nopenxr_runtime=%s\nopenxr_manifest=%s\nmetadata=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$MONADO_REV" "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA" "$LIB" "$MANIFEST" "$META"
