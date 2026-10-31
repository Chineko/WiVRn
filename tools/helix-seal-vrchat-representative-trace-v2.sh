#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v2-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v2-seal.txt"
EXPECTED_REPAIR="46cd7e613b53efbb0060cec9442ea105becb98fc"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$META" ]] || fail "metadata missing"
get(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
TRACE="$(get trace_path)"; SUMMARY="$(get summary_path)"
[[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace or summary missing"
[[ "$(get repair_tooling_commit)" == "$EXPECTED_REPAIR" ]] || fail "repair tooling binding mismatch"
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
C0="$(get rtx_canary_stream0_frame)"; C1="$(get rtx_canary_stream1_frame)"
[[ "$C0" =~ ^[0-9]+$ && "$C1" =~ ^[0-9]+$ ]] || fail "invalid canary frame binding"
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"; SUMMARY_SHA="$(sha256sum "$SUMMARY"|awk '{print $1}')"; META_SHA="$(sha256sum "$META"|awk '{print $1}')"
for pair in "trace_sha256:$TRACE_SHA" "summary_sha256:$SUMMARY_SHA"; do k="${pair%%:*}"; v="${pair#*:}"; [[ "$(get "$k")" == "$v" ]] || fail "$k binding mismatch"; done
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
cat >"$SEAL" <<EOF
source_commit=$(get source_commit)
repair_tooling_commit=$EXPECTED_REPAIR
seed=20261031
duration_s=300
profile=torture
phase=transport-recovery-characterization
rtx_canary_stream0_frame=$C0
rtx_canary_stream1_frame=$C1
trace_sha256=$TRACE_SHA
summary_sha256=$SUMMARY_SHA
generator_sha256=$(get generator_sha256)
loader_sha256=$(get loader_sha256)
checker_source_sha256=$(get checker_source_sha256)
server_trace_source_sha256=$(get server_trace_source_sha256)
protocol_packets_sha256=$(get protocol_packets_sha256)
metadata_sha256=$META_SHA
oracle_contract=clean-failed-zero-false-complete-zero-two-shard0-canaries-recovered-representative-damage-characterized
claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established
artifact_seal=PASS vrchat-representative-trace-v2-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-wholefile-sha256
runtime_status=NOT_RUN
EOF
printf 'PASS: representative trace v2 sealed.\nrepair_tooling_commit=%s\ntrace_sha256=%s\nmetadata_sha256=%s\ncanary_stream0_frame=%s canary_stream1_frame=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' "$EXPECTED_REPAIR" "$TRACE_SHA" "$META_SHA" "$C0" "$C1" "$SEAL"
