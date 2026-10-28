#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-$STAMP"}
QUEST_TMP="/data/local/tmp/helix-blackout-$STAMP"
RUNTIME_BASE=${HELIX_RUNTIME_BASE:-ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a}
DASHBOARD_PID=""
HOST_TCPDUMP_PID=""
QUEST_CAPTURE_ADB_PID=""
QUEST_LOGCAT_ADB_PID=""
CAPTURE_ACTIVE=0

fail() {
    echo "Helix capture: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

for cmd in adb awk cut date df git grep ip python3 sudo tcpdump timeout wc; do
    need "$cmd"
done

cleanup_capture() {
    set +e
    if [[ "$CAPTURE_ACTIVE" -eq 1 ]]; then
        if adb shell su -c "test -f $QUEST_TMP.tcpdump.pid" >/dev/null 2>&1; then
            adb shell su -c "kill -2 \$(cat $QUEST_TMP.tcpdump.pid) 2>/dev/null || true" >/dev/null 2>&1
        fi
        if adb shell su -c "test -f $QUEST_TMP.logcat.pid" >/dev/null 2>&1; then
            adb shell su -c "kill \$(cat $QUEST_TMP.logcat.pid) 2>/dev/null || true" >/dev/null 2>&1
        fi
        if [[ -n "$HOST_TCPDUMP_PID" ]]; then
            sudo kill -2 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        fi
        sleep 1
        [[ -n "$QUEST_CAPTURE_ADB_PID" ]] && kill "$QUEST_CAPTURE_ADB_PID" >/dev/null 2>&1 || true
        [[ -n "$QUEST_LOGCAT_ADB_PID" ]] && kill "$QUEST_LOGCAT_ADB_PID" >/dev/null 2>&1 || true
        [[ -n "$HOST_TCPDUMP_PID" ]] && sudo kill -15 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        [[ -n "$QUEST_CAPTURE_ADB_PID" ]] && wait "$QUEST_CAPTURE_ADB_PID" >/dev/null 2>&1 || true
        [[ -n "$QUEST_LOGCAT_ADB_PID" ]] && wait "$QUEST_LOGCAT_ADB_PID" >/dev/null 2>&1 || true
        [[ -n "$HOST_TCPDUMP_PID" ]] && wait "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        CAPTURE_ACTIVE=0
    fi
}

cleanup_all() {
    cleanup_capture
    if [[ -n "$DASHBOARD_PID" ]]; then
        kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
        wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
        DASHBOARD_PID=""
    fi
}
trap cleanup_all EXIT INT TERM

mkdir -p "$OUT"

git -C "$ROOT" cat-file -e "$RUNTIME_BASE^{commit}" 2>/dev/null || fail "runtime base $RUNTIME_BASE is not available locally"
if ! git -C "$ROOT" diff --quiet "$RUNTIME_BASE" -- . ':(exclude)docs/**' ':(exclude)tools/**'; then
    fail "runtime source differs from validated base $RUNTIME_BASE; stop before collecting data"
fi
if ! git -C "$ROOT" diff --quiet || ! git -C "$ROOT" diff --cached --quiet; then
    fail "tracked working tree changes are present; stop before collecting data"
fi

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root check failed: adb shell su -c id did not return uid=0"

QUEST_ROUTE=$(adb shell su -c 'ip route show default 2>/dev/null | head -n1' | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell su -c "ip -4 -o addr show dev $QUEST_IF scope global 2>/dev/null | head -n1" | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address on $QUEST_IF"

HOST_ROUTE=$(ip route get "$QUEST_IP" | head -n1)
HOST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
HOST_IP=$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
[[ -n "$HOST_IF" && -n "$HOST_IP" ]] || fail "could not determine host route to Quest $QUEST_IP"

QUEST_TCPDUMP=$(adb shell su -c 'command -v tcpdump 2>/dev/null || which tcpdump 2>/dev/null' | tr -d '\r' | tail -n1)
[[ -n "$QUEST_TCPDUMP" ]] || fail "tcpdump is not available on the rooted Quest"
FILTER="udp and src host $HOST_IP and dst host $QUEST_IP"
CAPTURE_BUFFER_KIB=16384

tcpdump -d "$FILTER" >/dev/null 2>&1 || fail "host tcpdump rejected capture filter: $FILTER"
adb shell su -c "$QUEST_TCPDUMP -d '$FILTER'" >/dev/null 2>&1 || fail "Quest tcpdump rejected capture filter: $FILTER"

PRE="$QUEST_TMP-preflight.pcap"
adb shell su -c "rm -f $PRE" >/dev/null 2>&1 || true
if ! timeout 8s adb shell su -c "$QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -c 1 -w $PRE" >/dev/null 2>&1; then
    fail "Quest tcpdump preflight failed on $QUEST_IF; stop before doing a VR run"
fi
PRE_BYTES=$(adb shell su -c "wc -c < $PRE" 2>/dev/null | tr -d '\r ' || echo 0)
[[ "$PRE_BYTES" =~ ^[0-9]+$ && "$PRE_BYTES" -gt 24 ]] || fail "Quest tcpdump preflight did not produce a valid local PCAP"
adb shell su -c "rm -f $PRE" >/dev/null 2>&1 || true

QUEST_FREE_KB=$(adb shell su -c 'df -Pk /data/local/tmp 2>/dev/null | tail -n1' | tr -d '\r' | awk '{print $4}')
[[ "$QUEST_FREE_KB" =~ ^[0-9]+$ ]] || fail "could not determine free Quest storage"
(( QUEST_FREE_KB >= 524288 )) || fail "Quest has less than 512 MiB free under /data/local/tmp"
HOST_FREE_KB=$(df -Pk "$OUT" | tail -n1 | awk '{print $4}')
(( HOST_FREE_KB >= 1048576 )) || fail "host has less than 1 GiB free for paired captures"

sudo -v
TOOL_COMMIT=$(git -C "$ROOT" rev-parse HEAD)

{
    echo "setup_started_utc=$(date -u +%FT%TZ)"
    echo "host_tz_offset=$(date +%z)"
    echo "repo=$ROOT"
    echo "capture_tool_commit=$TOOL_COMMIT"
    echo "runtime_source_base=$RUNTIME_BASE"
    echo "runtime_source_equivalent=true"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
    echo "host_ip=$HOST_IP"
    echo "host_if=$HOST_IF"
    echo "quest_ip=$QUEST_IP"
    echo "quest_if=$QUEST_IF"
    echo "capture_filter=$FILTER"
    echo "capture_buffer_kib=$CAPTURE_BUFFER_KIB"
    echo "quest_epoch_ns=$(adb shell su -c 'date +%s%N' 2>/dev/null | tr -d '\r' || true)"
} >"$OUT/metadata.txt"

snapshot_host() {
    local tag=$1
    ip -s link show dev "$HOST_IF" >"$OUT/host-link-$tag.txt" 2>&1 || true
    if command -v tc >/dev/null 2>&1; then tc -s qdisc show dev "$HOST_IF" >"$OUT/host-qdisc-$tag.txt" 2>&1 || true; fi
    if command -v ethtool >/dev/null 2>&1; then ethtool -S "$HOST_IF" >"$OUT/host-ethtool-$tag.txt" 2>&1 || true; fi
    cat /proc/net/snmp >"$OUT/host-snmp-$tag.txt" 2>/dev/null || true
    cat /proc/net/netstat >"$OUT/host-netstat-$tag.txt" 2>/dev/null || true
}

snapshot_quest() {
    local tag=$1
    adb shell su -c "ip -s link show dev $QUEST_IF" >"$OUT/quest-link-$tag.txt" 2>&1 || true
    adb shell su -c 'cat /proc/net/snmp' >"$OUT/quest-snmp-$tag.txt" 2>&1 || true
    adb shell su -c 'cat /proc/net/netstat' >"$OUT/quest-netstat-$tag.txt" 2>&1 || true
    adb shell su -c 'cat /proc/net/udp; cat /proc/net/udp6' >"$OUT/quest-udp-$tag.txt" 2>&1 || true
    adb shell su -c 'ss -u -a -m -i 2>/dev/null || true' >"$OUT/quest-sockets-$tag.txt" 2>&1 || true
    adb shell su -c 'cmd wifi status 2>/dev/null || true' >"$OUT/quest-wifi-status-$tag.txt" 2>&1 || true
}

snapshot_host before
snapshot_quest before

CAPTURE_START_EPOCH_NS=$(date +%s%N)
echo "capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS" >>"$OUT/metadata.txt"
echo "capture_started_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

adb shell su -c "rm -f $QUEST_TMP.pcap $QUEST_TMP.tcpdump.pid $QUEST_TMP.tcpdump.err $QUEST_TMP.logcat $QUEST_TMP.logcat.pid $QUEST_TMP.logcat.err" >/dev/null 2>&1 || true
adb shell su -c 'logcat -c' >/dev/null 2>&1 || true
CAPTURE_ACTIVE=1

adb shell su -c "sh -c 'echo \$\$ > $QUEST_TMP.tcpdump.pid; exec $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- \"$FILTER\" 2>$QUEST_TMP.tcpdump.err'" >/dev/null 2>&1 &
QUEST_CAPTURE_ADB_PID=$!
adb shell su -c "sh -c 'echo \$\$ > $QUEST_TMP.logcat.pid; exec logcat -v threadtime -f $QUEST_TMP.logcat 2>$QUEST_TMP.logcat.err'" >/dev/null 2>&1 &
QUEST_LOGCAT_ADB_PID=$!
sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap" -- "$FILTER" >"$OUT/host-tcpdump.txt" 2>&1 &
HOST_TCPDUMP_PID=$!

sleep 1
kill -0 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || fail "host tcpdump exited before CAPTURE ARMED"
kill -0 "$QUEST_CAPTURE_ADB_PID" >/dev/null 2>&1 || fail "Quest tcpdump ADB session exited before CAPTURE ARMED"
kill -0 "$QUEST_LOGCAT_ADB_PID" >/dev/null 2>&1 || fail "Quest logcat ADB session exited before CAPTURE ARMED"
adb shell su -c "kill -0 \$(cat $QUEST_TMP.tcpdump.pid) && kill -0 \$(cat $QUEST_TMP.logcat.pid)" >/dev/null 2>&1 || fail "Quest capture/logcat process did not survive startup"
QUEST_PCAP_BYTES=$(adb shell su -c "wc -c < $QUEST_TMP.pcap" 2>/dev/null | tr -d '\r ' || echo 0)
[[ "$QUEST_PCAP_BYTES" =~ ^[0-9]+$ && "$QUEST_PCAP_BYTES" -ge 24 ]] || fail "Quest PCAP header was not created"
[[ -s "$OUT/host.pcap" ]] || fail "host PCAP header was not created"

DASHBOARD="$ROOT/build-dashboard/server/wivrn-dashboard"
PREFIX="$ROOT/build-dashboard/dashboard/prefix.sh"
if pgrep -f "$DASHBOARD" >/dev/null 2>&1; then
    echo "  dashboard: already running; current-run log events will be time-filtered"
elif [[ -x "$DASHBOARD" && -f "$PREFIX" ]]; then
    (cd "$ROOT"; bash -c 'source build-dashboard/dashboard/prefix.sh && exec build-dashboard/server/wivrn-dashboard') >"$OUT/dashboard-stdout.txt" 2>&1 &
    DASHBOARD_PID=$!
    echo "  dashboard: launched (pid $DASHBOARD_PID)"
else
    fail "existing dashboard build not found at $DASHBOARD"
fi

echo "Helix blackout capture"
echo "  tooling:   ${TOOL_COMMIT:0:12}"
echo "  runtime:   source-equivalent to ${RUNTIME_BASE:0:12}"
echo "  host:      $HOST_IP via $HOST_IF"
echo "  Quest:     $QUEST_IP via $QUEST_IF"
echo "  filter:    $FILTER"
echo "  buffer:    ${CAPTURE_BUFFER_KIB} KiB"
echo "  output:    $OUT"
echo
echo "CAPTURE ARMED. Reproduce the avatar load/unload blackout now."
echo "When finished, come back here and press Enter once."
read -r _

CAPTURE_END_EPOCH_NS=$(date +%s%N)
echo "capture_end_epoch_ns=$CAPTURE_END_EPOCH_NS" >>"$OUT/metadata.txt"
snapshot_host after
snapshot_quest after
cleanup_capture

adb pull "$QUEST_TMP.pcap" "$OUT/quest.pcap" >/dev/null || fail "failed to pull Quest PCAP"
adb pull "$QUEST_TMP.logcat" "$OUT/quest-logcat.txt" >/dev/null || fail "failed to pull Quest logcat"
adb shell su -c "cat $QUEST_TMP.tcpdump.err 2>/dev/null" >"$OUT/quest-tcpdump.txt" 2>&1 || true
adb shell su -c "cat $QUEST_TMP.logcat.err 2>/dev/null" >"$OUT/quest-logcat-stderr.txt" 2>&1 || true

[[ -s "$OUT/host.pcap" ]] || fail "host PCAP is empty after the run"
[[ -s "$OUT/quest.pcap" ]] || fail "Quest PCAP is empty after the run"
tcpdump -nn -r "$OUT/host.pcap" -c 1 >/dev/null 2>&1 || fail "host PCAP is unreadable"
tcpdump -nn -r "$OUT/quest.pcap" -c 1 >/dev/null 2>&1 || fail "Quest PCAP is unreadable"

if [[ -n "$DASHBOARD_PID" ]]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
    DASHBOARD_PID=""
fi

SERVER_LOG_DIR="$HOME/.local/state/wivrn/wivrn-dashboard"
SERVER_LOG=""
if [[ -d "$SERVER_LOG_DIR" ]]; then
    START_SEC=$((CAPTURE_START_EPOCH_NS / 1000000000))
    SERVER_LOG=$(find "$SERVER_LOG_DIR" -maxdepth 1 -type f -name 'server_logs_*.txt' -newermt "@$START_SEC" -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[[ -n "$SERVER_LOG" ]] || fail "no dashboard server log updated during this capture"
cp "$SERVER_LOG" "$OUT/server-log.txt"
echo "server_log_source=$SERVER_LOG" >>"$OUT/metadata.txt"

SERVER_ID=$(grep -m1 -E "WiVRn .*starting|WiVRn 'v[^']+' starting up" "$OUT/server-log.txt" || true)
QUEST_ID=$(grep -m1 -E 'Starting WiVRn version' "$OUT/quest-logcat.txt" || true)
printf 'server_runtime_identity=%s\n' "$SERVER_ID" >>"$OUT/metadata.txt"
printf 'quest_runtime_identity=%s\n' "$QUEST_ID" >>"$OUT/metadata.txt"
echo "finished_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

echo "Reducing to decision-relevant blackout windows..."
python3 "$ROOT/tools/helix-blackout-reduce.py" "$OUT"

trap - EXIT INT TERM

echo
echo "Capture complete. Original evidence: $OUT"
echo "Upload the reduced bundle printed above. No manual extraction needed."