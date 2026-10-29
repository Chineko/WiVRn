#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_NET_ECHO_DIR:-"$HOME/helix-net-echo-$STAMP"}
DURATION=${HELIX_NET_DURATION_S:-300}
HZ=${HELIX_NET_HZ:-90}
PAYLOAD_BYTES=${HELIX_NET_PAYLOAD_BYTES:-1432}
PORT=${HELIX_NET_PORT:-39878}
RECEIVER_EXTRA_S=120
MOVE_SEND_TARGET_S=115
NDK_VERSION=29.0.14206865
REMOTE_BASE="/data/local/tmp/helix-net-echo-$STAMP"
REMOTE_BIN="$REMOTE_BASE.bin"
REMOTE_STATUS="$REMOTE_BASE.status"
REMOTE_ERR="$REMOTE_BASE.err"
REMOTE_PID="$REMOTE_BASE.pid"
BUILD_DIR=""
QUEST_STARTED=0

fail() { echo "Helix echo test: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in adb awk bash cc cut date df git grep ip mktemp pgrep pkill python3 sed sleep tr; do need "$cmd"; done

cleanup() {
    set +e
    if [[ "$QUEST_STARTED" -eq 1 ]]; then
        adb shell "if test -f '$REMOTE_PID'; then kill \$(cat '$REMOTE_PID') 2>/dev/null || true; fi" >/dev/null 2>&1 || true
    fi
    adb shell "rm -f '$REMOTE_BIN' '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'" >/dev/null 2>&1 || true
    [[ -n "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

wifi_frequency_mhz() {
    awk 'BEGIN{IGNORECASE=1} /frequency/ { for (i=1;i<=NF;i++) { v=$i; gsub(/[^0-9]/,"",v); if ((v+0)>=5000 && (v+0)<=8000) {print v; exit} } }'
}
wifi_bssid() {
    awk 'BEGIN{IGNORECASE=1} /bssid/ { for (i=1;i<=NF;i++) { v=$i; gsub(/[,;]/,"",v); if (split(v,a,":")==6) {print tolower(v); exit} } }'
}
find_ndk() {
    local candidates=()
    [[ -n "${HELIX_ANDROID_NDK:-}" ]] && candidates+=("$HELIX_ANDROID_NDK")
    [[ -n "${ANDROID_NDK_HOME:-}" ]] && candidates+=("$ANDROID_NDK_HOME")
    [[ -n "${ANDROID_NDK_ROOT:-}" ]] && candidates+=("$ANDROID_NDK_ROOT")
    [[ -n "${ANDROID_HOME:-}" ]] && candidates+=("$ANDROID_HOME/ndk/$NDK_VERSION")
    [[ -n "${ANDROID_SDK_ROOT:-}" ]] && candidates+=("$ANDROID_SDK_ROOT/ndk/$NDK_VERSION")
    if [[ -f "$ROOT/local.properties" ]]; then
        local sdk
        sdk=$(sed -n 's/^sdk\.dir=//p' "$ROOT/local.properties" | head -n1)
        [[ -n "$sdk" ]] && candidates+=("$sdk/ndk/$NDK_VERSION")
    fi
    local ndk
    for ndk in "${candidates[@]}"; do
        [[ -x "$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang" ]] && { printf '%s\n' "$ndk"; return 0; }
    done
    return 1
}

cd "$ROOT"
C_SRC="$ROOT/tools/helix-net-echo-test.c"
REDUCER="$ROOT/tools/helix-net-echo-test-reduce.py"
[[ -f "$C_SRC" && -f "$REDUCER" ]] || fail "missing echo-test sources"
bash -n "$0" || fail "runner failed Bash syntax check"
python3 -c 'from pathlib import Path; p=Path("tools/helix-net-echo-test-reduce.py"); compile(p.read_text(), str(p), "exec")' || fail "reducer failed Python syntax check"
git diff --quiet || fail "tracked working-tree changes are present"
git diff --cached --quiet || fail "staged working-tree changes are present"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2=="device" {n++} END{print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
[[ "$ADB_SERIAL" != *:* ]] || fail "wireless ADB would share the path under test; use USB for setup"

QUEST_ROUTE=$(adb shell "ip route show default 2>/dev/null | head -n1" | tr -d '\r')
QUEST_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell "ip -4 -o addr show dev '$QUEST_IF' scope global 2>/dev/null | head -n1" | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address"
HOST_ROUTE=$(ip route get "$QUEST_IP" | head -n1)
HOST_IF=$(awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
HOST_IP=$(awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
[[ -n "$HOST_IF" && -n "$HOST_IP" ]] || fail "could not determine host route"

WIFI_STATUS=$(adb shell "cmd wifi status 2>/dev/null || true" | tr -d '\r')
QUEST_FREQ=$(wifi_frequency_mhz <<<"$WIFI_STATUS")
QUEST_BSSID=$(wifi_bssid <<<"$WIFI_STATUS")
[[ "$QUEST_FREQ" =~ ^[0-9]+$ ]] || fail "could not determine Quest Wi-Fi frequency"
(( QUEST_FREQ >= 5925 && QUEST_FREQ <= 7125 )) || fail "Quest is not on 6 GHz (${QUEST_FREQ} MHz)"
[[ -n "$QUEST_BSSID" ]] || fail "could not determine Quest BSSID"

pkill -f 'build-dashboard/server/wivrn-dashboard' >/dev/null 2>&1 || true
pkill -f 'build-dashboard/server/wivrn-server' >/dev/null 2>&1 || true
adb shell "am force-stop org.meumeu.wivrn.local 2>/dev/null || true; am force-stop org.meumeu.wivrn 2>/dev/null || true" >/dev/null
if adb shell "pidof tcpdump 2>/dev/null" | tr -d '\r' | grep -Eq '[0-9]'; then fail "Quest tcpdump is running"; fi
if pgrep -f 'tcpdump.*wlan|tcpdump.*udp' >/dev/null 2>&1; then fail "host tcpdump appears to be running"; fi

NDK=$(find_ndk || true)
[[ -n "$NDK" ]] || fail "Android NDK $NDK_VERSION not found"
ANDROID_CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"
mkdir -p "$OUT"
BUILD_DIR=$(mktemp -d)
HOST_BIN="$BUILD_DIR/helix-net-echo-host"
QUEST_BIN="$BUILD_DIR/helix-net-echo-quest"
cc -O2 -std=c11 -Wall -Wextra -Werror "$C_SRC" -o "$HOST_BIN"
"$ANDROID_CC" -O2 -std=c11 -Wall -Wextra -Werror "$C_SRC" -o "$QUEST_BIN"
adb push "$QUEST_BIN" "$REMOTE_BIN" >/dev/null
adb shell "chmod 755 '$REMOTE_BIN'" >/dev/null
NOHUP=$(adb shell "which nohup 2>/dev/null" | tr -d '\r' | awk '/^\// {print; exit}')
[[ "$NOHUP" == /* ]] || fail "could not resolve Quest nohup"
QUEST_DURATION=$((DURATION + RECEIVER_EXTRA_S))

{
    echo "tool_commit=$(git rev-parse HEAD)"
    echo "experiment=bidirectional_low_load_udp_echo_localization"
    echo "adb_transport=usb_setup_and_retrieval_only"
    echo "usb_detached_during_workload=true"
    echo "host_ip=$HOST_IP"
    echo "host_if=$HOST_IF"
    echo "quest_ip=$QUEST_IP"
    echo "quest_if=$QUEST_IF"
    echo "quest_frequency_mhz=$QUEST_FREQ"
    echo "quest_bssid=$QUEST_BSSID"
    echo "duration_s=$DURATION"
    echo "hz=$HZ"
    echo "payload_bytes=$PAYLOAD_BYTES"
    echo "port=$PORT"
    echo "started_utc=$(date -u +%FT%TZ)"
} >"$OUT/metadata.txt"

adb shell "rm -f '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'; '$NOHUP' '$REMOTE_BIN' quest '$PORT' '$QUEST_DURATION' '$PAYLOAD_BYTES' '$REMOTE_STATUS' > /dev/null 2>'$REMOTE_ERR' </dev/null & echo \$! >'$REMOTE_PID'" >/dev/null
QUEST_STARTED=1
QUEST_LAUNCH_SECONDS=$SECONDS
sleep 0.5
adb shell "kill -0 \$(cat '$REMOTE_PID')" >/dev/null 2>&1 || fail "Quest echo responder exited before test armed"

echo
echo "HELIX BIDIRECTIONAL TEST ARMED"
echo "  host:       $HOST_IP via $HOST_IF"
echo "  Quest:      $QUEST_IP via $QUEST_IF"
echo "  Wi-Fi:      ${QUEST_FREQ} MHz / $QUEST_BSSID"
echo "  pattern:    ${HZ} Hz, 1 packet/tick, ${PAYLOAD_BYTES} B UDP echo"
echo "  duration:   ${DURATION} s"
echo
echo "Unplug USB, move the Quest to the normal VR position, then return here."
read -r -p "Press Enter after USB is unplugged and the Quest is in position: " _
ADB_NOW=$(adb devices | awk 'NR>1 && $2=="device" {n++} END{print n+0}')
[[ "$ADB_NOW" -eq 0 ]] || fail "Quest is still visible to ADB"
MOVE_ELAPSED=$((SECONDS - QUEST_LAUNCH_SECONDS))
(( MOVE_ELAPSED < MOVE_SEND_TARGET_S )) || fail "setup took too long; reconnect USB and rerun"
WAIT_TO_SEND=$((MOVE_SEND_TARGET_S - MOVE_ELAPSED))
echo "Quest detached. Starting workload in ${WAIT_TO_SEND}s at the fixed timing point..."
sleep "$WAIT_TO_SEND"
echo "Starting 300-second bidirectional workload. Do not reconnect USB until prompted."

set +e
"$HOST_BIN" host "$QUEST_IP" "$PORT" "$DURATION" "$HZ" "$PAYLOAD_BYTES" "$OUT/host.bin" >"$OUT/host-status.txt" 2>"$OUT/host-stderr.txt"
HOST_RC=$?
set -e
[[ "$HOST_RC" -eq 0 ]] || fail "host probe failed; evidence preserved at $OUT"

ELAPSED=$((SECONDS - QUEST_LAUNCH_SECONDS))
REMAINING=$((QUEST_DURATION - ELAPSED + 1))
(( REMAINING > 0 )) && sleep "$REMAINING"

echo
echo "WORKLOAD COMPLETE"
echo "Reconnect the Quest over USB now. Do not enable wireless ADB."
read -r -p "Press Enter after USB ADB has reconnected: " _
ADB_COUNT_AFTER=$(adb devices | awk 'NR>1 && $2=="device" {n++} END{print n+0}')
[[ "$ADB_COUNT_AFTER" -eq 1 ]] || fail "expected exactly one USB ADB device after reconnect, found $ADB_COUNT_AFTER"
ADB_SERIAL_AFTER=$(adb devices | awk 'NR>1 && $2=="device" {print $1; exit}')
[[ "$ADB_SERIAL_AFTER" != *:* ]] || fail "wireless ADB is connected after workload"
[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected device does not match setup Quest"
QUEST_STARTED=0
adb exec-out cat "$REMOTE_STATUS" >"$OUT/quest-status.txt" || fail "failed to retrieve Quest status"
adb exec-out cat "$REMOTE_ERR" >"$OUT/quest-stderr.txt" || true

WIFI_STATUS_AFTER=$(adb shell "cmd wifi status 2>/dev/null || true" | tr -d '\r')
QUEST_FREQ_AFTER=$(wifi_frequency_mhz <<<"$WIFI_STATUS_AFTER")
QUEST_BSSID_AFTER=$(wifi_bssid <<<"$WIFI_STATUS_AFTER")
ENDPOINT_CONSISTENT=true
[[ "$QUEST_FREQ_AFTER" == "$QUEST_FREQ" ]] || ENDPOINT_CONSISTENT=false
[[ "$QUEST_BSSID_AFTER" == "$QUEST_BSSID" ]] || ENDPOINT_CONSISTENT=false
{
    echo "quest_frequency_mhz_after=$QUEST_FREQ_AFTER"
    echo "quest_bssid_after=$QUEST_BSSID_AFTER"
    echo "wifi_endpoint_state_consistent=$ENDPOINT_CONSISTENT"
    echo "finished_utc=$(date -u +%FT%TZ)"
} >>"$OUT/metadata.txt"

adb shell "rm -f '$REMOTE_BIN' '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'" >/dev/null 2>&1 || true
python3 "$REDUCER" "$OUT"
trap - EXIT INT TERM
rm -rf "$BUILD_DIR"
BUILD_DIR=""
echo
echo "Bidirectional run complete. Raw evidence: $OUT"
echo "Upload the reduced .tar.gz bundle printed above."
