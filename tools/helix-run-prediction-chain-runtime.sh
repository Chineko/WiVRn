#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="a315a97f9bd39923a5249365f6fef1b73aa5b452"
PACKAGE="org.meumeu.wivrn.local"
MAX_SECONDS=${HELIX_RUNTIME_SECONDS:-300}
USB_RECONNECT_SECONDS=${HELIX_USB_RECONNECT_SECONDS:-120}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_RUNTIME_OUT:-"$HOME/helix-prediction-runtime-$STAMP"}
DASH_PID=""
WORKTREE=""
active_units=()

fail() { echo "Helix prediction runtime gate: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in adb ar awk bash busctl cmake cp date dirname find git grep head jq mktemp nm pgrep pkill python3 readlink realpath rm seq sha256sum sleep sort timeout tr; do need "$cmd"; done

cleanup() {
    set +e
    if [[ -n "$DASH_PID" ]]; then
        kill "$DASH_PID" >/dev/null 2>&1 || true
        wait "$DASH_PID" >/dev/null 2>&1 || true
    fi
    adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
    if command -v systemctl >/dev/null 2>&1; then
        for unit in "${active_units[@]}"; do systemctl --user start "$unit" >/dev/null 2>&1 || true; done
    fi
    if [[ -n "$WORKTREE" && -d "$WORKTREE" ]]; then
        git -C "$ROOT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || fail "run inside WiVRn checkout"
cd "$ROOT"
git cat-file -e "$SOURCE_COMMIT^{commit}" 2>/dev/null || fail "source commit $SOURCE_COMMIT is not available locally; run git fetch first"

mkdir -p "$OUT"
WORKTREE="$OUT/worktree"
git worktree add --detach "$WORKTREE" "$SOURCE_COMMIT" >/dev/null
cd "$WORKTREE"
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "wrong detached source commit"
[[ -z "$(git status --porcelain)" ]] || fail "fresh runtime worktree is dirty"
printf 'source_commit=%s\nstarted_utc=%s\n' "$SOURCE_COMMIT" "$(date -u +%FT%TZ)" >"$OUT/metadata.txt"

echo "[1/8] Building exact runtime-complete desktop artifacts"
cmake --preset everything 2>&1 | tee "$OUT/configure.txt"
cmake --build build-everything --target wivrn-server wivrn-dashboard openxr_wivrn monado -j 2 2>&1 | tee "$OUT/build.txt"

grep -Fq "const char git_commit[] = \"${SOURCE_COMMIT}\";" build-everything/version.cpp || fail "generated version.cpp does not contain exact source commit"
COMMON_ARCHIVE=$(find build-everything -type f -name 'libwivrn-common-base.a' -print -quit)
[[ -n "$COMMON_ARCHIVE" && -s "$COMMON_ARCHIVE" ]] || fail "common-base archive missing"
ar t "$COMMON_ARCHIVE" | grep -Fq 'version.cpp.o' || fail "common-base archive lacks version.cpp.o"
nm -C "$COMMON_ARCHIVE" | grep -Fq 'wivrn::display_version()' || fail "common-base archive lacks display_version symbol"

DEV_MANIFEST="$WORKTREE/build-everything/openxr_wivrn-dev.json"
[[ -s "$DEV_MANIFEST" ]] || fail "missing build-tree OpenXR development manifest"
python3 - "$DEV_MANIFEST" "$WORKTREE/build-everything" <<'PY'
import json, pathlib, sys
manifest = pathlib.Path(sys.argv[1]).resolve()
build_root = pathlib.Path(sys.argv[2]).resolve()
doc = json.loads(manifest.read_text())
if doc.get("file_format_version") != "1.0.0":
    raise SystemExit("unexpected OpenXR manifest version")
runtime = doc.get("runtime") or {}
value = runtime.get("library_path")
if not isinstance(value, str) or not value:
    raise SystemExit("OpenXR runtime library_path missing")
lib = pathlib.Path(value)
lib = (manifest.parent / lib).resolve() if not lib.is_absolute() else lib.resolve()
try:
    lib.relative_to(build_root)
except ValueError:
    raise SystemExit(f"OpenXR runtime escapes build tree: {lib}")
if not lib.is_file() or lib.stat().st_size == 0:
    raise SystemExit(f"OpenXR runtime library invalid: {lib}")
print(f"OpenXR manifest={manifest}")
print(f"OpenXR library={lib}")
PY

mapfile -t servers < <(find build-everything -type f -name wivrn-server -perm -111 | sort)
mapfile -t dashboards < <(find build-everything -type f -name wivrn-dashboard -perm -111 | sort)
[[ ${#servers[@]} -eq 1 ]] || fail "expected one wivrn-server, found ${#servers[@]}"
[[ ${#dashboards[@]} -eq 1 ]] || fail "expected one wivrn-dashboard, found ${#dashboards[@]}"
SERVER=$(realpath "${servers[0]}")
DASHBOARD=$(realpath "${dashboards[0]}")
PREFIX=$(find build-everything -type f -path '*/dashboard/prefix.sh' | head -n1 || true)
[[ -n "$PREFIX" && -f "$PREFIX" ]] || fail "dashboard prefix.sh missing"
printf 'server=%s\ndashboard=%s\nopenxr_manifest=%s\n' "$SERVER" "$DASHBOARD" "$DEV_MANIFEST" >>"$OUT/metadata.txt"

echo "[2/8] Locating and verifying exact matching Quest APK"
mapfile -t apk_meta_candidates < <(grep -l "^source_commit=${SOURCE_COMMIT}$" "$HOME"/helix-quest-apk-${SOURCE_COMMIT:0:12}-*/metadata.txt 2>/dev/null || true)
[[ ${#apk_meta_candidates[@]} -gt 0 ]] || fail "no preserved matching Quest APK for $SOURCE_COMMIT"
APK_META=$(printf '%s\n' "${apk_meta_candidates[@]}" | sort | tail -1)
APK=$(sed -n 's/^apk=//p' "$APK_META" | tail -1)
[[ -s "$APK" ]] || fail "preserved Quest APK missing: $APK"
APK_SHA_FILE=$(dirname "$APK_META")/apk.sha256
[[ -s "$APK_SHA_FILE" ]] || fail "APK sha256 evidence missing"
EXPECTED_SHA=$(awk '{print $1}' "$APK_SHA_FILE" | head -1)
ACTUAL_SHA=$(sha256sum "$APK" | awk '{print $1}')
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || fail "APK sha256 mismatch"
printf 'apk=%s\napk_sha256=%s\n' "$APK" "$ACTUAL_SHA" >>"$OUT/metadata.txt"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell is not active"

adb install -r -d "$APK" >"$OUT/adb-install.txt" 2>&1 || fail "ADB APK install failed; package was not uninstalled"
adb shell dumpsys package "$PACKAGE" >"$OUT/package.txt"
grep -Fq "versionName=helix-${SOURCE_COMMIT}" "$OUT/package.txt" || fail "installed package versionName does not match exact source commit"
APK_PATH=$(adb shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | awk -F: '/base\.apk$/{print $2; exit}')
[[ -n "$APK_PATH" ]] || fail "installed Quest base APK not found"
APK_TMP=$(mktemp --suffix=.apk)
if ! timeout 45s adb exec-out su -c "cat '$APK_PATH'" >"$APK_TMP"; then
    rm -f "$APK_TMP"
    fail "could not read installed APK for identity verification"
fi
python3 - "$APK_TMP" "$SOURCE_COMMIT" <<'PY'
import sys, zipfile
apk, expected = sys.argv[1], sys.argv[2].encode()
with zipfile.ZipFile(apk) as z:
    libs = [n for n in z.namelist() if n.endswith('.so')]
    if not libs:
        raise SystemExit("installed APK has no native libraries")
    if not any(expected in z.read(n) for n in libs):
        raise SystemExit("installed Quest native libraries do not contain exact source commit")
PY
rm -f "$APK_TMP"

echo "[3/8] Establishing clean desktop runtime ownership"
if command -v systemctl >/dev/null 2>&1; then
    mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
    for unit in "${active_units[@]}"; do systemctl --user stop "$unit" || true; done
fi
pkill -x wivrn-dashboard >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
for _ in $(seq 1 40); do
    if ! pgrep -x wivrn-server >/dev/null 2>&1 && ! pgrep -x wivrn-dashboard >/dev/null 2>&1; then break; fi
    sleep 0.1
done
! pgrep -x wivrn-server >/dev/null 2>&1 || fail "pre-existing wivrn-server survived cleanup"
! pgrep -x wivrn-dashboard >/dev/null 2>&1 || fail "pre-existing wivrn-dashboard survived cleanup"
if busctl --user --no-pager status io.github.wivrn.Server >/dev/null 2>&1; then
    fail "io.github.wivrn.Server is still owned before launch"
fi

adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb logcat -c >/dev/null 2>&1 || true

(
    cd "$WORKTREE"
    set +u
    # shellcheck disable=SC1090
    source "$PREFIX"
    set -u
    exec "$DASHBOARD"
) >"$OUT/dashboard-stdout.txt" 2>&1 &
DASH_PID=$!

SERVER_LOG=""
for _ in $(seq 1 120); do
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
[[ -n "$SERVER_LOG" && "$SERVER_LOG" == /* && -s "$SERVER_LOG" ]] || fail "dashboard did not report a valid server log"
mapfile -t server_pids < <(pgrep -x wivrn-server || true)
[[ ${#server_pids[@]} -eq 1 ]] || fail "expected exactly one wivrn-server, found ${#server_pids[@]}"
SERVER_PID=${server_pids[0]}
SERVER_EXE=$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server is $SERVER_EXE, expected $SERVER"
for _ in $(seq 1 100); do
    grep -F "$SOURCE_COMMIT" "$SERVER_LOG" >/dev/null 2>&1 && break
    sleep 0.1
done
grep -F "$SOURCE_COMMIT" "$SERVER_LOG" >/dev/null || fail "server log does not contain exact source commit before arm"

echo "[4/8] Launching exact Quest client and capturing durable startup provenance"
adb shell monkey -p "$PACKAGE" 1 >/dev/null 2>&1 || fail "could not launch Quest client"
QUEST_PROVENANCE="$OUT/quest-startup-provenance.txt"
: >"$QUEST_PROVENANCE"
for _ in $(seq 1 120); do
    if adb logcat -d -v threadtime 2>/dev/null | grep -F "Starting WiVRn version" | grep -F "$SOURCE_COMMIT" >"$QUEST_PROVENANCE"; then
        [[ -s "$QUEST_PROVENANCE" ]] && break
    fi
    sleep 0.1
done
[[ -s "$QUEST_PROVENANCE" ]] || fail "Quest startup log did not expose exact source commit before arm"
printf 'quest_startup_provenance=%s\nserver_log_source=%s\nserver_pid=%s\nserver_exe=%s\n' "$QUEST_PROVENANCE" "$SERVER_LOG" "$SERVER_PID" "$SERVER_EXE" >>"$OUT/metadata.txt"

echo
echo "RUNTIME TEST ARMED"
echo "  exact source:     ${SOURCE_COMMIT}"
echo "  server:           $SERVER_EXE"
echo "  server log:       $SERVER_LOG"
echo "  Quest provenance: $QUEST_PROVENANCE"
echo "  output:           $OUT"
echo
echo "Unplug USB and use VR normally. Prefer the dense VRChat workload that usually produces short stalls."
echo "When finished, return here and press Enter. Auto-stop is ${MAX_SECONDS}s."
if ! read -r -t "$MAX_SECONDS" _; then
    echo "Runtime duration limit reached."
fi

echo
echo "[5/8] Reconnect Quest USB"
echo "Reconnect USB now. Waiting up to ${USB_RECONNECT_SECONDS}s..."
timeout "${USB_RECONNECT_SECONDS}s" adb wait-for-device || fail "Quest did not reconnect over USB"
ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one reconnected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell unavailable after reconnect"

echo "[6/8] Collecting exact runtime evidence"
adb shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep 1
adb logcat -d -v threadtime >"$OUT/quest-logcat.txt" 2>&1 || fail "could not collect Quest logcat"
kill "$DASH_PID" >/dev/null 2>&1 || true
wait "$DASH_PID" >/dev/null 2>&1 || true
DASH_PID=""
sleep 2
[[ -s "$SERVER_LOG" ]] || fail "authoritative server log unavailable"
cp "$SERVER_LOG" "$OUT/server-log.txt"
grep -F "$SOURCE_COMMIT" "$OUT/server-log.txt" >/dev/null || fail "server log lost exact source identity"
grep -F "$SOURCE_COMMIT" "$QUEST_PROVENANCE" >/dev/null || fail "durable Quest startup provenance lost exact source identity"
printf 'finished_utc=%s\n' "$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

echo "[7/8] Reducing prediction-chain runtime signals"
python3 - "$OUT/server-log.txt" "$OUT/quest-logcat.txt" "$OUT/result.txt" <<'PY'
import re, sys
from pathlib import Path
server = Path(sys.argv[1]).read_text(errors='replace')
quest = Path(sys.argv[2]).read_text(errors='replace')
out = Path(sys.argv[3])

def count(text, pattern):
    return len(re.findall(pattern, text, re.M | re.I))

def summary_rows(text):
    rows=[]
    for line in re.findall(r'^.*Helix NVENC invalidation summary.*$', text, re.M):
        vals={k:int(v) for k,v in re.findall(r'\b([A-Za-z_]+)=(\d+)\b', line)}
        rows.append(vals)
    return rows

rows=summary_rows(server)
vals={
    'support_lines': count(server, r'Helix NVENC reference invalidation stream=\d+ supported='),
    'support_yes': count(server, r'Helix NVENC reference invalidation stream=\d+ supported=1'),
    'applied_events': count(server, r'Helix NVENC invalidated reference stream='),
    'error_events': count(server, r'Helix NVENC reference invalidation failed stream='),
    'gap_events': count(server, r'Helix gap timing event '),
    'idr_needed': count(server, r'IDR frame needed'),
    'idr_retargeted': count(server, r'IDR frame retargeted'),
    'inconsistent_idr': count(server, r'inconsistent IDR state'),
    'idr_timeouts': count(server, r'IDR frame timeout'),
    'encoder_timeouts': count(server, r'Timeout on stream'),
    'quest_incomplete_frames': count(quest, r'frame .* was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
    'quest_crash_markers': count(quest, r'(FATAL EXCEPTION|Fatal signal|ANR in org\.meumeu\.wivrn\.local)'),
    'summary_lines': len(rows),
}
for key in ['queued','applied','nonref_skipped','duplicate','overflow','stale','errors','fallback_idr','pending']:
    vals[f'summary_{key}'] = sum(r.get(key,0) for r in rows)

hard = any(vals[k] for k in ['inconsistent_idr','idr_timeouts','encoder_timeouts','quest_crash_markers'])
if vals['support_lines'] == 0:
    verdict='NONDIAGNOSTIC: NVENC invalidation capability was not observed in the runtime log'
elif vals['support_yes'] == 0:
    verdict='NONDIAGNOSTIC_UNSUPPORTED: active NVENC codec/GPU reported reference invalidation unsupported'
elif vals['summary_lines'] == 0:
    verdict='NONDIAGNOSTIC: encoder shutdown summary was not captured'
elif hard:
    verdict='FAIL: hard runtime/IDR/encoder/Quest failure signal occurred'
elif vals['summary_queued'] == 0:
    verdict='NONDIAGNOSTIC: runtime was healthy but no failed reference reached the deferred invalidation path'
elif vals['summary_applied'] == 0:
    verdict='FAIL_RECOVERY_EFFECTIVENESS: failed references reached the path but no NVENC reference invalidation succeeded'
elif vals['summary_pending'] != 0:
    verdict='FAIL_STATE_CLEANUP: invalidation work remained pending at shutdown'
elif vals['summary_errors'] or vals['summary_stale'] or vals['summary_overflow']:
    verdict='PROVISIONAL_PASS_MIXED: real NVENC invalidation succeeded and bounded IDR fallback was also exercised without hard failures'
else:
    verdict='PASS_RUNTIME_INVALIDATION: real NVENC reference invalidation succeeded with no hard failure or fallback-error signal'

lines=[verdict,'']+[f'{k}={v}' for k,v in vals.items()]
if vals['summary_queued']:
    lines.append(f'applied_per_queued={vals["summary_applied"]/vals["summary_queued"]:.6f}')
out.write_text('\n'.join(lines)+'\n')
print('\n'.join(lines))
PY

echo "[8/8] Runtime evidence preserved"
echo "evidence=$OUT"
echo "result=$OUT/result.txt"
echo "Tell me how the session felt (better / same / worse, and any short stalls you noticed) together with the result output."
