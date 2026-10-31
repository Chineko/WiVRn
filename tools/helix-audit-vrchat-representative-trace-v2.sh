#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v2-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v2-seal.txt"
FREEZE_DOC="docs/helix/2026-10-31-live8-burst8-frozen.md"
EXPECTED_REPAIR="46cd7e613b53efbb0060cec9442ea105becb98fc"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$META" "$SEAL" "$FREEZE_DOC" tools/helix-vrchat-workload-model.py server/helix_vrchat_trace.h server/helix_synthetic_transport.cpp tools/helix-vrchat-trace-check.cpp common/wivrn_packets.h; do [[ -s "$f" ]] || fail "missing $f"; done
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }
TRACE="$(getm trace_path)"; SUMMARY="$(getm summary_path)"; [[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace/summary missing"
TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"; SUMMARY_SHA="$(sha256sum "$SUMMARY"|awk '{print $1}')"; META_SHA="$(sha256sum "$META"|awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
[[ "$(getm trace_sha256)" == "$TRACE_SHA" && "$(gets trace_sha256)" == "$TRACE_SHA" ]] || fail "trace binding mismatch"
[[ "$(getm summary_sha256)" == "$SUMMARY_SHA" && "$(gets summary_sha256)" == "$SUMMARY_SHA" ]] || fail "summary binding mismatch"
[[ "$(gets metadata_sha256)" == "$META_SHA" ]] || fail "metadata seal mismatch"
[[ "$(getm repair_tooling_commit)" == "$EXPECTED_REPAIR" && "$(gets repair_tooling_commit)" == "$EXPECTED_REPAIR" ]] || fail "repair tooling binding mismatch"
grep -Fqx 'artifact_seal=PASS vrchat-representative-trace-v2-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-wholefile-sha256' "$SEAL" || fail "seal marker mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$SEAL" || fail "runtime status mismatch"
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

grep -Fq 'rtx_canary_candidates == 2' server/helix_synthetic_transport.cpp || fail "two-canary gate missing"
grep -Fq 'rtx_canary_recovered == 2' server/helix_synthetic_transport.cpp || fail "canary recovery gate missing"
grep -Fq 'packet.retransmission = retransmission;' server/helix_synthetic_transport.cpp || fail "retransmission send path missing"
grep -Fq 'dropped_packets[{row.stream, seq}] = row;' server/helix_synthetic_transport.cpp || fail "dropped sequence cache missing"
grep -Fq 'payload_would_clamp' server/helix_synthetic_transport.cpp || fail "zero-clamp runtime gate missing"
! grep -Fq 'trace_false_incomplete_budget' server/helix_synthetic_transport.cpp || fail "stale 0.5 percent runtime budget remains"
grep -Fq 'rtx_canary_frames = {}' tools/helix-vrchat-workload-model.py || fail "generator canary insertion missing"
grep -Fq 'edge_payload = min(1200, cal["shard_payload"])' tools/helix-vrchat-workload-model.py || fail "edge payload headroom missing"
grep -Fq 'cal["fps"] = 1_000_000.0 / gap_mean_us' tools/helix-vrchat-workload-model.py || fail "cadence calibration fix missing"
grep -Fq 'inline static const size_t max_payload_size = 1400;' common/wivrn_packets.h || fail "protocol max payload no longer 1400"
grep -Fq '.max_shard_payload = 1400,' tools/helix-vrchat-trace-check.cpp || fail "standalone checker payload mismatch"

read -r DROP0 DROP1 C0 C1 < <(python3 - "$TRACE" "$SUMMARY" <<'PY'
import json, sys
from collections import Counter, defaultdict
trace, summary = sys.argv[1:]
stream = Counter(); frames = defaultdict(list)
with open(trace) as f:
    for line in f:
        if line.startswith('#') or not line.strip():
            continue
        a=line.rstrip().split(',')
        if len(a)!=9 or a[0] != 'P':
            raise SystemExit('FAIL: malformed trace row')
        if a[8]=='D':
            s,fr,sh=int(a[3]),int(a[4]),int(a[5]); stream[s]+=1; frames[(s,fr)].append(sh)
canaries=sorted((s,fr) for (s,fr),v in frames.items() if v==[0])
if stream[0] <= 0 or stream[1] <= 0:
    raise SystemExit(f'FAIL: both-eye representative drops missing {dict(stream)}')
if len(canaries)!=2 or {s for s,_ in canaries}!={0,1}:
    raise SystemExit(f'FAIL: canary set mismatch {canaries}')
with open(summary) as f: j=json.load(f)
reported={int(k):int(v) for k,v in j.get('rtx_canary_frames',{}).items()}
if reported != dict(canaries):
    raise SystemExit(f'FAIL: summary canary mismatch {reported} vs {dict(canaries)}')
print(stream[0], stream[1], reported[0], reported[1])
PY
)
[[ "$(getm rtx_canary_stream0_frame)" == "$C0" && "$(gets rtx_canary_stream0_frame)" == "$C0" ]] || fail "stream0 canary binding mismatch"
[[ "$(getm rtx_canary_stream1_frame)" == "$C1" && "$(gets rtx_canary_stream1_frame)" == "$C1" ]] || fail "stream1 canary binding mismatch"

grep -Fq 'RUNTIME=PASS server-side encoded-loss/invalidation stability plus full Vulkan churn completion' "$FREEZE_DOC" || fail "corrected old runtime classification missing"
grep -Fq 'DECODER_RECOVERY=NOT_ESTABLISHED' "$FREEZE_DOC" || fail "old decoder limitation missing"
grep -Fq 'RTX_GAP_RECOVERY=NOT_EXERCISED' "$FREEZE_DOC" || fail "old RTX limitation missing"
grep -Fq 'BOTH_EYES_FAULTED=NO' "$FREEZE_DOC" || fail "old one-eye limitation missing"
grep -Fq 'HEVC10_RECOVERY=NOT_TESTED' "$FREEZE_DOC" || fail "old codec limitation missing"
grep -Fq 'source_sha256=94228dbab8a63290d3b66671fb3aa1b3845096652e93d719a565e1335a6c4971' "$FREEZE_DOC" || fail "frozen source hash mismatch"
grep -Fq 'binary_sha256=06ef8b3bc28bad788457f1d2c6c036ad5a144aab018240f60f84a8e8929a3a60' "$FREEZE_DOC" || fail "frozen binary hash mismatch"
grep -Fq 'metadata_sha256=7702a3c8c828afb4832c0fb6db758f312a1cc680751e90b59356a6e62154d2a6' "$FREEZE_DOC" || fail "frozen metadata hash mismatch"

printf 'AUDIT_A=PASS representative-trace-v2-sealed-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp\n'
printf 'AUDIT_B=PASS corrected-old-lane-plus-both-eye-representative-transport-contract\n'
printf 'trace_drop_stream0=%s trace_drop_stream1=%s\n' "$DROP0" "$DROP1"
printf 'rtx_canary_stream0_frame=%s rtx_canary_stream1_frame=%s\n' "$C0" "$C1"
printf 'trace_sha256=%s\nmetadata_sha256=%s\nRUNTIME=NOT_RUN\n' "$TRACE_SHA" "$META_SHA"
