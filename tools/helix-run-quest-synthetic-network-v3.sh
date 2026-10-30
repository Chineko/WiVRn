#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"
SOURCE_BRANCH="helix-encoded-nvenc-torture-fix-v3-built"
BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v3-build-20261030-185452"
META="$BUILD_ROOT/metadata.txt"
SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"
APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v3-951ce95cd2ea.apk"
SERVER_SHA256="1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af"
APK_SHA256="1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c"
ARTIFACT_GATE="artifact_gate=PASS encoded-nvenc-fix-v3-server-apk-exact-source"
PACKAGE="org.meumeu.wivrn.local"
ACTIVITY="org.meumeu.wivrn.MainActivity"
TIMEOUT_SECONDS=240

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git adb sha256sum awk sed grep ip python3 timeout stdbuf systemctl pkill; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done

[[ -s "$META" ]] || fail "metadata missing: $META"
[[ -s "$SERVER" && -x "$SERVER" ]] || fail "server missing/not executable: $SERVER"
[[ -s "$APK" ]] || fail "APK missing: $APK"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"
grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "metadata remote-head mismatch"
grep -Fqx "$ARTIFACT_GATE" "$META" || fail "artifact gate missing"
VERSION_NAME="$(sed -n 's/^version_name=//p' "$META" | tail -1)"
[[ -n "$VERSION_NAME" ]] || fail "metadata version_name missing"

git fetch -q origin "$SOURCE_BRANCH"
[[ "$(git rev-parse "refs/remotes/origin/$SOURCE_BRANCH")" == "$SOURCE_COMMIT" ]] || fail "remote source branch moved"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'constexpr double promotion_threshold = 0.95;' || fail "95% promotion gate missing"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 's.catastrophic == 0' || fail "catastrophic=0 gate missing"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY' || fail "oracle sanity marker missing"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_RESULT' || fail "result marker missing"
git show "$SOURCE_COMMIT:server/main.cpp" | grep -Fq -- '--helix-synthetic-transport' || fail "synthetic transport CLI missing"
git show "$SOURCE_COMMIT:server/CMakeLists.txt" | grep -Fq 'helix_synthetic_transport.cpp' || fail "synthetic transport missing from server target"

echo 'NETWORK_PREFLIGHT_ARTIFACT=PASS exact-v3-source-server-apk'

adb get-state >/dev/null 2>&1 || fail "Quest not visible to adb"
serial="$(adb get-serialno | tr -d '\r')"
[[ -n "$serial" && "$serial" != unknown ]] || fail "ADB serial unavailable"

forward_out="$(adb forward --list 2>/dev/null || true)"
reverse_out="$(adb reverse --list 2>/dev/null || true)"
[[ -z "$forward_out" ]] || fail "ADB forward exists; refusing ambiguous transport path: $forward_out"
[[ -z "$reverse_out" ]] || fail "ADB reverse exists; refusing ambiguous transport path: $reverse_out"

quest_ip="$(adb shell ip -4 addr show wlan0 2>/dev/null | awk '/inet / && !found {sub(/\/.*/,"",$2); value=$2; found=1} END {if(found) print value}' | tr -d '\r')"
[[ -n "$quest_ip" ]] || fail "Quest wlan0 IPv4 address unavailable"
route="$(ip -4 route get "$quest_ip" 2>/dev/null | head -1)"
[[ -n "$route" ]] || fail "host has no route to Quest wlan0 address $quest_ip"
echo "$route" | grep -Eq ' dev (lo|usb[^ ]*|rndis[^ ]*|adb[^ ]*) ' && fail "route to Quest is not accepted network path: $route"
host_ip="$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"
[[ -n "$host_ip" ]] || fail "host route source missing"
echo "NETWORK_PATH_GATE=PASS quest_wlan0=$quest_ip host_route=$route host_ip=$host_ip adb_forward=none adb_reverse=none"

echo "Installing exact Quest APK version=$VERSION_NAME"
adb -s "$serial" install -r -d "$APK" >/dev/null || fail "APK install failed"
package_dump="$(adb -s "$serial" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r')"
printf '%s\n' "$package_dump" | grep -Fq "versionName=$VERSION_NAME" || fail "installed versionName mismatch for proven package $PACKAGE"
echo "Quest package=$PACKAGE version=$VERSION_NAME"

evidence="$HOME/helix-synthetic-network-runtime-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$evidence"
printf '%s\n' "$package_dump" >"$evidence/package.txt"
printf 'source_commit=%s\nserver_sha256=%s\napk_sha256=%s\npackage=%s\nversion=%s\nquest_wlan0=%s\nhost_ip=%s\nhost_route=%s\n' \
    "$SOURCE_COMMIT" "$SERVER_SHA256" "$APK_SHA256" "$PACKAGE" "$VERSION_NAME" "$quest_ip" "$host_ip" "$route" >"$evidence/metadata.txt"

