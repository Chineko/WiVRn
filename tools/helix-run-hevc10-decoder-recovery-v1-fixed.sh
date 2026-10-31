#!/usr/bin/env bash
set -euo pipefail

BASE_RUNNER_COMMIT="0df0d1fead1189e01293cc61e2a4dff56f0490c0"
BASE_RUNNER_PATH="tools/helix-run-hevc10-decoder-recovery-v1.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash grep; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git cat-file -e "${BASE_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_RUNNER_COMMIT"
git cat-file -e "${BASE_RUNNER_COMMIT}^{commit}" 2>/dev/null || fail "pinned base runner commit unavailable"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "${BASE_RUNNER_COMMIT}:${BASE_RUNNER_PATH}" >"$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old="grep -Fqx 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' \"$SEAL\" || fail \"seal gate marker missing\""
new="grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' \"$SEAL\" || fail \"seal gate marker missing\""
if s.count(old) != 1:
    raise SystemExit(f"FAIL: stale seal marker anchor count={s.count(old)}")
if new in s:
    raise SystemExit("FAIL: corrected seal marker unexpectedly already present")
s=s.replace(old,new,1)
p.write_text(s)
PY

bash -n "$tmp"
grep -Fq 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$tmp" || fail "corrected seal marker missing"
! grep -Fq "grep -Fqx 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers'" "$tmp" || fail "stale seal-file marker remains"
grep -Fq 'SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"' "$tmp" || fail "server hash binding missing"
grep -Fq 'APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"' "$tmp" || fail "APK hash binding missing"
grep -Fq 'META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"' "$tmp" || fail "metadata hash binding missing"
grep -Fq 'STIM_BIN_SHA256="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"' "$tmp" || fail "stimulus hash binding missing"
grep -Fq 'FRAMES=1200' "$tmp" || fail "frame-count binding missing"
grep -Fq '"bit-depth": 10' "$tmp" || fail "10-bit config binding missing"
grep -Fq '"encoder": {"encoder": "nvenc", "codec": "h265"}' "$tmp" || fail "NVENC H265 config binding missing"
grep -Fq 'export HELIX_HEVC10_RECOVERY=1' "$tmp" || fail "HEVC10 runtime enable missing"
grep -Fq 'QUEST_IP_EXPECTED="192.168.0.54"' "$tmp" || fail "Quest IP binding missing"
grep -Fq 'HOST_IP_EXPECTED="192.168.0.44"' "$tmp" || fail "host IP binding missing"
grep -Fq 'HOST_DEV_EXPECTED="enp14s0"' "$tmp" || fail "host route binding missing"
grep -Fq 'ADB forward exists; LAN-only transport proof requires none' "$tmp" || fail "ADB forward exclusion missing"
grep -Fq 'ADB reverse exists; LAN-only transport proof requires none' "$tmp" || fail "ADB reverse exclusion missing"
! grep -Eq 'adb .*forward .*tcp:|adb .*reverse .*tcp:' "$tmp" || fail "runtime contains ADB tunnel creation"
grep -Fq 'decoder_recovery=ESTABLISHED exact-rtx-to-mediacodec-to-aimage-per-eye' "$tmp" || fail "exact decoder oracle missing"
grep -Fq 'PIXEL_CLEANLINESS=NOT_ESTABLISHED' "$tmp" || fail "pixel-cleanliness claim boundary missing"

if [[ "${1:-}" == "--emit-only" ]]; then
  [[ $# -eq 2 && -n "${2:-}" ]] || fail "usage: $0 --emit-only OUTPUT"
  cp -- "$tmp" "$2"
  echo "RUNTIME_RUNNER_EMIT=PASS corrected-seal-marker-final-script-not-executed"
  echo "emitted=$2"
  echo "RUNTIME=NOT_RUN"
  exit 0
fi
[[ $# -eq 0 ]] || fail "unexpected arguments"

echo 'RUNTIME_RUNNER_PREFLIGHT=PASS corrected-seal-marker-final-script-audited'
exec bash "$tmp"
