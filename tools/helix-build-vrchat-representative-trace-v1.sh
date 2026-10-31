#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-vrchat-representative-torture-v1"
TRACE="$ROOT/vrchat-torture-300s-seed20261031.trace"
SUMMARY="$ROOT/vrchat-torture-300s-seed20261031-summary.json"
CHECKER="$ROOT/helix-vrchat-trace-check"
META="$ROOT/vrchat-representative-trace-v1-metadata.txt"
SEED=20261031
DURATION=300
PROFILE=torture
REPAIR_TOOLING_COMMIT="bbb1a2ce173f1a36af2f64585b3251f94ce2237e"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in c++ git grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in tools/helix-vrchat-workload-model.py tools/helix-vrchat-trace-check.cpp server/helix_vrchat_trace.h server/helix_synthetic_transport.cpp; do [[ -s "$f" ]] || fail "missing repaired source $f"; done

grep -Fq 'make_trace_view_info()' server/helix_synthetic_transport.cpp || fail "RTX-eligible trace view info missing"
grep -Fq 'rtx_retransmissions' server/helix_synthetic_transport.cpp || fail "RTX replay accounting missing"
grep -Fq 'damaged_recovered' server/helix_synthetic_transport.cpp || fail "recovery-aware oracle missing"
grep -Fq 'payload_would_clamp' server/helix_synthetic_transport.cpp || fail "zero-clamp guard missing"
grep -Fq 'edge_payload = min(1200, cal["shard_payload"])' tools/helix-vrchat-workload-model.py || fail "edge payload headroom missing"
grep -Fq 'cal["fps"] = 1_000_000.0 / gap_mean_us' tools/helix-vrchat-workload-model.py || fail "cadence calibration fix missing"

mkdir -p "$ROOT"
python3 tools/helix-vrchat-workload-model.py --self-test
python3 tools/helix-vrchat-workload-model.py --seed "$SEED" --duration "$DURATION" --profile "$PROFILE" --out "$TRACE" --summary-json "$SUMMARY"

grep -Fqx '# helix-vrchat-trace v1' "$TRACE" || fail "trace header mismatch"
grep -Eq '^# rows=[0-9]+ rows_sha256=[0-9a-f]{64}$' "$TRACE" || fail "trace row hash header missing"

c++ -std=c++20 -O2 -Wall -Wextra -Werror -I server tools/helix-vrchat-trace-check.cpp -o "$CHECKER"
"$CHECKER" "$TRACE"

TRACE_SHA="$(sha256sum "$TRACE" | awk '{print $1}')"
SUMMARY_SHA="$(sha256sum "$SUMMARY" | awk '{print $1}')"
GEN_SHA="$(sha256sum tools/helix-vrchat-workload-model.py | awk '{print $1}')"
LOADER_SHA="$(sha256sum server/helix_vrchat_trace.h | awk '{print $1}')"
CHECK_SRC_SHA="$(sha256sum tools/helix-vrchat-trace-check.cpp | awk '{print $1}')"
SERVER_SHA="$(sha256sum server/helix_synthetic_transport.cpp | awk '{print $1}')"
for h in "$TRACE_SHA" "$SUMMARY_SHA" "$GEN_SHA" "$LOADER_SHA" "$CHECK_SRC_SHA" "$SERVER_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
SOURCE_COMMIT="$(git rev-parse HEAD)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "invalid source commit"

cat >"$META" <<EOF
source_commit=$SOURCE_COMMIT
repair_tooling_commit=$REPAIR_TOOLING_COMMIT
seed=$SEED
duration_s=$DURATION
profile=$PROFILE
phase=characterization
trace_sha256=$TRACE_SHA
summary_sha256=$SUMMARY_SHA
generator_sha256=$GEN_SHA
loader_sha256=$LOADER_SHA
checker_source_sha256=$CHECK_SRC_SHA
server_trace_source_sha256=$SERVER_SHA
trace_path=$TRACE
summary_path=$SUMMARY
oracle_contract=clean-failed-zero-false-complete-zero-rtx-exercised-at-least-one-damaged-recovered
payload_contract=zero-clamp-runtime-guard-edge-shard-headroom1200
trace_identity=whole-file-sha256-external-seal
runtime_status=NOT_RUN
EOF
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"

printf 'PASS: representative VRChat-like trace built and structurally checked.\nsource_commit=%s\ntrace_sha256=%s\nsummary_sha256=%s\nmetadata_sha256=%s\nseed=%s duration_s=%s profile=%s\nSTATUS: characterization artifact built only; runtime not executed.\n' "$SOURCE_COMMIT" "$TRACE_SHA" "$SUMMARY_SHA" "$META_SHA" "$SEED" "$DURATION" "$PROFILE"
