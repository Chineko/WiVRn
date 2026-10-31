#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
TRACE_ROOT="$HOME/helix-vrchat-representative-torture-v1"
TRACE="$TRACE_ROOT/vrchat-torture-300s-seed20261031.trace"
TRACE_META="$TRACE_ROOT/vrchat-representative-trace-v4-metadata.txt"
TRACE_SEAL="$TRACE_ROOT/vrchat-representative-trace-v4-seal.txt"
TRACE_SHA256="9c233a73d119109a141f9ce961b93725e7b93700f45f19071bf4f57c54f57138"
TRACE_META_SHA256="dd36e22d4284a495c66d1ab4a250e63cdb37abd6e4dd578ac71a3e91042eb232"
OUT="$HOME/helix-vrchat-representative-runtime-v1"
VERSION_NAME="helix-vrchat-representative-v1-${SOURCE_COMMIT}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git cmake ninja ar nm realpath grep find java sha256sum awk rsvg-convert; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "caller source mismatch"
[[ -z "$(git status --short)" ]] || fail "caller source tree dirty"
git cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null || fail "source commit unavailable locally"
[[ ! -e "$OUT" ]] || fail "runtime build root already exists: $OUT"
[[ -s "$TRACE" && -s "$TRACE_META" && -s "$TRACE_SEAL" ]] || fail "sealed trace artifacts missing"
[[ "$(sha256sum "$TRACE"|awk '{print $1}')" == "$TRACE_SHA256" ]] || fail "trace hash mismatch"
[[ "$(sha256sum "$TRACE_META"|awk '{print $1}')" == "$TRACE_META_SHA256" ]] || fail "trace metadata hash mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$TRACE_SEAL" || fail "trace seal source mismatch"
grep -Fqx "trace_sha256=$TRACE_SHA256" "$TRACE_SEAL" || fail "trace seal hash mismatch"
grep -Fqx "metadata_sha256=$TRACE_META_SHA256" "$TRACE_SEAL" || fail "trace metadata seal mismatch"
grep -Fqx 'artifact_seal=PASS vrchat-representative-trace-v4-exact-source-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-no-empty-shards-all-source-hashes' "$TRACE_SEAL" || fail "trace seal marker mismatch"

mkdir -p "$OUT"
WORKTREE="$OUT/worktree"
git worktree add --detach "$WORKTREE" "$SOURCE_COMMIT" >/dev/null
cd "$WORKTREE"
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "isolated source mismatch"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source dirty"

# Bind the runtime source to the sealed trace contract before compiling.
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$TRACE_META" | tail -1; }
[[ "$(sha256sum server/helix_synthetic_transport.cpp|awk '{print $1}')" == "$(getm server_trace_source_sha256)" ]] || fail "server trace source differs from sealed trace metadata"
[[ "$(sha256sum common/wivrn_packets.h|awk '{print $1}')" == "$(getm protocol_packets_sha256)" ]] || fail "protocol source differs from sealed trace metadata"
grep -Fq 'rtx_canary_candidates == 2' server/helix_synthetic_transport.cpp || fail "runtime canary gate missing"
grep -Fq 'rtx_canary_recovered == 2' server/helix_synthetic_transport.cpp || fail "runtime recovery gate missing"
grep -Fq 'payload_would_clamp' server/helix_synthetic_transport.cpp || fail "zero-clamp gate missing"
grep -Fq 'HELIX_SYNTHETIC_TRACE' server/helix_synthetic_transport.cpp || fail "trace selector missing"
grep -Fq -- '--helix-synthetic-transport' server/main.cpp || fail "synthetic transport CLI missing"
grep -Fq 'helix_synthetic_transport.cpp' server/CMakeLists.txt || fail "synthetic source absent from server target"

printf 'source_commit=%s\nversion_name=%s\ntrace_sha256=%s\ntrace_metadata_sha256=%s\n' \
  "$SOURCE_COMMIT" "$VERSION_NAME" "$TRACE_SHA256" "$TRACE_META_SHA256" > "$OUT/metadata.txt"

printf '[1/4] Building exact committed wivrn-server\n'
cmake --preset server 2>&1 | tee "$OUT/configure-server.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "$OUT/build-server.txt"
status=${PIPESTATUS[0]}
set -e
(( status == 0 )) || exit "$status"

grep -Fq "const char git_commit[] = \"${SOURCE_COMMIT}\";" build-server/version.cpp || fail "generated version provenance mismatch"
ninja -C build-server -t query server/wivrn-server > "$OUT/ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "$OUT/ninja-query.txt" || fail "server graph lacks synthetic transport object"
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "$common_archive" && -s "$common_archive" ]] || fail "common-base archive missing"
ar t "$common_archive" | grep -Fq 'version.cpp.o' || fail "common-base lacks version object"
nm -C "$common_archive" | grep -Fq 'wivrn::display_version()' || fail "display_version symbol missing"
server_src="$(realpath build-server/server/wivrn-server)"
[[ -s "$server_src" && -x "$server_src" ]] || fail "built server missing"
SERVER="$OUT/wivrn-server-representative-v1"
cp -- "$server_src" "$SERVER"
chmod +x "$SERVER"

printf '[2/4] Building exact matching Quest APK\n'
./gradlew --no-daemon assembleDebug \
  -Pwivrn_version="$VERSION_NAME" \
  -Pwivrn_app_name="Helix VRChat Representative" \
  2>&1 | tee "$OUT/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || fail "expected exactly one debug APK, found ${#apks[@]}"
APK="$OUT/helix-vrchat-representative-${SOURCE_COMMIT:0:12}.apk"
cp -- "$(realpath "${apks[0]}")" "$APK"
[[ -s "$APK" ]] || fail "APK missing"

printf '[3/4] Hashing artifacts and rechecking source provenance\n'
SERVER_SHA="$(sha256sum "$SERVER"|awk '{print $1}')"
APK_SHA="$(sha256sum "$APK"|awk '{print $1}')"
for h in "$SERVER_SHA" "$APK_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid artifact hash $h"; done
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "source HEAD changed during build"
[[ -z "$(git status --porcelain)" ]] || { git status --short >&2; fail "source tree changed during build"; }

cat >> "$OUT/metadata.txt" <<EOF
server=$SERVER
server_sha256=$SERVER_SHA
apk=$APK
apk_sha256=$APK_SHA
server_provenance=PASS generated-version-and-build-graph
artifact_gate=PASS representative-v1-exact-source-server-apk-trace-bound
runtime_status=NOT_RUN
EOF

printf '[4/4] Build gate complete\n'
printf 'BUILD_GATE=PASS representative-v1-exact-source-server-apk-trace-bound\nsource_commit=%s\nserver_sha256=%s\napk_sha256=%s\nserver=%s\napk=%s\nevidence=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$SERVER_SHA" "$APK_SHA" "$SERVER" "$APK" "$OUT"
