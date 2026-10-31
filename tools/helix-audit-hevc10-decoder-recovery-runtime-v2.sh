#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BASE_AUDIT_COMMIT="cc5954a431d518dd8b929716308090a6f5868411"
BASE_AUDIT_PATH="tools/helix-audit-hevc10-decoder-recovery-runtime-v1.sh"
RUNNER_V2_COMMIT="75d8f3dc4d24ca85606094412b70cd5fda6a3ae7"
RUNNER_V2_PATH="tools/helix-run-hevc10-decoder-recovery-v2.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 grep mktemp cp rm; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
for commit in "$SOURCE_COMMIT" "$BASE_AUDIT_COMMIT" "$RUNNER_V2_COMMIT"; do
  git cat-file -e "${commit}^{commit}" 2>/dev/null || git fetch origin "$commit"
  git cat-file -e "${commit}^{commit}" 2>/dev/null || fail "required commit unavailable: $commit"
done

base_audit="$(mktemp)"
runner_v2="$(mktemp)"
final_v2="$(mktemp)"
base_log="$(mktemp)"
trap 'rm -f "$base_audit" "$runner_v2" "$final_v2" "$base_log"' EXIT INT TERM

# Re-run the complete v1 artifact/source/oracle audit first. It is pre-runtime only.
git show "$BASE_AUDIT_COMMIT:$BASE_AUDIT_PATH" >"$base_audit"
bash -n "$base_audit"
set +e
bash "$base_audit" >"$base_log" 2>&1
base_status=$?
set -e
cat "$base_log"
[[ "$base_status" -eq 0 ]] || fail "base complete runtime audit failed"
grep -Fqx 'AUDIT_A=PASS hevc10-runtime-runner-exact-source-artifacts-hashes-seals-stimulus-final-emitted-script' "$base_log" || fail "base Audit A marker missing"
grep -Fqx 'AUDIT_B=PASS bit-depth-parser-nvenc-main10-both-eye-cached-shard0-exact-rtx-mediacodec-aimage-lan-only-bounded-ledger' "$base_log" || fail "base Audit B marker missing"
grep -Fqx 'RUNTIME=NOT_RUN' "$base_log" || fail "base audit unexpectedly crossed runtime boundary"

# Materialize the v2 final runner without executing runtime.
git show "$RUNNER_V2_COMMIT:$RUNNER_V2_PATH" >"$runner_v2"
bash -n "$runner_v2"
grep -Fqx 'BASE_RUNNER_COMMIT="0bfb4c6092498cae7be8e32d2199490589f75f35"' "$runner_v2" || fail "v2 base runner binding mismatch"
grep -Fq 'pre-drive gate block anchors' "$runner_v2" || fail "v2 does not require unique gate-block anchors"
grep -Fq 'RUNTIME_RUNNER_V2_EMIT=PASS post-drive-hevc10-gates-final-script-not-executed' "$runner_v2" || fail "v2 emit-only marker missing"
bash "$runner_v2" --emit-only "$final_v2" >"$base_log.v2"
grep -Fqx 'RUNTIME=NOT_RUN' "$base_log.v2" || fail "v2 emit-only crossed runtime boundary"
bash -n "$final_v2"

# The source and artifact identities audited by v1 must remain literally bound in v2.
for binding in \
  'SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"' \
  'SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"' \
  'APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"' \
  'META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"' \
  'STIM_BIN_SHA256="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"' \
  'FRAMES=1200' \
  'QUEST_IP_EXPECTED="192.168.0.54"' \
  'HOST_IP_EXPECTED="192.168.0.44"' \
  'HOST_DEV_EXPECTED="enp14s0"'; do
  grep -Fq "$binding" "$final_v2" || fail "v2 binding missing: $binding"
done

