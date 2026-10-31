#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-vrchat-representative-torture-v1"
TRACE="$ROOT/vrchat-torture-300s-seed20261031.trace"
SUMMARY="$ROOT/vrchat-torture-300s-seed20261031-summary.json"
CHECKER="$ROOT/helix-vrchat-trace-check"
META="$ROOT/vrchat-representative-trace-v3-metadata.txt"
SEED=20261031
DURATION=300
PROFILE=torture
EXPECTED_SOURCE_COMMIT="1588af7b63783af04843038b3362a0dbd62eda4a"
REPAIR_TOOLING_COMMIT="46cd7e613b53efbb0060cec9442ea105becb98fc"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in c++ git grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse HEAD)" == "$EXPECTED_SOURCE_COMMIT" ]] || fail "source commit mismatch expected=$EXPECTED_SOURCE_COMMIT actual=$(git rev-parse HEAD)"
[[ -z "$(git status --short)" ]] || fail "source tree must be clean before artifact build"
for f in tools/helix-vrchat-workload-model.py tools/helix-vrchat-trace-check.cpp server/helix_vrchat_trace.h server/helix_synthetic_transport.cpp common/wivrn_packets.h; do [[ -s "$f" ]] || fail "missing repaired source $f"; done

grep -Fq 'rtx_canary_candidates == 2' server/helix_synthetic_transport.cpp || fail "two-canary runtime gate missing"
grep -Fq 'rtx_canary_recovered == 2' server/helix_synthetic_transport.cpp || fail "two-canary recovery gate missing"
grep -Fq 'packet.retransmission = retransmission;' server/helix_synthetic_transport.cpp || fail "RTX retransmission path missing"
grep -Fq 'payload_would_clamp' server/helix_synthetic_transport.cpp || fail "zero-clamp runtime gate missing"
! grep -Fq 'trace_false_incomplete_budget' server/helix_synthetic_transport.cpp || fail "stale 0.5 percent runtime budget remains"
grep -Fq 'rtx_canary_frames = {}' tools/helix-vrchat-workload-model.py || fail "generator canary block missing"
grep -Fq 'edge_payload = min(1200, cal["shard_payload"])' tools/helix-vrchat-workload-model.py || fail "edge payload headroom missing"
grep -Fq 'cal["fps"] = 1_000_000.0 / gap_mean_us' tools/helix-vrchat-workload-model.py || fail "cadence calibration fix missing"
grep -Fq 'inline static const size_t max_payload_size = 1400;' common/wivrn_packets.h || fail "protocol max payload is no longer audited 1400"
grep -Fq '.max_shard_payload = 1400,' tools/helix-vrchat-trace-check.cpp || fail "checker max payload binding changed"

mkdir -p "$ROOT"
python3 tools/helix-vrchat-workload-model.py --self-test
python3 tools/helix-vrchat-workload-model.py --seed "$SEED" --duration "$DURATION" --profile "$PROFILE" --out "$TRACE" --summary-json "$SUMMARY"

grep -Fqx '# helix-vrchat-trace v1' "$TRACE" || fail "trace header mismatch"
grep -Eq '^# rows=[0-9]+ rows_sha256=[0-9a-f]{64}$' "$TRACE" || fail "trace row hash header missing"

python3 - "$TRACE" "$SUMMARY" <<'PY'
import json, sys
from collections import defaultdict, Counter
trace, summary = sys.argv[1:]
drops = defaultdict(list)
stream_drops = Counter()
with open(trace) as f:
    for line in f:
        if not line or line.startswith('#'):
            continue
        a = line.rstrip('\n').split(',')
        if len(a) != 9 or a[0] != 'P':
            raise SystemExit('FAIL: malformed trace row during canary audit')
        if a[8] == 'D':
            s, fr, sh = int(a[3]), int(a[4]), int(a[5])
            stream_drops[s] += 1
            drops[(s, fr)].append(sh)
canaries = sorted((s, fr) for (s, fr), shards in drops.items() if shards == [0])
if stream_drops[0] == 0 or stream_drops[1] == 0:
    raise SystemExit(f'FAIL: representative drops not present on both streams: {dict(stream_drops)}')
