#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-$STAMP"}
QUEST_TMP=/data/local/tmp/helix-blackout
DASHBOARD_PID=""

fail() {
    echo "Helix capture: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

need adb
need ip
need tcpdump
need git
need tar

mkdir -p "$OUT"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"

ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root check failed: adb shell su -c id did not return uid=0"

QUEST_ROUTE=$(adb shell su -c 'ip route show default 2>/dev/null | head -n1' | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0

QUEST_IP=$(adb shell su -c "ip -4 -o addr show dev $QUEST_IF scope global 2>/dev/null | head -n1" \
    | tr -d '\r' \
    | awk '{print $4}' \
    | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address on $QUEST_IF"

HOST_ROUTE=$(ip route get "$QUEST_IP" | head -n1)
HOST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
HOST_IP=$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
[[ -n "$HOST_IF" && -n "$HOST_IP" ]] || fail "could not determine host route to Quest $QUEST_IP"

# Verify capture capability before asking the user to start a VR run.
QUEST_TCPDUMP=$(adb shell su -c 'command -v tcpdump 2>/dev/null || which tcpdump 2>/dev/null' | tr -d '\r' | head -n1)
[[ -n "$QUEST_TCPDUMP" ]] || fail "tcpdump is not available on the rooted Quest; stop here before doing a data run"

# Meta's tcpdump build drops privileges by default. Retain root so packet-socket capture works under Magisk root.
if ! adb shell su -c "$QUEST_TCPDUMP -Z root -i $QUEST_IF -c 1 -nn" >/dev/null 2>&1; then
    fail "Quest tcpdump cannot capture on $QUEST_IF even with -Z root; stop here before doing a data run"
fi

echo "Helix blackout capture"
echo "  repo:      $ROOT"
echo "  commit:    $(git -C "$ROOT" rev-parse --short=12 HEAD)"
echo "  host:      $HOST_IP via $HOST_IF"
echo "  Quest:     $QUEST_IP via $QUEST_IF"
echo "  tcpdump:   $QUEST_TCPDUMP (-Z root verified)"
echo "  output:    $OUT"

{
    echo "started_utc=$(date -u +%FT%TZ)"
    echo "repo=$ROOT"
    echo "commit=$(git -C "$ROOT" rev-parse HEAD)"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
    echo "host_ip=$HOST_IP"
    echo "host_if=$HOST_IF"
    echo "quest_ip=$QUEST_IP"
    echo "quest_if=$QUEST_IF"
    echo "host_epoch=$(date +%s)"
    echo "quest_epoch=$(adb shell su -c 'date +%s' 2>/dev/null | tr -d '\r' || true)"
} >"$OUT/metadata.txt"

# Baseline host state.
ip -s link show dev "$HOST_IF" >"$OUT/host-link-before.txt" 2>&1 || true
if command -v tc >/dev/null 2>&1; then
    tc -s qdisc show dev "$HOST_IF" >"$OUT/host-qdisc-before.txt" 2>&1 || true
fi
if command -v ethtool >/dev/null 2>&1; then
    ethtool -S "$HOST_IF" >"$OUT/host-ethtool-before.txt" 2>&1 || true
fi
cat /proc/net/snmp >"$OUT/host-snmp-before.txt" 2>/dev/null || true

# Baseline rooted Quest state.
adb shell su -c "ip -s link show dev $QUEST_IF" >"$OUT/quest-link-before.txt" 2>&1 || true
adb shell su -c 'cat /proc/net/snmp' >"$OUT/quest-snmp-before.txt" 2>&1 || true
adb shell su -c 'cat /proc/net/udp; cat /proc/net/udp6' >"$OUT/quest-udp-before.txt" 2>&1 || true
adb shell su -c 'ss -u -a -m -i 2>/dev/null || true' >"$OUT/quest-sockets-before.txt" 2>&1 || true
adb shell su -c 'cmd wifi status 2>/dev/null || dumpsys wifi' >"$OUT/quest-wifi-before.txt" 2>&1 || true

# Ask for host capture privilege once, before the headset is on.
sudo -v

# Clear and start full Quest logcat locally on the PC.
adb logcat -c
adb logcat -v threadtime >"$OUT/quest-logcat.txt" 2>&1 &
LOGCAT_PID=$!

# Rooted Quest interface capture. Header/timing-only snaplen keeps a 5-minute run reasonably small.
adb shell su -c "rm -f $QUEST_TMP.pcap $QUEST_TMP.pid $QUEST_TMP.err; \
    sh -c '$QUEST_TCPDUMP -Z root -i $QUEST_IF -s 96 -U -w $QUEST_TMP.pcap \"udp and host $HOST_IP\" \
    >$QUEST_TMP.err 2>&1 & echo \$! >$QUEST_TMP.pid'" >/dev/null

# Matching host-side capture of the same UDP flow.
sudo tcpdump -i "$HOST_IF" -s 96 -U -w "$OUT/host.pcap" "udp and host $QUEST_IP" \
    >"$OUT/host-tcpdump.txt" 2>&1 &
HOST_TCPDUMP_PID=$!

cleanup_capture() {
    set +e
    kill "$LOGCAT_PID" >/dev/null 2>&1
    sudo kill "$HOST_TCPDUMP_PID" >/dev/null 2>&1
    wait "$LOGCAT_PID" >/dev/null 2>&1
    wait "$HOST_TCPDUMP_PID" >/dev/null 2>&1
    adb shell su -c "if [ -f $QUEST_TMP.pid ]; then kill \$(cat $QUEST_TMP.pid) 2>/dev/null; fi" >/dev/null 2>&1
}

cleanup_all() {
    cleanup_capture
    if [[ -n "$DASHBOARD_PID" ]]; then
        kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
        wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
    fi
}
trap cleanup_all EXIT INT TERM

# Launch the already-built dashboard only after capture is armed. No rebuild is required for this diagnostic run.
DASHBOARD="$ROOT/build-dashboard/server/wivrn-dashboard"
PREFIX="$ROOT/build-dashboard/dashboard/prefix.sh"
if pgrep -f "$DASHBOARD" >/dev/null 2>&1; then
    echo "  dashboard: already running"
elif [[ -x "$DASHBOARD" && -f "$PREFIX" ]]; then
    (
        cd "$ROOT"
        bash -c 'source build-dashboard/dashboard/prefix.sh && exec build-dashboard/server/wivrn-dashboard'
    ) >"$OUT/dashboard-stdout.txt" 2>&1 &
    DASHBOARD_PID=$!
    echo "  dashboard: launched (pid $DASHBOARD_PID)"
else
    echo "  dashboard: existing build not found; launch it manually before starting VR"
fi

echo
echo "CAPTURE ARMED. Reproduce the avatar load/unload blackout now."
echo "When finished, come back here and press Enter once."
read -r _

echo "Stopping and collecting..."
cleanup_capture

if [[ -n "$DASHBOARD_PID" ]]; then
    kill "$DASHBOARD_PID" >/dev/null 2>&1 || true
    wait "$DASHBOARD_PID" >/dev/null 2>&1 || true
    DASHBOARD_PID=""
fi
trap - EXIT INT TERM

sleep 1
adb pull "$QUEST_TMP.pcap" "$OUT/quest.pcap" >/dev/null 2>&1 || true
adb shell su -c "cat $QUEST_TMP.err 2>/dev/null" >"$OUT/quest-tcpdump.txt" 2>&1 || true

# Post-run state.
ip -s link show dev "$HOST_IF" >"$OUT/host-link-after.txt" 2>&1 || true
if command -v tc >/dev/null 2>&1; then
    tc -s qdisc show dev "$HOST_IF" >"$OUT/host-qdisc-after.txt" 2>&1 || true
fi
if command -v ethtool >/dev/null 2>&1; then
    ethtool -S "$HOST_IF" >"$OUT/host-ethtool-after.txt" 2>&1 || true
fi
cat /proc/net/snmp >"$OUT/host-snmp-after.txt" 2>/dev/null || true

adb shell su -c "ip -s link show dev $QUEST_IF" >"$OUT/quest-link-after.txt" 2>&1 || true
adb shell su -c 'cat /proc/net/snmp' >"$OUT/quest-snmp-after.txt" 2>&1 || true
adb shell su -c 'cat /proc/net/udp; cat /proc/net/udp6' >"$OUT/quest-udp-after.txt" 2>&1 || true
adb shell su -c 'ss -u -a -m -i 2>/dev/null || true' >"$OUT/quest-sockets-after.txt" 2>&1 || true
adb shell su -c 'cmd wifi status 2>/dev/null || dumpsys wifi' >"$OUT/quest-wifi-after.txt" 2>&1 || true

# Copy the newest dashboard server log if one exists.
SERVER_LOG_DIR="$HOME/.local/state/wivrn/wivrn-dashboard"
if [[ -d "$SERVER_LOG_DIR" ]]; then
    SERVER_LOG=$(find "$SERVER_LOG_DIR" -maxdepth 1 -type f -name 'server_logs_*.txt' -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-)
    if [[ -n "${SERVER_LOG:-}" ]]; then
        cp "$SERVER_LOG" "$OUT/server-log.txt"
        echo "server_log_source=$SERVER_LOG" >>"$OUT/metadata.txt"
    fi
fi

echo "finished_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"
echo "host_epoch_end=$(date +%s)" >>"$OUT/metadata.txt"
echo "quest_epoch_end=$(adb shell su -c 'date +%s' 2>/dev/null | tr -d '\r' || true)" >>"$OUT/metadata.txt"

# Lightweight capture sanity summary.
{
    echo "host_pcap_bytes=$(stat -c %s "$OUT/host.pcap" 2>/dev/null || echo 0)"
    echo "quest_pcap_bytes=$(stat -c %s "$OUT/quest.pcap" 2>/dev/null || echo 0)"
    echo "host_udp_packets=$(tcpdump -nn -r "$OUT/host.pcap" 2>/dev/null | wc -l)"
    echo "quest_udp_packets=$(tcpdump -nn -r "$OUT/quest.pcap" 2>/dev/null | wc -l)"
} >"$OUT/capture-summary.txt"

# PCAP payload is encrypted and barely compressible; avoid wasting time recompressing it.
ARCHIVE="$OUT.tar"
tar -C "$(dirname "$OUT")" -cf "$ARCHIVE" "$(basename "$OUT")"

echo
echo "Capture complete."
echo "Bundle: $ARCHIVE"
echo "Send me that one file; no manual grep or extraction needed."