grep -Fq '"encoder": {"encoder": "nvenc", "codec": "h265"}' "$final_v2" || fail "v2 NVENC H265 request missing"
grep -Fq '"bit-depth": 10' "$final_v2" || fail "v2 10-bit request missing"
grep -Fq 'export HELIX_HEVC10_RECOVERY=1' "$final_v2" || fail "v2 HEVC10 source gate enable missing"
grep -Fq 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$final_v2" || fail "v2 corrected seal binding missing"
! grep -Fq "grep -Fqx 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers'" "$final_v2" || fail "v2 resurrected stale seal-file marker"

# Critical v2 invariant: no resolved-encoder wait before starting OpenXR.
grep -Fq "echo '[4/8] Trusted connection established; resolved encoder gates will be verified after real frame drive'" "$final_v2" || fail "deferred encoder-gate marker missing"
! grep -Fq "echo '[4/8] Proving resolved NVENC H.265 Main10 on both eyes'" "$final_v2" || fail "stale pre-drive encoder wait remains"
grep -Fq 'server exited during HEVC10 frame drive' "$final_v2" || fail "post-drive server liveness proof missing"
python3 - "$final_v2" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
drive=s.index("echo '[5/8] Driving 1200 sealed graphics-bound OpenXR frames'")
completion=s.index('grep -Fq "HELIX_VULKAN_DONE frames=$FRAMES"')
verify=s.index('server exited during HEVC10 frame drive')
if not drive < completion < verify:
    raise SystemExit('FAIL: resolved HEVC10 verification is not strictly post-drive')
# Each resolved eye gate/profile/fault-plan check must still exist after the drive.
need=[
 'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10',
 'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10',
 'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10',
 'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10',
 'HELIX_HEVC10_FAULT_PLAN stream=0 target_ordinal=600 shard=0',
 'HELIX_HEVC10_FAULT_PLAN stream=1 target_ordinal=900 shard=0',
]
post=s[verify:]
for x in need:
    if x not in post:
        raise SystemExit('FAIL: post-drive proof missing '+x)
PY

# Preserve exact per-eye decoder oracle, bounded ledger, LAN-only proof, and claim boundary.
for oracle in \
  "x.get('frame')==frame and x.get('packet_sequence')==seq and x.get('exact_canary')=='1'" \
  "x.get('frame')==frame and x.get('exact_recovered_frame')=='1'" \
  "x.get('recovered_frame')!=frame" \
  "int(x.get('image_frame','-1')) >= int(frame)" \
  "p.get('overflow')!='0'" \
  'decoder_recovery=ESTABLISHED exact-rtx-to-mediacodec-to-aimage-per-eye' \
  'PIXEL_CLEANLINESS=NOT_ESTABLISHED' \
  'RUNTIME=PASS hevc10-both-eye-exact-rtx-mediacodec-aimage-recovery'; do
  grep -Fq "$oracle" "$final_v2" || fail "v2 oracle/claim marker missing: $oracle"
done
grep -Fq 'adb forward --list' "$final_v2" || fail "v2 ADB-forward exclusion missing"
grep -Fq 'reverse --list' "$final_v2" || fail "v2 ADB-reverse exclusion missing"
! grep -Eq 'adb .*forward .*tcp:|adb .*reverse .*tcp:' "$final_v2" || fail "v2 contains ADB tunnel creation"

echo 'AUDIT_A=PASS hevc10-runtime-v2-inherits-exact-source-artifacts-hashes-seals-stimulus-and-v1-oracle-audit'
echo 'AUDIT_B=PASS openxr-drive-before-resolved-main10-gates-both-eye-exact-frame-decoder-oracle-lan-only-claim-boundary'
echo "source_commit=$SOURCE_COMMIT"
echo "runner_v2_commit=$RUNNER_V2_COMMIT"
echo 'frames=1200 target_ordinals=600,900'
echo 'runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts'
echo 'probe_overflow_required=0'
echo 'PIXEL_CLEANLINESS=NOT_ESTABLISHED'
echo 'RUNTIME=NOT_RUN'
