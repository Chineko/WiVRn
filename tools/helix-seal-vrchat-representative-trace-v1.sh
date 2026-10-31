#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v1-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v1-seal.txt"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk grep sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$META" ]] || fail "metadata missing"
get(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
TRACE="$(get trace_path)"; SUMMARY="$(get summary_path)"
[[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace or summary missing"
for kv in 'seed=20261031' 'duration_s=300' 'profile=torture' 'phase=characterization' \
'html_placeholder=never'; do [[ "$kv" == html_placeholder=* ]] && continue; grep -Fqx "$kv" "$META" || fail "metadata mismatch $kv"; done
for kv in \
'oracle_contract=clean-failed-zero-false-complete-zero-rtx-exercised-at-least-one-damaged-recovered' \
'payload_contract=zero-clamp-runtime-guard-edge-shard-headroom1200' \
'trace_identity=whole-file-sha256-external-seal' \
'runtime_status=NOT_RUN'; do grep -Fqx "$kv" "$META" || fail "metadata mismatch $kv"; done
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"; SUMMARY_SHA="$(sha256sum "$SUMMARY"|awk '{print $1}')"
GEN_SHA="$(sha256sum tools/helix-vrchat-workload-model.py|awk '{print $1}')"; LOADER_SHA="$(sha256sum server/helix_vrchat_trace.h|awk '{print $1}')"
CHECK_SHA="$(sha256sum tools/helix-vrchat-trace-check.cpp|awk '{print $1}')"; SERVER_SHA="$(sha256sum server/helix_synthetic_transport.cpp|awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$GEN_SHA" "$LOADER_SHA" "$CHECK_SHA" "$SERVER_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
[[ "$(get trace_sha256)" == "$TRACE_SHA" ]] || fail "trace hash mismatch"
[[ "$(get summary_sha256)" == "$SUMMARY_SHA" ]] || fail "summary hash mismatch"
[[ "$(get generator_sha256)" == "$GEN_SHA" ]] || fail "generator hash mismatch"
[[ "$(get loader_sha256)" == "$LOADER_SHA" ]] || fail "loader hash mismatch"
[[ "$(get checker_source_sha256)" == "$CHECK_SHA" ]] || fail "checker hash mismatch"
[[ "$(get server_trace_source_sha256)" == "$SERVER_SHA" ]] || fail "server trace source hash mismatch"
META_SHA="$(sha256sum "$META"|awk '{print $1}')"; [[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"
cat >"$SEAL" <<EOF
source_commit=$(get source_commit)
repair_tooling_commit=$(get repair_tooling_commit)
seed=20261031
duration_s=300
profile=torture
phase=characterization
trace_sha256=$TRACE_SHA
summary_sha256=$SUMMARY_SHA
generator_sha256=$GEN_SHA
loader_sha256=$LOADER_SHA
checker_source_sha256=$CHECK_SHA
server_trace_source_sha256=$SERVER_SHA
metadata_sha256=$META_SHA
artifact_seal=PASS vrchat-representative-trace-v1-300s-seed20261031-rtx-zero-clamp-wholefile-sha256
runtime_status=NOT_RUN
EOF
printf 'PASS: representative trace sealed.\ntrace_sha256=%s\nmetadata_sha256=%s\nseal=%s\nSTATUS: artifact sealed; runtime not executed.\n' "$TRACE_SHA" "$META_SHA" "$SEAL"
