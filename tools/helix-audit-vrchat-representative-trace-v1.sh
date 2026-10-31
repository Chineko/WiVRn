#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v1-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v1-seal.txt"
FREEZE_DOC="docs/helix/2026-10-31-live8-burst8-frozen.md"
CONTRACT_DOC="docs/helix/2026-10-31-representative-recovery-contract.md"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk grep sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$META" "$SEAL" "$FREEZE_DOC" "$CONTRACT_DOC" tools/helix-vrchat-workload-model.py server/helix_vrchat_trace.h server/helix_synthetic_transport.cpp; do [[ -s "$f" ]] || fail "missing $f"; done
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }
TRACE="$(getm trace_path)"; SUMMARY="$(getm summary_path)"; [[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace/summary missing"
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"; META_SHA="$(sha256sum "$META"|awk '{print $1}')"
[[ "$TRACE_SHA" =~ ^[0-9a-f]{64}$ && "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash format"
[[ "$(getm trace_sha256)" == "$TRACE_SHA" && "$(gets trace_sha256)" == "$TRACE_SHA" ]] || fail "trace binding mismatch"
[[ "$(gets metadata_sha256)" == "$META_SHA" ]] || fail "metadata seal mismatch"
grep -Fqx 'artifact_seal=PASS vrchat-representative-trace-v1-300s-seed20261031-rtx-zero-clamp-wholefile-sha256' "$SEAL" || fail "seal marker mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$SEAL" || fail "runtime status mismatch"
for kv in 'seed=20261031' 'duration_s=300' 'profile=torture' 'phase=characterization'; do grep -Fqx "$kv" "$META" || fail "metadata mismatch $kv"; done

# Trace-level coverage: both eyes/streams must actually contain modeled path drops.
DROP0="$(awk -F, '$1=="P" && $4==0 && $9=="D"{n++} END{print n+0}' "$TRACE")"
DROP1="$(awk -F, '$1=="P" && $4==1 && $9=="D"{n++} END{print n+0}' "$TRACE")"
[[ "$DROP0" -gt 0 ]] || fail "trace has no modeled drops on stream 0"
[[ "$DROP1" -gt 0 ]] || fail "trace has no modeled drops on stream 1"

grep -Fq 'make_trace_view_info()' server/helix_synthetic_transport.cpp || fail "trace RTX eligibility missing"
grep -Fq 'packet.retransmission = true;' server/helix_synthetic_transport.cpp || fail "trace RTX resend path missing"
grep -Fq 'damaged_recovered' server/helix_synthetic_transport.cpp || fail "recovery-aware oracle missing"
grep -Fq 'clean_failed == 0 && false_complete == 0' server/helix_synthetic_transport.cpp || fail "strict characterization invariants missing"
grep -Fq 'payload_would_clamp' server/helix_synthetic_transport.cpp || fail "zero-clamp runtime gate missing"
grep -Fq 'edge_payload = min(1200, cal["shard_payload"])' tools/helix-vrchat-workload-model.py || fail "edge payload headroom missing"
grep -Fq 'cal["fps"] = 1_000_000.0 / gap_mean_us' tools/helix-vrchat-workload-model.py || fail "cadence calibration fix missing"

# Frozen old lane must remain present but with the corrected evidence classification.
grep -Fq 'RUNTIME=PASS server-side encoded-loss/invalidation stability plus full Vulkan churn completion' "$FREEZE_DOC" || fail "corrected frozen live8 classification missing"
grep -Fq 'DECODER_RECOVERY=NOT_ESTABLISHED' "$FREEZE_DOC" || fail "old decoder recovery limitation missing"
grep -Fq 'RTX_GAP_RECOVERY=NOT_EXERCISED' "$FREEZE_DOC" || fail "old RTX/gap limitation missing"
grep -Fq 'BOTH_EYES_FAULTED=NO' "$FREEZE_DOC" || fail "old eye-coverage limitation missing"
grep -Fq 'HEVC10_RECOVERY=NOT_TESTED' "$FREEZE_DOC" || fail "old codec limitation missing"
grep -Fq 'source_sha256=94228dbab8a63290d3b66671fb3aa1b3845096652e93d719a565e1335a6c4971' "$FREEZE_DOC" || fail "frozen live8 source hash mismatch"
grep -Fq 'binary_sha256=06ef8b3bc28bad788457f1d2c6c036ad5a144aab018240f60f84a8e8929a3a60' "$FREEZE_DOC" || fail "frozen live8 binary hash mismatch"
grep -Fq 'metadata_sha256=7702a3c8c828afb4832c0fb6db758f312a1cc680751e90b59356a6e62154d2a6' "$FREEZE_DOC" || fail "frozen live8 metadata hash mismatch"

# New-lane evidence contract must explicitly keep transport and decoder claims separate.
grep -Fq 'clean_failed=0;' "$CONTRACT_DOC" || fail "contract clean-frame invariant missing"
grep -Fq 'false_complete=0;' "$CONTRACT_DOC" || fail "contract false-complete invariant missing"
grep -Fq 'rtx_requests>0;' "$CONTRACT_DOC" || fail "contract RTX request invariant missing"
grep -Fq 'rtx_retransmissions>0;' "$CONTRACT_DOC" || fail "contract RTX retransmission invariant missing"
grep -Fq 'damaged_recovered>0;' "$CONTRACT_DOC" || fail "contract recovered-frame invariant missing"
grep -Fq 'both eyes/streams' "$CONTRACT_DOC" || fail "contract both-eye coverage missing"
grep -Fq 'HEVC 10-bit' "$CONTRACT_DOC" || fail "contract HEVC10 requirement missing"
grep -Fq 'never `DECODER_RECOVERY`' "$CONTRACT_DOC" || fail "transport/decoder claim separation missing"

printf 'AUDIT_A=PASS representative-trace-sealed-300s-seed20261031-rtx-zero-clamp-wholefile-sha256\n'
printf 'AUDIT_B=PASS corrected-old-lane-plus-both-eye-representative-contract\n'
printf 'trace_drop_stream0=%s\ntrace_drop_stream1=%s\n' "$DROP0" "$DROP1"
printf 'trace_sha256=%s\nmetadata_sha256=%s\nRUNTIME=NOT_RUN\n' "$TRACE_SHA" "$META_SHA"
