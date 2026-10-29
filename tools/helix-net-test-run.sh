#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_NET_TEST_DIR:-"$HOME/helix-net-test-$STAMP"}
DURATION=${HELIX_NET_DURATION_S:-300}
HZ=${HELIX_NET_HZ:-90}
PACKETS_PER_BURST=${HELIX_NET_PACKETS_PER_BURST:-56}
SPACING_US=${HELIX_NET_SPACING_US:-50}
PAYLOAD_BYTES=${HELIX_NET_PAYLOAD_BYTES:-1432}
PORT=${HELIX_NET_PORT:-39877}
RECEIVER_EXTRA_S=3
NDK_VERSION=29.0.14206865
REMOTE_BASE="/data/local/tmp/helix-net-test-$STAMP"
REMOTE_BIN="$REMOTE_BASE.bin"
REMOTE_RX="$REMOTE_BASE.receiver.bin"
REMOTE_STATUS="$REMOTE_BASE.receiver.status"
REMOTE_ERR="$REMOTE_BASE.receiver.err"
REMOTE_PID="$REMOTE_BASE.receiver.pid"
BUILD_DIR=""
RECEIVER_STARTED=0

fail() {
    echo "Helix net test: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

for cmd in adb awk bash cc cut date df git grep ip mktemp pgrep pkill python3 sed sleep timeout tr; do
    need "$cmd"
done

cleanup() {
    set +e
    if [[ "$RECEIVER_STARTED" -eq 1 ]]; then
        adb shell "if test -f '$REMOTE_PID'; then kill \$(cat '$REMOTE_PID') 2>/dev/null || true; fi" >/dev/null 2>&1 || true
    fi
    adb shell "rm -f '$REMOTE_BIN' '$REMOTE_RX' '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'" >/dev/null 2>&1 || true
    [[ -n "$BUILD_DIR" ]] && rm -rf "$BUILD_DIR"
}
trap cleanup EXIT INT TERM

wifi_frequency_mhz() {
    awk 'BEGIN{IGNORECASE=1} /frequency/ { for (i=1; i<=NF; i++) { v=$i; gsub(/[^0-9]/, "", v); if ((v+0) >= 5000 && (v+0) <= 8000) { print v; exit } } }'
}

wifi_bssid() {
    awk 'BEGIN{IGNORECASE=1} /bssid/ { for (i=1;i<=NF;i++) { v=$i; gsub(/[,;]/, "", v); n=split(v, a, ":"); if (n == 6) { print tolower(v); exit } } }'
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
        if [[ -x "$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang" ]]; then
            printf '%s\n' "$ndk"
            return 0
        fi
    done
    return 1
}

cd "$ROOT"

C_SRC="$ROOT/tools/helix-net-test.c"
REDUCER="$ROOT/tools/helix-net-test-reduce.py"
[[ -f "$C_SRC" ]] || fail "missing $C_SRC"
[[ -f "$REDUCER" ]] || fail "missing $REDUCER"
bash -n "$0" || fail "runner failed Bash syntax check"
python3 -c 'from pathlib import Path; p=Path("tools/helix-net-test-reduce.py"); compile(p.read_text(), str(p), "exec")' \
    || fail "reducer failed Python syntax check"
git diff --quiet || fail "tracked working-tree changes are present"
git diff --cached --quiet || fail "staged working-tree changes are present"

for value_name in DURATION HZ PACKETS_PER_BURST SPACING_US PAYLOAD_BYTES PORT; do
    value=${!value_name}
    [[ "$value" =~ ^[0-9]+$ ]] || fail "$value_name must be an integer"
done
(( DURATION >= 10 && DURATION <= 1800 )) || fail "duration must be 10..1800 seconds"
(( HZ >= 1 && HZ <= 1000 )) || fail "HZ must be 1..1000"
(( PACKETS_PER_BURST >= 1 && PACKETS_PER_BURST <= 10000 )) || fail "PACKETS_PER_BURST out of range"
(( SPACING_US >= 1 && SPACING_US <= 1000000 )) || fail "SPACING_US out of range"
(( PAYLOAD_BYTES >= 40 && PAYLOAD_BYTES <= 65000 )) || fail "PAYLOAD_BYTES out of range"
(( PORT >= 1024 && PORT <= 65535 )) || fail "PORT out of range"
PERIOD_US=$((1000000 / HZ))
OCCUPIED_US=$(((PACKETS_PER_BURST - 1) * SPACING_US))
(( OCCUPIED_US < PERIOD_US )) || fail "burst occupancy ${OCCUPIED_US}us does not fit ${PERIOD_US}us period"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
if [[ "$ADB_SERIAL" == *:* ]]; then
    fail "wireless ADB would share the path under test; connect Quest over USB for this experiment"
fi

QUEST_ROUTE=$(adb shell "ip route show default 2>/dev/null | head -n1" | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell "ip -4 -o addr show dev '$QUEST_IF' scope global 2>/dev/null | head -n1" | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address on $QUEST_IF"

HOST_ROUTE=$(ip route get "$QUEST_IP" | head -n1)
HOST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
HOST_IP=$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
[[ -n "$HOST_IF" && -n "$HOST_IP" ]] || fail "could not determine host route to Quest $QUEST_IP"

WIFI_STATUS=$(adb shell "cmd wifi status 2>/dev/null || true" | tr -d '\r')
QUEST_FREQ=$(wifi_frequency_mhz <<<"$WIFI_STATUS")
QUEST_BSSID=$(wifi_bssid <<<"$WIFI_STATUS")
[[ "$QUEST_FREQ" =~ ^[0-9]+$ ]] || fail "could not determine Quest Wi-Fi frequency"
(( QUEST_FREQ >= 5925 && QUEST_FREQ <= 7125 )) || fail "Quest is not on 6 GHz (${QUEST_FREQ} MHz)"
[[ -n "$QUEST_BSSID" ]] || fail "could not determine Quest BSSID"

# The first synthetic run deliberately excludes WiVRn and packet capture.
if pgrep -f 'build-dashboard/server/wivrn-dashboard' >/dev/null 2>&1; then
    echo "Helix net test: stopping desktop WiVRn dashboard"
    pkill -f 'build-dashboard/server/wivrn-dashboard' || true
    sleep 1
fi
if pgrep -f 'build-dashboard/server/wivrn-server' >/dev/null 2>&1; then
    echo "Helix net test: stopping desktop WiVRn server"
    pkill -f 'build-dashboard/server/wivrn-server' || true
    sleep 1
fi
adb shell "am force-stop org.meumeu.wivrn.local 2>/dev/null || true; am force-stop org.meumeu.wivrn 2>/dev/null || true" >/dev/null

if adb shell "pidof tcpdump 2>/dev/null" | tr -d '\r' | grep -Eq '[0-9]'; then
    fail "Quest tcpdump is already running; stop it so the first synthetic run has no capture observer"
fi
if pgrep -f 'tcpdump.*wlan|tcpdump.*udp' >/dev/null 2>&1; then
    fail "host tcpdump appears to be running; stop it for the no-capture synthetic baseline"
fi

NDK=$(find_ndk || true)
[[ -n "$NDK" ]] || fail "Android NDK $NDK_VERSION not found; expected the same NDK used by this WiVRn checkout"
ANDROID_CC="$NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android29-clang"
[[ -x "$ANDROID_CC" ]] || fail "missing Android compiler $ANDROID_CC"

mkdir -p "$OUT"
BUILD_DIR=$(mktemp -d)
HOST_BIN="$BUILD_DIR/helix-net-test-host"
QUEST_BIN="$BUILD_DIR/helix-net-test-quest"

cc -O2 -std=c11 -Wall -Wextra -Werror "$C_SRC" -o "$HOST_BIN"
"$ANDROID_CC" -O2 -std=c11 -Wall -Wextra -Werror "$C_SRC" -o "$QUEST_BIN"

adb push "$QUEST_BIN" "$REMOTE_BIN" >/dev/null
adb shell "chmod 755 '$REMOTE_BIN'" >/dev/null

QUEST_FREE_KB=$(adb shell "df -Pk /data/local/tmp 2>/dev/null | tail -n1" | tr -d '\r' | awk '{print $4}')
HOST_FREE_KB=$(df -Pk "$OUT" | tail -n1 | awk '{print $4}')
[[ "$QUEST_FREE_KB" =~ ^[0-9]+$ ]] || fail "could not determine Quest free storage"
(( QUEST_FREE_KB >= 524288 )) || fail "Quest has less than 512 MiB free under /data/local/tmp"
(( HOST_FREE_KB >= 1048576 )) || fail "host has less than 1 GiB free for synthetic test evidence"

RECEIVER_DURATION=$((DURATION + RECEIVER_EXTRA_S))
NOHUP=$(adb shell "which nohup 2>/dev/null" | tr -d '\r' | awk '/^\// {print; exit}')
[[ "$NOHUP" == /* ]] || fail "could not resolve Quest nohup executable"

{
    echo "tool_commit=$(git rev-parse HEAD)"
    echo "experiment=standalone_pc_to_quest_udp_no_wivrn_no_tcpdump"
    echo "adb_transport=usb"
    echo "host_ip=$HOST_IP"
    echo "host_if=$HOST_IF"
    echo "quest_ip=$QUEST_IP"
    echo "quest_if=$QUEST_IF"
    echo "quest_frequency_mhz=$QUEST_FREQ"
    echo "quest_bssid=$QUEST_BSSID"
    echo "duration_s=$DURATION"
    echo "receiver_duration_s=$RECEIVER_DURATION"
    echo "hz=$HZ"
    echo "packets_per_burst=$PACKETS_PER_BURST"
    echo "spacing_us=$SPACING_US"
    echo "payload_bytes=$PAYLOAD_BYTES"
    echo "port=$PORT"
    echo "burst_occupied_us=$OCCUPIED_US"
    echo "host_free_kb_before=$HOST_FREE_KB"
    echo "quest_free_kb_before=$QUEST_FREE_KB"
    echo "started_utc=$(date -u +%FT%TZ)"
} >"$OUT/metadata.txt"

adb shell "rm -f '$REMOTE_RX' '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'; \
'$NOHUP' '$REMOTE_BIN' recv '$PORT' '$RECEIVER_DURATION' '$PAYLOAD_BYTES' '$REMOTE_RX' \
>'$REMOTE_STATUS' 2>'$REMOTE_ERR' </dev/null & echo \$! >'$REMOTE_PID'" >/dev/null
RECEIVER_STARTED=1
sleep 0.5
adb shell "kill -0 \$(cat '$REMOTE_PID')" >/dev/null 2>&1 || {
    adb shell "cat '$REMOTE_ERR' 2>/dev/null || true" >&2
    fail "Quest synthetic receiver exited before test armed"
}

echo
echo "HELIX SYNTHETIC TEST ARMED"
echo "  WiVRn:      stopped"
echo "  tcpdump:    disabled"
echo "  host:       $HOST_IP via $HOST_IF"
echo "  Quest:      $QUEST_IP via $QUEST_IF"
echo "  Wi-Fi:      ${QUEST_FREQ} MHz / $QUEST_BSSID"
echo "  pattern:    ${HZ} Hz, ${PACKETS_PER_BURST} packets/burst, ${SPACING_US} us spacing, ${PAYLOAD_BYTES} B UDP"
echo "  duration:   ${DURATION} s"
echo "  output:     $OUT"
echo
echo "No ADB command will run during the sender workload."

set +e
"$HOST_BIN" send "$QUEST_IP" "$PORT" "$DURATION" "$HZ" "$PACKETS_PER_BURST" "$SPACING_US" "$PAYLOAD_BYTES" "$OUT/sender.bin" \
    >"$OUT/sender-status.txt" 2>"$OUT/sender-stderr.txt"
SENDER_RC=$?
set -e
echo "sender_exit_code=$SENDER_RC" >>"$OUT/metadata.txt"
[[ "$SENDER_RC" -eq 0 ]] || fail "host sender failed; evidence preserved at $OUT"

# Receiver was started before the sender and intentionally runs a few seconds longer.
sleep $((RECEIVER_EXTRA_S + 1))
if adb shell "kill -0 \$(cat '$REMOTE_PID') 2>/dev/null" >/dev/null 2>&1; then
    fail "Quest receiver did not exit after its bounded duration; evidence preserved on device at $REMOTE_BASE.*"
fi
RECEIVER_STARTED=0

adb exec-out cat "$REMOTE_RX" >"$OUT/receiver.bin" || fail "failed to retrieve Quest receiver log"
adb exec-out cat "$REMOTE_STATUS" >"$OUT/receiver-status.txt" || fail "failed to retrieve Quest receiver status"
adb exec-out cat "$REMOTE_ERR" >"$OUT/receiver-stderr.txt" || true

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

adb shell "rm -f '$REMOTE_BIN' '$REMOTE_RX' '$REMOTE_STATUS' '$REMOTE_ERR' '$REMOTE_PID'" >/dev/null 2>&1 || true

echo
echo "Reducing standalone UDP evidence..."
python3 "$REDUCER" "$OUT"

trap - EXIT INT TERM
rm -rf "$BUILD_DIR"
BUILD_DIR=""

echo
echo "Synthetic run complete. Raw evidence: $OUT"
echo "Upload the reduced .tar.gz bundle printed above."
