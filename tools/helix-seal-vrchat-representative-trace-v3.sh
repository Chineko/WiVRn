#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v3-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v3-seal.txt"
EXPECTED_SOURCE="1588af7b63783af04843038b3362a0dbd62eda4a"
EXPECTED_REPAIR="46cd7e613b53efbb0060cec9442ea105becb98fc"
BUILD_TOOLING_COMMIT="78bd922a5de461ccc5eb57c94a69504912d11f81"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk git grep sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$EXPECTED_SOURCE" ]] || fail "source commit mismatch"
[[ -z "$(git status --short)" ]] || fail "source tree must be clean"
[[ -s "$META" ]] || fail "metadata missing"
get(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
[[ "$(get source_commit)" == "$EXPECTED_SOURCE" ]] || fail "metadata source commit mismatch"
[[ "$(get repair_tooling_commit)" == "$EXPECTED_REPAIR" ]] || fail "repair tooling binding mismatch"
TRACE="$(get trace_path)"; SUMMARY="$(get summary_path)"
[[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace or summary missing"
for kv in \
 'seed=20261031' \
 'duration_s=300' \
 'profile=torture' \
 'phase=transport-recovery-characterization' \
 'oracle_contract=clean-failed-zero-false-complete-zero-two-shard0-canaries-recovered-representative-damage-characterized' \
 'payload_contract=zero-clamp-runtime-guard-edge-shard-headroom1200-protocol-max1400-bound' \
 'trace_identity=whole-file-sha256-external-seal' \
 'claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established' \
 'runtime_status=NOT_RUN'; do grep -Fqx "$kv" "$META" || fail "metadata mismatch $kv"; done

TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"
SUMMARY_SHA="$(sha256sum "$SUMMARY"|awk '{print $1}')"
GEN_SHA="$(sha256sum tools/helix-vrchat-workload-model.py|awk '{print $1}')"
LOADER_SHA="$(sha256sum server/helix_vrchat_trace.h|awk '{print $1}')"
CHECK_SRC_SHA="$(sha256sum tools/helix-vrchat-trace-check.cpp|awk '{print $1}')"
SERVER_SHA="$(sha256sum server/helix_synthetic_transport.cpp|awk '{print $1}')"
PACKETS_SHA="$(sha256sum common/wivrn_packets.h|awk '{print $1}')"
META_SHA="$(sha256sum "$META"|awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$GEN_SHA" "$LOADER_SHA" "$CHECK_SRC_SHA" "$SERVER_SHA" "$PACKETS_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
for pair in \
 "trace_sha256:$TRACE_SHA" \
 "summary_sha256:$SUMMARY_SHA" \
 "generator_sha256:$GEN_SHA" \
 "loader_sha256:$LOADER_SHA" \
 "checker_source_sha256:$CHECK_SRC_SHA" \
 "server_trace_source_sha256:$SERVER_SHA" \
 "protocol_packets_sha256:$PACKETS_SHA"; do
 k="${pair%%:*}"; v="${pair#*:}"; [[ "$(get "$k")" == "$v" ]] || fail "$k binding mismatch";
done

C0="$(get rtx_canary_stream0_frame)"; C1="$(get rtx_canary_stream1_frame)"
[[ "$C0" =~ ^[0-9]+$ && "$C1" =~ ^[0-9]+$ ]] || fail "invalid canary frame binding"

cat >"$SEAL" <<EOF
source_commit=$EXPECTED_SOURCE
repair_tooling_commit=$EXPECTED_REPAIR
build_tooling_commit=$BUILD_TOOLING_COMMIT
seed=20261031
duration_s=300
profile=torture
phase=transport-recovery-characterization
rtx_canary_stream0_frame=$C0
rtx_canary_stream1_frame=$C1
trace_sha256=$TRACE_SHA
summary_sha256=$SUMMARY_SHA
generator_sha256=$GEN_SHA
loader_sha256=$LOADER_SHA
checker_source_sha256=$CHECK_SRC_SHA
server_trace_source_sha256=$SERVER_SHA
protocol_packets_sha256=$PACKETS_SHA
metadata_sha256=$META_SHA
oracle_contract=clean-failed-zero-false-complete-zero-two-shard0-canaries-recovered-representative-damage-characterized
payload_contract=zero-clamp-runtime-guard-edge-shard-headroom1200-protocol-max1400-bound
claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established
artifact_seal=PASS vrchat-representative-trace-v3-exact-source-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-all-source-hashes
runtime_status=NOT_RUN
EOF
printf 'PASS: representative trace v3 sealed.\nsource_commit=%s\nbuild_tooling_commit=%s\ntrace_sha256=%s\nmetadata_sha256=%s\ncanary_stream0_frame=%s canary_stream1_frame=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' "$EXPECTED_SOURCE" "$BUILD_TOOLING_COMMIT" "$TRACE_SHA" "$META_SHA" "$C0" "$C1" "$SEAL"
