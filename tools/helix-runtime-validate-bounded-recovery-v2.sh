#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

SOURCE_BASE="fa68cb3af0e0dfcb5e683abd951dfe0d2a126336"
EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
PACKAGE="org.meumeu.wivrn.local"
MAX_SECONDS=${HELIX_RUNTIME_SECONDS:-240}
USB_RECONNECT_SECONDS=${HELIX_USB_RECONNECT_SECONDS:-120}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_RUNTIME_OUT:-"$HOME/helix-bounded-recovery-$STAMP"}
DASH_PID=""

fail() { echo "Helix runtime gate: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in adb awk bash busctl cmake cp cut date dirname find git grep head mktemp pgrep pkill python3 readlink realpath rm seq sleep sort strings timeout tr; do need "$cmd"; done

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

echo "[1/7] Building matching desktop server + dashboard from $RUNTIME_SHORT"
if [[ ! -f build-everything/build.ninja ]]; then
    cmake --preset everything
fi
cmake --build build-everything --target wivrn-server wivrn-dashboard -j

mapfile -t servers < <(find build-everything -type f -name wivrn-server -perm -111 | sort)
mapfile -t dashboards < <(find build-everything -type f -name wivrn-dashboard -perm -111 | sort)
[[ ${#servers[@]} -eq 1 ]] || fail "expected one build-everything wivrn-server, found ${#servers[@]}"
[[ ${#dashboards[@]} -eq 1 ]] || fail "expected one build-everything wivrn-dashboard, found ${#dashboards[@]}"
SERVER=$(realpath "${servers[0]}")
DASHBOARD=$(realpath "${dashboards[0]}")
[[ "$(dirname "$SERVER")" == "$(dirname "$DASHBOARD")" ]] || fail "dashboard and server are not sibling runtime artifacts"
strings "$SERVER" | grep -F "$RUNTIME_SHORT" >/dev/null || fail "server binary does not contain runtime id $RUNTIME_SHORT"
PREFIX=$(find build-everything -type f -path '*/dashboard/prefix.sh' | head -n1 || true)
[[ -n "$PREFIX" && -f "$PREFIX" ]] || fail "dashboard prefix.sh not found in build-everything"

echo "[2/7] Building matching Quest APK"
[[ -f ./gradlew ]] || fail "Gradle wrapper not found"
rm -rf build/outputs/apk/debug
bash ./gradlew assembleDebug
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' | sort)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK, found ${#apks[@]}"
APK=${apks[0]}

echo "[3/7] Installing and verifying Quest runtime"
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

echo "[4/7] Establishing clean desktop runtime ownership"
pkill -x wivrn-dashboard >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    if ! pgrep -x wivrn-server >/dev/null 2>&1 && ! pgrep -x wivrn-dashboard >/dev/null 2>&1; then
        break
    fi
    sleep 0.1
done
! pgrep -x wivrn-server >/dev/null 2>&1 || fail "a pre-existing wivrn-server survived cleanup"
! pgrep -x wivrn-dashboard >/dev/null 2>&1 || fail "a pre-existing wivrn-dashboard survived cleanup"
if busctl --user --no-pager status io.github.wivrn.Server >/dev/null 2>&1; then
    fail "io.github.wivrn.Server is still owned before launch"
fi

adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb logcat -c >/dev/null 2>&1 || true
CAPTURE_START=$(date +%s)
echo "capture_start_epoch=$CAPTURE_START" >>"$OUT/metadata.txt"

(
    cd "$ROOT"
    set +u
    # shellcheck disable=SC1090
    source "$PREFIX"
    set -u
    exec "$DASHBOARD"
) >"$OUT/dashboard-stdout.txt" 2>&1 &
DASH_PID=$!

SERVER_LOG=""
for _ in $(seq 1 100); do
    kill -0 "$DASH_PID" 2>/dev/null || fail "dashboard exited during startup; see $OUT/dashboard-stdout.txt"
    SERVER_LOG=$(python3 - "$OUT/dashboard-stdout.txt" <<'PY'
import re, sys
from pathlib import Path
p = Path(sys.argv[1])
text = p.read_text(errors='replace') if p.exists() else ''
m = re.findall(r'Saving logs in\s+"([^"]*server_logs_[^"]+\.txt)"', text)
print(m[-1] if m else '')
PY
)
    [[ -n "$SERVER_LOG" ]] && break
    sleep 0.1
done
[[ -n "$SERVER_LOG" ]] || fail "dashboard did not report a newly-created server log before arm"
[[ "$SERVER_LOG" == /* && -s "$SERVER_LOG" ]] || fail "dashboard-reported server log is missing/empty: $SERVER_LOG"

mapfile -t server_pids < <(pgrep -x wivrn-server || true)
[[ ${#server_pids[@]} -eq 1 ]] || fail "expected exactly one wivrn-server after dashboard launch, found ${#server_pids[@]}"
SERVER_PID=${server_pids[0]}
SERVER_EXE=$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server is $SERVER_EXE, expected $SERVER"
grep -F "$RUNTIME_SHORT" "$SERVER_LOG" >/dev/null || fail "new server log does not contain runtime id $RUNTIME_SHORT before arm"

adb shell monkey -p "$PACKAGE" 1 >/dev/null 2>&1 || fail "could not launch Quest client"

echo
echo "RUNTIME TEST ARMED"
echo "  source prototype: ${SOURCE_BASE:0:12}"
echo "  matching runtime: ${RUNTIME_HEAD:0:12}"
echo "  server pid/exe:   $SERVER_PID / $SERVER_EXE"
echo "  server log:       $SERVER_LOG"
echo "  output:           $OUT"
echo
echo "Unplug USB, use VR normally, and reproduce the short-lag workload."
echo "Press Enter when finished; this auto-stops after ${MAX_SECONDS}s."
if ! read -r -t "$MAX_SECONDS" _; then
    echo "Runtime duration limit reached."
fi

echo
echo "[5/7] Reconnect Quest USB for evidence collection"
echo "Reconnect USB now. Waiting up to ${USB_RECONNECT_SECONDS}s..."
timeout "${USB_RECONNECT_SECONDS}s" adb wait-for-device || fail "Quest did not reconnect over USB within ${USB_RECONNECT_SECONDS}s"
ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one reconnected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell unavailable after reconnect"

echo "[6/7] Collecting runtime evidence"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep 1
adb logcat -d -v threadtime >"$OUT/quest-logcat.txt" 2>&1 || fail "could not collect Quest logcat"
kill "$DASH_PID" >/dev/null 2>&1 || true
wait "$DASH_PID" >/dev/null 2>&1 || true
DASH_PID=""
sleep 2
[[ -s "$SERVER_LOG" ]] || fail "authoritative server log became unavailable"
cp "$SERVER_LOG" "$OUT/server-log.txt"
printf 'server_log_source=%s\nserver_pid=%s\nserver_exe=%s\nfinished_utc=%s\n' \
    "$SERVER_LOG" "$SERVER_PID" "$SERVER_EXE" "$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

grep -F "$RUNTIME_SHORT" "$OUT/server-log.txt" >/dev/null || fail "server log lost runtime id $RUNTIME_SHORT"
grep -F "$RUNTIME_SHORT" "$OUT/quest-logcat.txt" >/dev/null || fail "Quest runtime log does not contain $RUNTIME_SHORT"

echo "[7/7] Reducing bounded-recovery decision signals"
python3 - "$OUT/server-log.txt" "$OUT/quest-logcat.txt" "$OUT/result.txt" <<'PY'
import re, sys
from pathlib import Path
server = Path(sys.argv[1]).read_text(errors='replace')
quest = Path(sys.argv[2]).read_text(errors='replace')
out = Path(sys.argv[3])

def count(text, pattern):
    return len(re.findall(pattern, text, re.M))

def kv(line):
    return {k: int(v) for k, v in re.findall(r'\b([A-Za-z_]+)=(\d+)\b', line)}

vals = {
    'replay_events': count(server, r'Helix time-diverse replay '),
    'gap_events': count(server, r'Helix gap timing event '),
    'idr_needed': count(server, r'IDR frame needed'),
    'idr_retargeted': count(server, r'IDR frame retargeted'),
    'inconsistent_idr': count(server, r'inconsistent IDR state'),
    'idr_timeouts': count(server, r'IDR frame timeout'),
    'encoder_timeouts': count(server, r'Timeout on stream'),
    'quest_incomplete_frames': count(quest, r'frame .* was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
}
summary = re.findall(r'^.*Helix time-diverse summary.*$', server, re.M)
summary_kv = [kv(line) for line in summary]
vals['td_summary_lines'] = len(summary_kv)
vals['td_fresh_bytes'] = sum(x.get('fresh_bytes', 0) for x in summary_kv)
vals['td_replay_bytes'] = sum(x.get('replay_bytes', 0) for x in summary_kv)
vals['td_replayed_frames'] = sum(x.get('replayed', 0) for x in summary_kv)
vals['td_send_errors'] = sum(x.get('send_errors', 0) for x in summary_kv)
vals['td_expired'] = sum(x.get('expired', 0) for x in summary_kv)
rtx_summary = re.findall(r'^.*Helix RTX.*summary.*$', quest, re.M | re.I)

summary_integrity = bool(summary_kv) and vals['td_replayed_frames'] == vals['replay_events']
budget_ok = bool(summary_kv) and vals['td_replay_bytes'] * 5 <= vals['td_fresh_bytes']
hard_failure = bool(vals['inconsistent_idr'] or vals['idr_timeouts'] or vals['encoder_timeouts'] or vals['td_send_errors'])

if vals['replay_events'] == 0:
    verdict = 'NONDIAGNOSTIC: no time-diverse replay event occurred'
elif not summary_kv:
    verdict = 'NONDIAGNOSTIC: replay occurred but no time-diverse shutdown summary was captured'
elif not summary_integrity:
    verdict = 'NONDIAGNOSTIC: replay event count does not reconcile with shutdown summary'
elif not budget_ok:
    verdict = 'FAIL: measured replay payload exceeded the frozen 20% long-run byte budget'
elif hard_failure:
    verdict = 'FAIL: recovery path executed but a hard recovery/encoder/send failure signal occurred'
elif vals['gap_events'] == 0:
    verdict = 'PROVISIONAL_PASS_EXECUTION_ONLY: replay path executed within budget without hard failures, but no gap event was observed'
else:
    verdict = 'PROVISIONAL_PASS: replay path executed during a run with gap events, stayed within budget, and showed no hard failure signals; effectiveness still requires event-level/baseline comparison'

lines = [verdict, '']
lines += [f'{k}={v}' for k, v in vals.items()]
lines += [f'td_summary_integrity={str(summary_integrity).lower()}', f'td_budget_ok={str(budget_ok).lower()}']
if vals['td_fresh_bytes']:
    lines += [f'td_replay_ratio={vals["td_replay_bytes"] / vals["td_fresh_bytes"]:.6f}']
if summary:
    lines += ['', 'server_time_diverse_summaries:', *summary]
if rtx_summary:
    lines += ['', 'quest_rtx_summary:', rtx_summary[-1]]
out.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

echo
echo "Artifacts: $OUT"
echo "Send result.txt or paste this terminal summary."
trap - EXIT INT TERM
