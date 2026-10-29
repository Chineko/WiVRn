#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

SOURCE_BASE="fa68cb3af0e0dfcb5e683abd951dfe0d2a126336"
EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
PACKAGE="org.meumeu.wivrn.local"
MAX_SECONDS=${HELIX_RUNTIME_SECONDS:-240}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_RUNTIME_OUT:-"$HOME/helix-bounded-recovery-$STAMP"}
DASH_PID=""

fail() { echo "Helix runtime gate: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in adb awk bash cmake cut date find git grep head mktemp pkill python3 rm sleep sort strings timeout tr; do need "$cmd"; done

cleanup() {
    set +e
    if [[ -n "$DASH_PID" ]]; then
        kill "$DASH_PID" >/dev/null 2>&1 || true
        wait "$DASH_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH"
git cat-file -e "$SOURCE_BASE^{commit}" 2>/dev/null || fail "source base $SOURCE_BASE not available locally"
if ! git diff --quiet "$SOURCE_BASE" -- . ':(exclude)docs/**' ':(exclude)tools/**'; then
    fail "runtime source differs from frozen prototype $SOURCE_BASE"
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "tracked working-tree changes are present"
fi

RUNTIME_HEAD=$(git rev-parse HEAD)
RUNTIME_SHORT=${RUNTIME_HEAD:0:8}
mkdir -p "$OUT"
printf 'source_base=%s\nruntime_head=%s\nstarted_utc=%s\n' "$SOURCE_BASE" "$RUNTIME_HEAD" "$(date -u +%FT%TZ)" >"$OUT/metadata.txt"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell is not active"

echo "[1/6] Building matching desktop server + dashboard from $RUNTIME_SHORT"
if [[ ! -f build-everything/build.ninja ]]; then
    cmake --preset everything
fi
cmake --build build-everything --target wivrn-server wivrn-dashboard -j

mapfile -t servers < <(find build-everything -type f -name wivrn-server -perm -111 | sort)
mapfile -t dashboards < <(find build-everything -type f -name wivrn-dashboard -perm -111 | sort)
[[ ${#servers[@]} -eq 1 ]] || fail "expected one build-everything wivrn-server, found ${#servers[@]}"
[[ ${#dashboards[@]} -eq 1 ]] || fail "expected one build-everything wivrn-dashboard, found ${#dashboards[@]}"
SERVER=${servers[0]}
DASHBOARD=${dashboards[0]}
strings "$SERVER" | grep -F "$RUNTIME_SHORT" >/dev/null || fail "server binary does not contain runtime id $RUNTIME_SHORT"
PREFIX=$(find build-everything -type f -path '*/dashboard/prefix.sh' | head -n1 || true)
[[ -n "$PREFIX" && -f "$PREFIX" ]] || fail "dashboard prefix.sh not found in build-everything"

echo "[2/6] Building matching Quest APK"
[[ -f ./gradlew ]] || fail "Gradle wrapper not found"
rm -rf build/outputs/apk/debug
bash ./gradlew assembleDebug
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' | sort)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK, found ${#apks[@]}"
APK=${apks[0]}

echo "[3/6] Installing and verifying Quest runtime"
adb install -r -d "$APK" >/dev/null || fail "ADB APK install failed"
APK_PATH=$(adb shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | awk -F: '/base\.apk$/{print $2; exit}')
[[ -n "$APK_PATH" ]] || fail "installed $PACKAGE base APK not found"
APK_TMP=$(mktemp --suffix=.apk)
if ! timeout 45s adb exec-out su -c "cat '$APK_PATH'" >"$APK_TMP"; then
    rm -f "$APK_TMP"
    fail "could not read installed APK for identity verification"
fi
python3 - "$APK_TMP" "$RUNTIME_SHORT" <<'PY'
import sys, zipfile
apk, expected = sys.argv[1], sys.argv[2].encode()
with zipfile.ZipFile(apk) as z:
    libs = [n for n in z.namelist() if n.endswith('.so')]
    if not libs:
        raise SystemExit("no native libraries found in installed APK")
    if not any(expected in z.read(n) for n in libs):
        raise SystemExit(f"installed Quest native libraries do not contain runtime id {expected.decode()}")
PY
rm -f "$APK_TMP"

echo "[4/6] Launching verified dashboard and Quest client"
pkill -f "$DASHBOARD" >/dev/null 2>&1 || true
pkill -f "$SERVER" >/dev/null 2>&1 || true
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb logcat -c >/dev/null 2>&1 || true
CAPTURE_START=$(date +%s)
echo "capture_start_epoch=$CAPTURE_START" >>"$OUT/metadata.txt"
(
    cd "$ROOT"
    # shellcheck disable=SC1090
    source "$PREFIX"
    exec "$DASHBOARD"
) >"$OUT/dashboard-stdout.txt" 2>&1 &
DASH_PID=$!
sleep 3
kill -0 "$DASH_PID" 2>/dev/null || fail "dashboard exited during startup; see $OUT/dashboard-stdout.txt"
adb shell monkey -p "$PACKAGE" 1 >/dev/null 2>&1 || fail "could not launch Quest client"

echo
echo "RUNTIME TEST ARMED"
echo "  source prototype: ${SOURCE_BASE:0:12}"
echo "  matching runtime: ${RUNTIME_HEAD:0:12}"
echo "  output:           $OUT"
echo
echo "Use VR normally and reproduce the short-lag workload."
echo "Press Enter when you have exercised it; this auto-stops after ${MAX_SECONDS}s."
if ! read -r -t "$MAX_SECONDS" _; then
    echo "Runtime duration limit reached; collecting results."
fi

echo "[5/6] Collecting runtime evidence"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep 2
adb logcat -d -v threadtime >"$OUT/quest-logcat.txt" 2>&1 || true
kill "$DASH_PID" >/dev/null 2>&1 || true
wait "$DASH_PID" >/dev/null 2>&1 || true
DASH_PID=""
sleep 2

SERVER_LOG_DIR="$HOME/.local/state/wivrn/wivrn-dashboard"
SERVER_LOG=""
if [[ -d "$SERVER_LOG_DIR" ]]; then
    SERVER_LOG=$(find "$SERVER_LOG_DIR" -maxdepth 1 -type f -name 'server_logs_*.txt' -newermt "@$CAPTURE_START" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[[ -n "$SERVER_LOG" ]] || fail "no dashboard server log updated during the runtime test"
cp "$SERVER_LOG" "$OUT/server-log.txt"
printf 'server_log_source=%s\nfinished_utc=%s\n' "$SERVER_LOG" "$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

grep -F "$RUNTIME_SHORT" "$OUT/server-log.txt" >/dev/null || fail "runtime server log does not contain $RUNTIME_SHORT"
grep -F "$RUNTIME_SHORT" "$OUT/quest-logcat.txt" >/dev/null || fail "Quest runtime log does not contain $RUNTIME_SHORT"

echo "[6/6] Reducing to bounded-recovery decision signals"
python3 - "$OUT/server-log.txt" "$OUT/quest-logcat.txt" "$OUT/result.txt" <<'PY'
import re, sys
from pathlib import Path
server = Path(sys.argv[1]).read_text(errors='replace')
quest = Path(sys.argv[2]).read_text(errors='replace')
out = Path(sys.argv[3])

def count(text, pattern):
    return len(re.findall(pattern, text, re.M))

vals = {
    'replay_events': count(server, r'Helix time-diverse replay '),
    'gap_events': count(server, r'Helix gap timing event '),
    'idr_needed': count(server, r'IDR frame needed'),
    'idr_retargeted': count(server, r'IDR frame retargeted'),
    'inconsistent_idr': count(server, r'inconsistent IDR state'),
    'idr_timeouts': count(server, r'IDR frame timeout'),
    'encoder_timeouts': count(server, r'Timeout on stream'),
    'quest_incomplete_frames': count(quest, r'was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
}
summary = re.findall(r'^.*Helix time-diverse summary.*$', server, re.M)
rtx_summary = re.findall(r'^.*Helix RTX.*summary.*$', quest, re.M | re.I)

if vals['replay_events'] == 0:
    verdict = 'NONDIAGNOSTIC: no time-diverse replay event occurred'
elif vals['inconsistent_idr'] or vals['idr_timeouts'] or vals['encoder_timeouts']:
    verdict = 'FAIL: recovery path executed but a hard recovery/encoder failure signal occurred'
else:
    verdict = 'PROVISIONAL_PASS: time-diverse path executed without hard failure signals; compare incomplete-frame/IDR fallout to baseline before promotion'

lines = [verdict, '']
lines += [f'{k}={v}' for k, v in vals.items()]
if summary:
    lines += ['', 'server_time_diverse_summary:', summary[-1]]
if rtx_summary:
    lines += ['', 'quest_rtx_summary:', rtx_summary[-1]]
out.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

echo
echo "Artifacts: $OUT"
echo "Send me result.txt (or paste the terminal summary) and I can make the prototype decision immediately."
trap - EXIT INT TERM