if len(canaries) != 2 or {s for s, _ in canaries} != {0, 1}:
    raise SystemExit(f'FAIL: expected exactly one single-shard0 RTX canary per stream, got {canaries}')
with open(summary) as f:
    j = json.load(f)
reported = {int(k): int(v) for k, v in j.get('rtx_canary_frames', {}).items()}
if reported != dict(canaries):
    raise SystemExit(f'FAIL: summary canary binding mismatch reported={reported} trace={dict(canaries)}')
print(f'CANARY_AUDIT=PASS stream0_frame={reported[0]} stream1_frame={reported[1]} drop_rows_s0={stream_drops[0]} drop_rows_s1={stream_drops[1]}')
PY

c++ -std=c++20 -O2 -Wall -Wextra -Werror -I server tools/helix-vrchat-trace-check.cpp -o "$CHECKER"
"$CHECKER" "$TRACE"

TRACE_SHA="$(sha256sum "$TRACE" | awk '{print $1}')"
SUMMARY_SHA="$(sha256sum "$SUMMARY" | awk '{print $1}')"
GEN_SHA="$(sha256sum tools/helix-vrchat-workload-model.py | awk '{print $1}')"
LOADER_SHA="$(sha256sum server/helix_vrchat_trace.h | awk '{print $1}')"
CHECK_SRC_SHA="$(sha256sum tools/helix-vrchat-trace-check.cpp | awk '{print $1}')"
SERVER_SHA="$(sha256sum server/helix_synthetic_transport.cpp | awk '{print $1}')"
PACKETS_SHA="$(sha256sum common/wivrn_packets.h | awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$GEN_SHA" "$LOADER_SHA" "$CHECK_SRC_SHA" "$SERVER_SHA" "$PACKETS_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
SOURCE_COMMIT="$(git rev-parse HEAD)"
[[ "$SOURCE_COMMIT" == "$EXPECTED_SOURCE_COMMIT" ]] || fail "source commit changed during build"
[[ -z "$(git status --short)" ]] || fail "source tree changed during artifact build"

CANARY0="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rtx_canary_frames"]["0"])' "$SUMMARY")"
CANARY1="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["rtx_canary_frames"]["1"])' "$SUMMARY")"

cat >"$META" <<EOF
source_commit=$EXPECTED_SOURCE_COMMIT
repair_tooling_commit=$REPAIR_TOOLING_COMMIT
seed=$SEED
duration_s=$DURATION
profile=$PROFILE
phase=transport-recovery-characterization
rtx_canary_stream0_frame=$CANARY0
rtx_canary_stream1_frame=$CANARY1
trace_sha256=$TRACE_SHA
summary_sha256=$SUMMARY_SHA
generator_sha256=$GEN_SHA
loader_sha256=$LOADER_SHA
checker_source_sha256=$CHECK_SRC_SHA
server_trace_source_sha256=$SERVER_SHA
protocol_packets_sha256=$PACKETS_SHA
trace_path=$TRACE
summary_path=$SUMMARY
oracle_contract=clean-failed-zero-false-complete-zero-two-shard0-canaries-recovered-representative-damage-characterized
payload_contract=zero-clamp-runtime-guard-edge-shard-headroom1200-protocol-max1400-bound
trace_identity=whole-file-sha256-external-seal
claim_boundary=transport-assembly-and-rtx-only-decoder-output-and-hevc10-not-established
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"

printf 'PASS: representative VRChat-like trace v3 built and structurally checked.\nsource_commit=%s\nrepair_tooling_commit=%s\ntrace_sha256=%s\nsummary_sha256=%s\nmetadata_sha256=%s\ncanary_stream0_frame=%s canary_stream1_frame=%s\nseed=%s duration_s=%s profile=%s\nSTATUS: transport-recovery characterization artifact built only; runtime not executed.\n' "$EXPECTED_SOURCE_COMMIT" "$REPAIR_TOOLING_COMMIT" "$TRACE_SHA" "$SUMMARY_SHA" "$META_SHA" "$CANARY0" "$CANARY1" "$SEED" "$DURATION" "$PROFILE"
