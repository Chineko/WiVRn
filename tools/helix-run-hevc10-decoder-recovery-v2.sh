#!/usr/bin/env bash
set -euo pipefail

BASE_RUNNER_COMMIT="0bfb4c6092498cae7be8e32d2199490589f75f35"
BASE_RUNNER_PATH="tools/helix-run-hevc10-decoder-recovery-v1-fixed.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash grep mktemp cp rm; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git cat-file -e "${BASE_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_RUNNER_COMMIT"
git cat-file -e "${BASE_RUNNER_COMMIT}^{commit}" 2>/dev/null || fail "pinned v1 runner commit unavailable"

base_wrapper="$(mktemp)"
final="$(mktemp)"
trap 'rm -f "$base_wrapper" "$final"' EXIT INT TERM
git show "${BASE_RUNNER_COMMIT}:${BASE_RUNNER_PATH}" >"$base_wrapper"
bash -n "$base_wrapper"
bash "$base_wrapper" --emit-only "$final" >/dev/null

python3 - "$final" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
start="echo '[4/8] Proving resolved NVENC H.265 Main10 on both eyes'\n"
end="echo '[5/8] Driving 1200 sealed graphics-bound OpenXR frames'\n"
if s.count(start) != 1 or s.count(end) != 1:
    raise SystemExit(f"FAIL: pre-drive gate block anchors start={s.count(start)} end={s.count(end)}")
i=s.index(start); j=s.index(end)
if i >= j:
    raise SystemExit('FAIL: gate block ordering corrupt')
old=s[i:j]
required_old=[
    "for _ in $(seq 1 200); do",
    "HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10",
    "HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10",
    "HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10",
    "HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10",
    "HELIX_HEVC10_FAULT_PLAN stream=0 target_ordinal=600 shard=0",
    "HELIX_HEVC10_FAULT_PLAN stream=1 target_ordinal=900 shard=0",
]
for x in required_old:
    if x not in old:
        raise SystemExit('FAIL: old pre-drive gate block missing '+x)
new="echo '[4/8] Trusted connection established; resolved encoder gates will be verified after real frame drive'\n\n"
s=s[:i]+new+s[j:]
anchor="grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' \"$EVIDENCE/vulkan.txt\" || fail \"sealed entropy stimulus contract did not execute\"\n"
if s.count(anchor) != 1:
    raise SystemExit(f"FAIL: post-stimulus anchor count={s.count(anchor)}")
verify=anchor+r'''kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited during HEVC10 frame drive"
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" || fail "eye 0 HEVC10 encoder gate missing"
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" || fail "eye 1 HEVC10 encoder gate missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG" || fail "eye 0 Main10 profile marker missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG" || fail "eye 1 Main10 profile marker missing"
grep -Fq 'HELIX_HEVC10_FAULT_PLAN stream=0 target_ordinal=600 shard=0' "$SERVER_LOG" || fail "eye 0 fault plan missing"
grep -Fq 'HELIX_HEVC10_FAULT_PLAN stream=1 target_ordinal=900 shard=0' "$SERVER_LOG" || fail "eye 1 fault plan missing"
'''
s=s.replace(anchor,verify,1)
p.write_text(s)
PY

bash -n "$final"
grep -Fq "echo '[4/8] Trusted connection established; resolved encoder gates will be verified after real frame drive'" "$final" || fail "v2 deferred-gate marker missing"
! grep -Fq "echo '[4/8] Proving resolved NVENC H.265 Main10 on both eyes'" "$final" || fail "stale pre-drive gate block remains"
grep -Fq 'server exited during HEVC10 frame drive' "$final" || fail "post-drive server liveness gate missing"
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10' "$final" || fail "eye 0 encoder gate missing"
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10' "$final" || fail "eye 1 encoder gate missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10' "$final" || fail "eye 0 Main10 gate missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10' "$final" || fail "eye 1 Main10 gate missing"
python3 - "$final" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
drive=s.index("echo '[5/8] Driving 1200 sealed graphics-bound OpenXR frames'")
complete=s.index('HELIX_VULKAN_DONE frames=$FRAMES')
verify=s.index('server exited during HEVC10 frame drive')
if not drive < complete < verify:
    raise SystemExit('FAIL: HEVC10 resolved-path verification is not post-drive')
PY

if [[ "${1:-}" == "--emit-only" ]]; then
  [[ $# -eq 2 && -n "${2:-}" ]] || fail "usage: $0 --emit-only OUTPUT"
  cp -- "$final" "$2"
  echo 'RUNTIME_RUNNER_V2_EMIT=PASS post-drive-hevc10-gates-final-script-not-executed'
  echo "emitted=$2"
  echo 'RUNTIME=NOT_RUN'
  exit 0
fi
[[ $# -eq 0 ]] || fail "unexpected arguments"

echo 'RUNTIME_RUNNER_V2_PREFLIGHT=PASS post-drive-hevc10-gates-final-script-audited'
exec bash "$final"
