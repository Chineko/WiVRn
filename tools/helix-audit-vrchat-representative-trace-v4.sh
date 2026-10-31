#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-vrchat-representative-torture-v1"
META="$ROOT/vrchat-representative-trace-v4-metadata.txt"
SEAL="$ROOT/vrchat-representative-trace-v4-seal.txt"
FREEZE_DOC="docs/helix/2026-10-31-live8-burst8-frozen.md"
EXPECTED_SOURCE="709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
EXPECTED_SEMANTICS_REPAIR="46cd7e613b53efbb0060cec9442ea105becb98fc"
EXPECTED_PACKETIZER_FIX="eb9ceefe0d7d6945cc32c14a7760c75d0e5b44de"
EXPECTED_BUILD="fdef87889e67891ecb165f88e31028eca42ffbe8"
EXPECTED_SEAL_TOOLING="a8ee7f615b302b5c84ebd8f4898c8018c114f881"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk git grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$EXPECTED_SOURCE" ]] || fail "source commit mismatch expected=$EXPECTED_SOURCE actual=$(git rev-parse HEAD)"
[[ -z "$(git status --short)" ]] || fail "source tree must be clean"
for f in "$META" "$SEAL" "$FREEZE_DOC" tools/helix-vrchat-workload-model.py server/helix_vrchat_trace.h server/helix_synthetic_transport.cpp tools/helix-vrchat-trace-check.cpp common/wivrn_packets.h; do [[ -s "$f" ]] || fail "missing $f"; done
getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }
TRACE="$(getm trace_path)"; SUMMARY="$(getm summary_path)"; [[ -s "$TRACE" && -s "$SUMMARY" ]] || fail "trace/summary missing"

TRACE_SHA="$(sha256sum "$TRACE"|awk '{print $1}')"
SUMMARY_SHA="$(sha256sum "$SUMMARY"|awk '{print $1}')"
GEN_SHA="$(sha256sum tools/helix-vrchat-workload-model.py|awk '{print $1}')"
LOADER_SHA="$(sha256sum server/helix_vrchat_trace.h|awk '{print $1}')"
CHECK_SRC_SHA="$(sha256sum tools/helix-vrchat-trace-check.cpp|awk '{print $1}')"
SERVER_SHA="$(sha256sum server/helix_synthetic_transport.cpp|awk '{print $1}')"
PACKETS_SHA="$(sha256sum common/wivrn_packets.h|awk '{print $1}')"
META_SHA="$(sha256sum "$META"|awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$GEN_SHA" "$LOADER_SHA" "$CHECK_SRC_SHA" "$SERVER_SHA" "$PACKETS_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid lowercase sha256 $h"; done

[[ "$(getm source_commit)" == "$EXPECTED_SOURCE" && "$(gets source_commit)" == "$EXPECTED_SOURCE" ]] || fail "source commit binding mismatch"
[[ "$(getm semantics_repair_tooling_commit)" == "$EXPECTED_SEMANTICS_REPAIR" && "$(gets semantics_repair_tooling_commit)" == "$EXPECTED_SEMANTICS_REPAIR" ]] || fail "semantics repair tooling binding mismatch"
[[ "$(getm packetizer_fix_tooling_commit)" == "$EXPECTED_PACKETIZER_FIX" && "$(gets packetizer_fix_tooling_commit)" == "$EXPECTED_PACKETIZER_FIX" ]] || fail "packetizer fix tooling binding mismatch"
[[ "$(gets build_tooling_commit)" == "$EXPECTED_BUILD" ]] || fail "build tooling binding mismatch"
for triple in \
 "trace_sha256:$TRACE_SHA" \
 "summary_sha256:$SUMMARY_SHA" \
 "generator_sha256:$GEN_SHA" \
 "loader_sha256:$LOADER_SHA" \
 "checker_source_sha256:$CHECK_SRC_SHA" \
 "server_trace_source_sha256:$SERVER_SHA" \
 "protocol_packets_sha256:$PACKETS_SHA"; do
 k="${triple%%:*}"; v="${triple#*:}"
 [[ "$(getm "$k")" == "$v" ]] || fail "metadata $k binding mismatch"
 [[ "$(gets "$k")" == "$v" ]] || fail "seal $k binding mismatch"
done
[[ "$(gets metadata_sha256)" == "$META_SHA" ]] || fail "metadata seal mismatch"

