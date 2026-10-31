#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
BUILD_TOOLING_COMMIT="0960d6451b1c903a7a3bc8c673cd9b42963b69a8"
SEAL_TOOLING_COMMIT="ee8aead20c57f259803ea779335546fd37a4e5ed"
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
for c in awk git grep sha256sum ninja; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "caller source mismatch"
[[ -z "$(git status --short)" ]] || fail "caller source tree dirty"
for f in "$META" "$SEAL" "$TRACE" "$TRACE_META" "$TRACE_SEAL"; do [[ -s "$f" ]] || fail "missing $f"; done
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }

[[ "$(getm source_commit)" == "$SOURCE_COMMIT" && "$(gets source_commit)" == "$SOURCE_COMMIT" ]] || fail "source binding mismatch"
[[ "$(gets build_tooling_commit)" == "$BUILD_TOOLING_COMMIT" ]] || fail "build tooling binding mismatch"
grep -Fqx 'artifact_gate=PASS representative-v1-exact-source-server-apk-trace-bound' "$META" || fail "build gate marker missing"
grep -Fqx 'artifact_seal=PASS vrchat-representative-runtime-v1-exact-source-server-apk-trace-v4-bound' "$SEAL" || fail "runtime seal marker missing"
grep -Fqx 'claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established' "$SEAL" || fail "claim boundary mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$META" || fail "metadata runtime status mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$SEAL" || fail "seal runtime status mismatch"

SERVER="$(getm server)"; APK="$(getm apk)"
[[ -s "$SERVER" && -x "$SERVER" && -s "$APK" ]] || fail "built artifacts missing"
SERVER_SHA="$(sha256sum "$SERVER"|awk '{print $1}')"
APK_SHA="$(sha256sum "$APK"|awk '{print $1}')"
META_SHA="$(sha256sum "$META"|awk '{print $1}')"
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"
TRACE_META_SHA="$(sha256sum "$TRACE_META"|awk '{print $1}')"
for h in "$SERVER_SHA" "$APK_SHA" "$META_SHA" "$TRACE_SHA" "$TRACE_META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid lowercase sha256 $h"; done
[[ "$SERVER_SHA" == "$(getm server_sha256)" && "$SERVER_SHA" == "$(gets server_sha256)" ]] || fail "server hash binding mismatch"
[[ "$APK_SHA" == "$(getm apk_sha256)" && "$APK_SHA" == "$(gets apk_sha256)" ]] || fail "APK hash binding mismatch"
[[ "$META_SHA" == "$(gets runtime_metadata_sha256)" ]] || fail "runtime metadata seal mismatch"
[[ "$TRACE_SHA" == "$TRACE_SHA256" && "$TRACE_SHA" == "$(getm trace_sha256)" && "$TRACE_SHA" == "$(gets trace_sha256)" ]] || fail "trace hash binding mismatch"
[[ "$TRACE_META_SHA" == "$TRACE_META_SHA256" && "$TRACE_META_SHA" == "$(getm trace_metadata_sha256)" && "$TRACE_META_SHA" == "$(gets trace_metadata_sha256)" ]] || fail "trace metadata binding mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$TRACE_SEAL" || fail "trace source binding mismatch"
grep -Fqx "trace_sha256=$TRACE_SHA256" "$TRACE_SEAL" || fail "trace seal hash mismatch"
grep -Fqx "metadata_sha256=$TRACE_META_SHA256" "$TRACE_SEAL" || fail "trace seal metadata mismatch"
grep -Fqx 'artifact_seal=PASS vrchat-representative-trace-v4-exact-source-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-no-empty-shards-all-source-hashes' "$TRACE_SEAL" || fail "trace seal marker mismatch"

WORKTREE="$ROOT/worktree"
[[ -e "$WORKTREE/.git" ]] || fail "build worktree missing"
[[ "$(git -C "$WORKTREE" rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "build worktree source mismatch"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || fail "build worktree dirty"
grep -Fq "const char git_commit[] = \"${SOURCE_COMMIT}\";" "$WORKTREE/build-server/version.cpp" || fail "generated version mismatch"
ninja -C "$WORKTREE/build-server" -t query server/wivrn-server > "$ROOT/audit-ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "$ROOT/audit-ninja-query.txt" || fail "server final graph lacks synthetic transport object"

# Rebind the exact compiled source to the exact sealed trace source hashes.
gettm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$TRACE_META" | tail -1; }
SERVER_SOURCE_SHA="$(sha256sum "$WORKTREE/server/helix_synthetic_transport.cpp"|awk '{print $1}')"
PACKETS_SOURCE_SHA="$(sha256sum "$WORKTREE/common/wivrn_packets.h"|awk '{print $1}')"
[[ "$SERVER_SOURCE_SHA" == "$(gettm server_trace_source_sha256)" ]] || fail "compiled server trace source not trace-bound"
[[ "$PACKETS_SOURCE_SHA" == "$(gettm protocol_packets_sha256)" ]] || fail "compiled protocol source not trace-bound"

grep -Fq 'rtx_canary_candidates == 2' "$WORKTREE/server/helix_synthetic_transport.cpp" || fail "two-canary runtime gate missing"
grep -Fq 'rtx_canary_recovered == 2' "$WORKTREE/server/helix_synthetic_transport.cpp" || fail "canary recovery gate missing"
grep -Fq 'payload_would_clamp' "$WORKTREE/server/helix_synthetic_transport.cpp" || fail "zero-clamp gate missing"
grep -Fq 'HELIX_SYNTHETIC_TRACE' "$WORKTREE/server/helix_synthetic_transport.cpp" || fail "trace selector missing"

printf 'AUDIT_A=PASS representative-runtime-v1-exact-source-server-apk-trace-v4-all-hashes\n'
printf 'AUDIT_B=PASS build-graph-plus-trace-source-binding-plus-runtime-contract\n'
printf 'source_commit=%s\nbuild_tooling_commit=%s\nseal_tooling_commit=%s\n' "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$SEAL_TOOLING_COMMIT"
printf 'server_sha256=%s\napk_sha256=%s\ntrace_sha256=%s\ntrace_metadata_sha256=%s\n' "$SERVER_SHA" "$APK_SHA" "$TRACE_SHA" "$TRACE_META_SHA"
printf 'RUNTIME=NOT_RUN\n'
