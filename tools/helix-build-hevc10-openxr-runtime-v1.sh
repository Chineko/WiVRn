#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BASE_META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
MONADO_REV="8b259763fdd23c46592fd4cdd30b4eea997d4b70"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
WORKTREE="$OUT_ROOT/worktree"
BUILD_DIR="$WORKTREE/build-server"
BASE_META="$OUT_ROOT/runtime-v1-metadata.txt"
HELPER_ROOT="$OUT_ROOT/openxr-runtime-v1"
LIB="$HELPER_ROOT/libmonado_wivrn.so"
MANIFEST="$HELPER_ROOT/openxr_wivrn.json"
META="$HELPER_ROOT/metadata.txt"
TEMPLATE_REL="server/dist/openxr_manifest.in.json"
SERVER_CMAKE_REL="server/CMakeLists.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git cmake find realpath file nm sha256sum awk grep python3 mkdir cp sort chmod; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done
[[ -d "$WORKTREE/.git" || -f "$WORKTREE/.git" ]] || fail "exact-source worktree missing: $WORKTREE"
[[ -d "$BUILD_DIR" ]] || fail "build-server directory missing: $BUILD_DIR"
[[ -s "$BASE_META" ]] || fail "base runtime metadata missing"
[[ "$(sha256sum "$BASE_META" | awk '{print $1}')" == "$BASE_META_SHA256" ]] || fail "base metadata hash mismatch"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || fail "worktree source dirty"
grep -Fqx "$MONADO_REV" "$WORKTREE/monado-rev" || fail "Monado revision mismatch"

grep -Fq 'set_target_properties(monado PROPERTIES OUTPUT_NAME "monado_wivrn")' "$WORKTREE/$SERVER_CMAKE_REL" || fail "monado output-name binding missing"
grep -Fq 'generate_openxr_runtime_manifest_at_install(' "$WORKTREE/$SERVER_CMAKE_REL" || fail "install-time manifest generator missing"
grep -Fq 'MANIFEST_TEMPLATE "${CMAKE_CURRENT_SOURCE_DIR}/dist/openxr_manifest.in.json"' "$WORKTREE/$SERVER_CMAKE_REL" || fail "manifest template binding missing"
grep -Fq '"library_path": "@target_path@"@extra_fields@' "$WORKTREE/$TEMPLATE_REL" || fail "manifest template contract missing"

[[ ! -e "$HELPER_ROOT" ]] || fail "helper artifact root already exists: $HELPER_ROOT"
mkdir -p "$HELPER_ROOT"

printf '[1/4] Building exact-source Monado OpenXR runtime target\n'
cmake --build "$BUILD_DIR" --target monado -j 2

mapfile -t raw_candidates < <(find "$BUILD_DIR" -type f \( -name 'libmonado_wivrn.so' -o -name 'libmonado_wivrn.so.*' \) -print)
[[ ${#raw_candidates[@]} -gt 0 ]] || fail "no libmonado_wivrn shared library produced"
mapfile -t candidates < <(printf '%s\n' "${raw_candidates[@]}" | while read -r p; do realpath "$p"; done | sort -u)
[[ ${#candidates[@]} -eq 1 ]] || { printf 'candidates:\n%s\n' "${candidates[*]}" >&2; fail "real OpenXR runtime library count=${#candidates[@]}"; }
SRC_LIB="${candidates[0]}"
file "$SRC_LIB" | grep -Eq 'ELF 64-bit.*x86-64' || fail "Monado runtime is not x86-64 ELF"
nm -D "$SRC_LIB" | grep -Fq 'xrNegotiateLoaderRuntimeInterface' || fail "OpenXR negotiation export missing"
cp -- "$SRC_LIB" "$LIB"
chmod 0555 "$LIB"

printf '[2/4] Materializing absolute-path manifest from committed template contract\n'
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
out, lib = sys.argv[1:]
lib = os.path.realpath(lib)
obj = {
    "file_format_version": "1.0.0",
    "runtime": {
        "name": "WiVRn",
        "library_path": lib,
    },
}
with open(out, "w", encoding="utf-8") as f:
    json.dump(obj, f, indent=4)
    f.write("\n")
PY
python3 - "$MANIFEST" "$LIB" <<'PY'
import json, os, sys
p, lib = sys.argv[1:]
with open(p, encoding='utf-8') as f: j=json.load(f)
if j != {"file_format_version":"1.0.0","runtime":{"name":"WiVRn","library_path":os.path.realpath(lib)}}:
    raise SystemExit('FAIL: generated manifest semantic mismatch')
PY

printf '[3/4] Freezing hashes and provenance\n'
TEMPLATE_SHA="$(sha256sum "$WORKTREE/$TEMPLATE_REL" | awk '{print $1}')"
SERVER_CMAKE_SHA="$(sha256sum "$WORKTREE/$SERVER_CMAKE_REL" | awk '{print $1}')"
LIB_SHA="$(sha256sum "$LIB" | awk '{print $1}')"
MANIFEST_SHA="$(sha256sum "$MANIFEST" | awk '{print $1}')"
for h in "$TEMPLATE_SHA" "$SERVER_CMAKE_SHA" "$LIB_SHA" "$MANIFEST_SHA"; do
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid SHA256: $h"
done
cat > "$META" <<EOF
source_commit=$SOURCE_COMMIT
base_metadata_sha256=$BASE_META_SHA256
monado_rev=$MONADO_REV
source_server_cmake_sha256=$SERVER_CMAKE_SHA
source_manifest_template_sha256=$TEMPLATE_SHA
openxr_runtime=$LIB
openxr_runtime_sha256=$LIB_SHA
openxr_manifest=$MANIFEST
openxr_manifest_sha256=$MANIFEST_SHA
manifest_contract=absolute-path-exact-copied-monado_wivrn-runtime
runtime_export_gate=PASS xrNegotiateLoaderRuntimeInterface
artifact_gate=PASS exact-source-monado-openxr-runtime-plus-absolute-manifest
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid helper metadata SHA256"

printf '[4/4] Helper build gate complete\n'
printf 'OPENXR_HELPER_BUILD=PASS exact-source-monado-runtime-absolute-manifest\nsource_commit=%s\nmonado_rev=%s\nopenxr_runtime_sha256=%s\nopenxr_manifest_sha256=%s\nmetadata_sha256=%s\nopenxr_runtime=%s\nopenxr_manifest=%s\nmetadata=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$MONADO_REV" "$LIB_SHA" "$MANIFEST_SHA" "$META_SHA" "$LIB" "$MANIFEST" "$META"