grep -Fqx 'artifact_seal=PASS vrchat-representative-trace-v4-exact-source-300s-seed20261031-botheyes-shard0-rtx-canaries-zero-clamp-no-empty-shards-all-source-hashes' "$SEAL" || fail "seal marker mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$SEAL" || fail "seal runtime status mismatch"
for kv in \
 'seed=20261031' \
 'duration_s=300' \
 'profile=torture' \
 'phase=transport-recovery-characterization' \
 'oracle_contract=clean-failed-zero-false-complete-zero-two-shard0-canaries-recovered-representative-damage-characterized' \
 'payload_contract=zero-clamp-no-empty-shards-reserve-one-byte-per-remaining-declared-shard-edge-headroom1200-protocol-max1400' \
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
grep -Fq 'remaining_shards = nshards - sh - 1' tools/helix-vrchat-workload-model.py || fail "packetizer remaining-shard reserve missing"
grep -Fq 'pb = min(cap_shard, rem - remaining_shards)' tools/helix-vrchat-workload-model.py || fail "packetizer reserve calculation missing"
grep -Fq 'if pb < 1:' tools/helix-vrchat-workload-model.py || fail "empty-shard guard missing"
grep -Fq 'cal["fps"] = 1_000_000.0 / gap_mean_us' tools/helix-vrchat-workload-model.py || fail "cadence calibration fix missing"
grep -Fq 'inline static const size_t max_payload_size = 1400;' common/wivrn_packets.h || fail "protocol max payload no longer 1400"
grep -Fq '.max_shard_payload = 1400,' tools/helix-vrchat-trace-check.cpp || fail "standalone checker payload mismatch"

read -r DROP0 DROP1 C0 C1 ZERO < <(python3 - "$TRACE" "$SUMMARY" <<'PY'
import json, sys
from collections import Counter, defaultdict
trace, summary = sys.argv[1:]
stream = Counter(); frames = defaultdict(list); zero=0
with open(trace) as f:
    for lineno,line in enumerate(f,1):
        if line.startswith('#') or not line.strip():
            continue
        a=line.rstrip().split(',')
        if len(a)!=9 or a[0] != 'P':
            raise SystemExit(f'FAIL: malformed trace row line={lineno}')
        if int(a[7]) < 1:
            zero += 1
        if a[8]=='D':
            s,fr,sh=int(a[3]),int(a[4]),int(a[5]); stream[s]+=1; frames[(s,fr)].append(sh)
canaries=sorted((s,fr) for (s,fr),v in frames.items() if v==[0])
if zero:
    raise SystemExit(f'FAIL: zero-byte shards present count={zero}')
if stream[0] <= 0 or stream[1] <= 0:
    raise SystemExit(f'FAIL: both-eye representative drops missing {dict(stream)}')
if len(canaries)!=2 or {s for s,_ in canaries}!={0,1}:
    raise SystemExit(f'FAIL: canary set mismatch {canaries}')
with open(summary) as f: j=json.load(f)
reported={int(k):int(v) for k,v in j.get('rtx_canary_frames',{}).items()}
if reported != dict(canaries):
    raise SystemExit(f'FAIL: summary canary mismatch {reported} vs {dict(canaries)}')
print(stream[0], stream[1], reported[0], reported[1], zero)
PY
)
[[ "$ZERO" == 0 ]] || fail "zero-byte shard count nonzero"
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

printf 'AUDIT_A=PASS representative-trace-v4-exact-source-all-source-hashes-no-empty-shards-botheyes-shard0-rtx-canaries-zero-clamp\n'
printf 'AUDIT_B=PASS corrected-old-lane-plus-both-eye-representative-transport-contract\n'
printf 'source_commit=%s\nbuild_tooling_commit=%s\nseal_tooling_commit=%s\n' "$EXPECTED_SOURCE" "$EXPECTED_BUILD" "$EXPECTED_SEAL_TOOLING"
printf 'trace_drop_stream0=%s trace_drop_stream1=%s zero_payload_shards=%s\n' "$DROP0" "$DROP1" "$ZERO"
printf 'rtx_canary_stream0_frame=%s rtx_canary_stream1_frame=%s\n' "$C0" "$C1"
printf 'trace_sha256=%s\nmetadata_sha256=%s\nRUNTIME=NOT_RUN\n' "$TRACE_SHA" "$META_SHA"