service_was_active=0
systemctl --user is-active --quiet wivrn.service && service_was_active=1 || true
cleanup(){
    set +e
    [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null
    adb -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1
    if (( service_was_active )); then
        systemctl --user start wivrn.service >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT INT TERM

systemctl --user stop wivrn.service >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
sleep 1

adb -s "$serial" logcat -c >/dev/null 2>&1 || true
adb -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true

stdbuf -oL -eL "$SERVER" --helix-synthetic-transport --no-fork --no-publish-service >"$evidence/server-log.txt" 2>&1 &
server_pid=$!
sleep 2
kill -0 "$server_pid" 2>/dev/null || { cat "$evidence/server-log.txt" >&2; fail "server exited before Quest launch"; }

# Explicit LAN URI: ADB launches the activity only; WiVRn TCP/UDP traffic goes to host_ip.
adb -s "$serial" shell am start -W -a android.intent.action.VIEW -d "wivrn+tcp://${host_ip}" -n "$PACKAGE/$ACTIVITY" >"$evidence/launch.txt" 2>&1 || fail "Quest launch failed"

connected=0
for _ in $(seq 1 200); do
    kill -0 "$server_pid" 2>/dev/null || fail "server exited before trusted Quest connection"
    grep -Fq 'To pair a new headset use PIN code:' "$evidence/server-log.txt" && fail "server entered pairing mode; existing trust state was not visible"
    if grep -Fq 'Client connected' "$evidence/server-log.txt"; then connected=1; break; fi
    sleep .1
done
[[ "$connected" -eq 1 ]] || fail "Quest did not establish trusted LAN connection"
echo 'NETWORK_TRUSTED_CONNECTION=PASS explicit-wivrn-tcp-uri'

set +e
timeout "$TIMEOUT_SECONDS" bash -c '
  log="$1"; pid="$2"
  while kill -0 "$pid" 2>/dev/null; do
    if grep -Fq "HELIX_SYNTHETIC_TRANSPORT_EXIT" "$log"; then exit 0; fi
    sleep 1
  done
  grep -Fq "HELIX_SYNTHETIC_TRANSPORT_EXIT" "$log"
' _ "$evidence/server-log.txt" "$server_pid"
wait_status=$?
set -e

adb -s "$serial" logcat -d >"$evidence/logcat.txt" 2>/dev/null || true
[[ $wait_status -eq 0 ]] || { tail -200 "$evidence/server-log.txt" >&2; fail "synthetic network battery timed out/exited without completion"; }

grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=1' "$evidence/server-log.txt" || fail "oracle sanity did not pass"
result_line="$(grep 'HELIX_SYNTHETIC_TRANSPORT_RESULT' "$evidence/server-log.txt" | tail -1 || true)"
[[ -n "$result_line" ]] || fail "result line missing"
exit_line="$(grep 'HELIX_SYNTHETIC_TRANSPORT_EXIT' "$evidence/server-log.txt" | tail -1 || true)"
echo "$exit_line" | grep -Fq 'result=0' || fail "synthetic runner exited nonzero: $exit_line"

python3 - "$result_line" <<'PY'
import re, sys
line=sys.argv[1]
vals=dict(re.findall(r'(pass|good_ratio|fallback_ratio|recorded_total|recorded_good|recorded_ratio|envelope_ratio|ordering_ratio|rtx_ratio|catastrophic)=([0-9.]+)', line))
required=['pass','good_ratio','fallback_ratio','recorded_total','recorded_good','recorded_ratio','envelope_ratio','ordering_ratio','rtx_ratio','catastrophic']
missing=[k for k in required if k not in vals]
if missing:
    raise SystemExit('FAIL: result fields missing: '+','.join(missing))
for k in ['good_ratio','fallback_ratio','recorded_ratio','envelope_ratio','ordering_ratio','rtx_ratio']:
    if float(vals[k]) < 0.95:
        raise SystemExit(f'FAIL: {k}={vals[k]} below 0.95')
if int(float(vals['recorded_total'])) != 10 or int(float(vals['recorded_good'])) != 10:
    raise SystemExit(f"FAIL: recorded corpus {vals['recorded_good']}/{vals['recorded_total']} expected 10/10")
if int(float(vals['catastrophic'])) != 0:
    raise SystemExit('FAIL: catastrophic='+vals['catastrophic'])
if vals['pass'] != '1':
    raise SystemExit('FAIL: production synthetic pass bit='+vals['pass'])
print('NETWORK_SYNTHETIC_GATE=PASS ratios>=0.95 recorded=10/10 catastrophic=0')
PY

printf '%s\n' "$result_line"
echo "EVIDENCE=$evidence"
echo 'verdict=QUEST_SYNTHETIC_NETWORK_PASS'
