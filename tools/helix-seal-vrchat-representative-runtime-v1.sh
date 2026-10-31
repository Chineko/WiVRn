#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
BUILD_TOOLING_COMMIT="0960d6451b1c903a7a3bc8c673cd9b42963b69a8"
TRACE_SHA256="9c233a73d119109a141f9ce961b93725e7b93700f45f19071bf4f57c54f57138"
TRACE_META_SHA256="dd36e22d4284a495c66d1ab4a250e63cdb37abd6e4dd578ac71a3e91042eb232"
ROOT="$HOME/helix-vrchat-representative-runtime-v1"
META="$ROOT/metadata.txt"
SEAL="$ROOT/runtime-v1-seal.txt"
TRACE_ROOT="$HOME/helix-vrchat-representative-torture-v1"
TRACE="$TRACE_ROOT/vrchat-torture-300s-seed20261031.trace"
TRACE_META="$TRACE_ROOT/vrchat-representative-trace-v4-metadata.txt"
TRACE_SEAL="$TRACE_ROOT/vrchat-representative-trace-v4-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk git grep sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "caller source mismatch"
[[ -z "$(git status --short)" ]] || fail "caller source tree dirty"
[[ -s "$META" && -s "$TRACE" && -s "$TRACE_META" && -s "$TRACE_SEAL" ]] || fail "required metadata/trace artifacts missing"
get(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
[[ "$(get source_commit)" == "$SOURCE_COMMIT" ]] || fail "runtime metadata source mismatch"
[[ "$(get trace_sha256)" == "$TRACE_SHA256" ]] || fail "runtime metadata trace mismatch"
[[ "$(get trace_metadata_sha256)" == "$TRACE_META_SHA256" ]] || fail "runtime metadata trace metadata mismatch"
grep -Fqx 'artifact_gate=PASS representative-v1-exact-source-server-apk-trace-bound' "$META" || fail "build artifact gate missing"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "runtime metadata status mismatch"

SERVER="$(get server)"; APK="$(get apk)"
[[ -s "$SERVER" && -x "$SERVER" && -s "$APK" ]] || fail "server/APK artifact missing"
SERVER_SHA="$(sha256sum "$SERVER"|awk '{print $1}')"
APK_SHA="$(sha256sum "$APK"|awk '{print $1}')"
META_SHA="$(sha256sum "$META"|awk '{print $1}')"
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"
TRACE_META_SHA="$(sha256sum "$TRACE_META"|awk '{print $1}')"
for h in "$SERVER_SHA" "$APK_SHA" "$META_SHA" "$TRACE_SHA" "$TRACE_META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid sha256 $h"; done
[[ "$SERVER_SHA" == "$(get server_sha256)" ]] || fail "server metadata hash mismatch"
[[ "$APK_SHA" == "$(get apk_sha256)" ]] || fail "APK metadata hash mismatch"
[[ "$TRACE_SHA" == "$TRACE_SHA256" ]] || fail "sealed trace drift"
[[ "$TRACE_META_SHA" == "$TRACE_META_SHA256" ]] || fail "sealed trace metadata drift"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$TRACE_SEAL" || fail "trace seal source mismatch"
grep -Fqx "trace_sha256=$TRACE_SHA256" "$TRACE_SEAL" || fail "trace seal hash mismatch"
grep -Fqx "metadata_sha256=$TRACE_META_SHA256" "$TRACE_SEAL" || fail "trace seal metadata mismatch"

WORKTREE="$ROOT/worktree"
[[ -d "$WORKTREE/.git" || -f "$WORKTREE/.git" ]] || fail "isolated build worktree missing"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "build worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || fail "build worktree dirty"
grep -Fq "const char git_commit[] = \"${SOURCE_COMMIT}\";" "$WORKTREE/build-server/version.cpp" || fail "compiled version source mismatch"

cat > "$SEAL" <<EOF
source_commit=$SOURCE_COMMIT
build_tooling_commit=$BUILD_TOOLING_COMMIT
trace_sha256=$TRACE_SHA
trace_metadata_sha256=$TRACE_META_SHA
server=$SERVER
server_sha256=$SERVER_SHA
apk=$APK
apk_sha256=$APK_SHA
runtime_metadata_sha256=$META_SHA
version_name=$(get version_name)
artifact_seal=PASS vrchat-representative-runtime-v1-exact-source-server-apk-trace-v4-bound
claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established
runtime_status=NOT_RUN
EOF

printf 'SEAL_GATE=PASS vrchat-representative-runtime-v1-exact-source-server-apk-trace-v4-bound\nsource_commit=%s\nbuild_tooling_commit=%s\nserver_sha256=%s\napk_sha256=%s\nruntime_metadata_sha256=%s\nseal=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$SERVER_SHA" "$APK_SHA" "$META_SHA" "$SEAL"
