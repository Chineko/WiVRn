#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-$STAMP"}
QUEST_TMP="/data/local/tmp/helix-blackout-$STAMP"
RUNTIME_BASE=${HELIX_RUNTIME_BASE:-ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a}
DASHBOARD_PID=""
HOST_TCPDUMP_PID=""
HOST_SAMPLER_PID=""
CAPTURE_ACTIVE=0
CAPTURE_BUFFER_KIB=16384
QUEST_MIN_FREE_KB=1572864
HOST_MIN_FREE_KB=2097152
MAX_CAPTURE_SECONDS=480

fail() {
    echo "Helix capture: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

for cmd in adb awk cut date df git grep ip ping pgrep python3 sudo tcpdump timeout wc; do
    need "$cmd"
done

wifi_frequency_mhz() {
    awk 'BEGIN{IGNORECASE=1} /frequency/ { for (i=1; i<=NF; i++) { v=$i; gsub(/[^0-9]/, "", v); if ((v+0) >= 5000 && (v+0) <= 8000) { print v; exit } } }'
}

wifi_bssid() {
    awk 'BEGIN{IGNORECASE=1} /bssid/ { for (i=1;i<=NF;i++) { v=$i; gsub(/[,;]/, "", v); n=split(v, a, ":"); if (n == 6) { print tolower(v); exit } } }'
}

pcap_linktype() {
    python3 - "$1" <<'PY'
import struct, sys
p=sys.argv[1]
with open(p, "rb") as f:
    h=f.read(24)
if len(h)!=24:
    raise SystemExit(2)
magic=h[:4]
formats={
    b"\xd4\xc3\xb2\xa1":"<", b"\xa1\xb2\xc3\xd4":">",
    b"\x4d\x3c\xb2\xa1":"<", b"\xa1\xb2\x3c\x4d":">",
}
if magic not in formats:
    raise SystemExit(3)
raw=struct.unpack(formats[magic]+"I", h[20:24])[0]
print(raw & 0xFFFF)
PY
}

quest_executable() {
    local name=$1
    local path
    path=$(adb shell "su -c 'which $name 2>/dev/null'" | tr -d '\r' | awk '/^\// {print; exit}')
    [[ -n "$path" ]] || return 1
    adb shell "su -c 'test -x $path'" >/dev/null 2>&1 || return 1
    printf '%s\n' "$path"
}

cleanup_capture() {
    set +e
    if [[ "$CAPTURE_ACTIVE" -eq 1 ]]; then
        if adb shell "su -c 'test -f $QUEST_TMP.tcpdump.pid'" >/dev/null 2>&1; then
            adb shell "su -c 'kill -2 \$(cat $QUEST_TMP.tcpdump.pid) 2>/dev/null || true'" >/dev/null 2>&1
        fi
        if [[ -n "$HOST_TCPDUMP_PID" ]]; then
            sudo kill -2 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        fi
        if [[ -n "$HOST_SAMPLER_PID" ]]; then
            kill "$HOST_SAMPLER_PID" >/dev/null 2>&1 || true
        fi
        sleep 1
        [[ -n "$HOST_TCPDUMP_PID" ]] && sudo kill -15 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        [[ -n "$HOST_TCPDUMP_PID" ]] && wait "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
        [[ -n "$HOST_SAMPLER_PID" ]] && wait "$HOST_SAMPLER_PID" >/dev/null 2>&1 || true
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

QUEST_ROUTE=$(adb shell "su -c 'ip route show default 2>/dev/null | head -n1'" | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell "su -c 'ip -4 -o addr show dev $QUEST_IF scope global 2>/dev/null | head -n1'" | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address on $QUEST_IF"

HOST_ROUTE=$(ip route get "$QUEST_IP" | head -n1)
HOST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
HOST_IP=$(awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' <<<"$HOST_ROUTE")
[[ -n "$HOST_IF" && -n "$HOST_IP" ]] || fail "could not determine host route to Quest $QUEST_IP"

WIFI_STATUS_BEFORE=$(adb shell "su -c 'cmd wifi status 2>/dev/null || true'" | tr -d '\r')
QUEST_FREQ_BEFORE=$(wifi_frequency_mhz <<<"$WIFI_STATUS_BEFORE")
QUEST_BSSID_BEFORE=$(wifi_bssid <<<"$WIFI_STATUS_BEFORE")
[[ "$QUEST_FREQ_BEFORE" =~ ^[0-9]+$ ]] || fail "could not determine Quest Wi-Fi frequency from 'cmd wifi status'"
(( QUEST_FREQ_BEFORE >= 5925 && QUEST_FREQ_BEFORE <= 7125 )) || fail "Quest is not on 6 GHz before the run (frequency ${QUEST_FREQ_BEFORE} MHz)"
[[ -n "$QUEST_BSSID_BEFORE" ]] || fail "could not determine Quest BSSID before the run"

QUEST_TCPDUMP=$(quest_executable tcpdump || true)
QUEST_NOHUP=$(quest_executable nohup || true)
[[ "$QUEST_TCPDUMP" == /* ]] || fail "tcpdump did not resolve to an absolute executable path on the rooted Quest"
[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"
FILTER="udp and src host $HOST_IP and dst host $QUEST_IP"

tcpdump -d "$FILTER" >/dev/null 2>&1 || fail "host tcpdump rejected capture filter: $FILTER"
adb shell "su -c '$QUEST_TCPDUMP -d \"$FILTER\"'" >/dev/null 2>&1 || fail "Quest tcpdump rejected capture filter: $FILTER"

QUEST_FREE_KB=$(adb shell "su -c 'df -Pk /data/local/tmp 2>/dev/null | tail -n1'" | tr -d '\r' | awk '{print $4}')
[[ "$QUEST_FREE_KB" =~ ^[0-9]+$ ]] || fail "could not determine free Quest storage"
(( QUEST_FREE_KB >= QUEST_MIN_FREE_KB )) || fail "Quest has less than 1.5 GiB free under /data/local/tmp"
HOST_FREE_KB=$(df -Pk "$OUT" | tail -n1 | awk '{print $4}')
(( HOST_FREE_KB >= HOST_MIN_FREE_KB )) || fail "host has less than 2 GiB free for paired captures"

sudo -v

QUEST_PRE="$QUEST_TMP-preflight.pcap"
QUEST_PRE_PID="$QUEST_TMP-preflight.pid"
QUEST_PRE_ERR="$QUEST_TMP-preflight.err"
HOST_PRE="$OUT/host-preflight.pcap"
adb shell "su -c 'rm -f $QUEST_PRE $QUEST_PRE_PID $QUEST_PRE_ERR'" >/dev/null 2>&1 || true
adb shell "su -c '$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -c 1 -w $QUEST_PRE -- \"icmp and host $HOST_IP\" >/dev/null 2>$QUEST_PRE_ERR </dev/null & echo \$! > $QUEST_PRE_PID'" >/dev/null 2>&1 \
    || fail "could not launch detached Quest tcpdump preflight"

sudo timeout 8s tcpdump -i "$HOST_IF" -s 96 -c 1 -w "$HOST_PRE" -- "icmp and host $QUEST_IP" >/dev/null 2>&1 &
HOST_PRE_PID=$!
sleep 0.3
ping -c 1 -W 1 "$QUEST_IP" >/dev/null 2>&1 || true

for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    if ! adb shell "su -c 'kill -0 \$(cat $QUEST_PRE_PID) 2>/dev/null'" >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done
if adb shell "su -c 'kill -0 \$(cat $QUEST_PRE_PID) 2>/dev/null'" >/dev/null 2>&1; then
    adb shell "su -c 'kill -2 \$(cat $QUEST_PRE_PID) 2>/dev/null || true'" >/dev/null 2>&1 || true
    fail "detached Quest tcpdump preflight did not capture a packet"
fi
wait "$HOST_PRE_PID" || fail "host tcpdump preflight did not capture a packet within 8 seconds"

if ! adb shell "su -c 'test -s $QUEST_PRE'" >/dev/null 2>&1; then
    adb shell "su -c 'cat $QUEST_PRE_ERR 2>/dev/null || true'" >&2 || true
    fail "detached Quest tcpdump preflight produced no PCAP"
fi
QUEST_PRE_LOCAL="$OUT/quest-preflight.pcap"
adb exec-out su -c "cat '$QUEST_PRE'" >"$QUEST_PRE_LOCAL" || fail "could not read detached Quest preflight PCAP as root"
[[ "$(pcap_linktype "$HOST_PRE")" == "1" ]] || fail "host capture link type is not Ethernet (DLT_EN10MB=1)"
[[ "$(pcap_linktype "$QUEST_PRE_LOCAL")" == "1" ]] || fail "Quest capture link type is not Ethernet (DLT_EN10MB=1)"
tcpdump -nn -r "$HOST_PRE" -c 1 >/dev/null 2>&1 || fail "host preflight PCAP is unreadable"
tcpdump -nn -r "$QUEST_PRE_LOCAL" -c 1 >/dev/null 2>&1 || fail "Quest preflight PCAP is unreadable"
rm -f "$HOST_PRE" "$QUEST_PRE_LOCAL"
adb shell "su -c 'rm -f $QUEST_PRE $QUEST_PRE_PID $QUEST_PRE_ERR'" >/dev/null 2>&1 || true

TOOL_COMMIT=$(git -C "$ROOT" rev-parse HEAD)

{
    echo "setup_started_utc=$(date -u +%FT%TZ)"
    echo "host_tz_offset=$(date +%z)"
    echo "repo=$ROOT"
    echo "capture_tool_commit=$TOOL_COMMIT"
    echo "runtime_source_base=$RUNTIME_BASE"
    echo "runtime_source_equivalent=true"
    echo "attribution_scope=host_capture_to_quest_wlan"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
    echo "host_ip=$HOST_IP"
    echo "host_if=$HOST_IF"
    echo "quest_ip=$QUEST_IP"
    echo "quest_if=$QUEST_IF"
    echo "quest_bssid_before=$QUEST_BSSID_BEFORE"
    echo "quest_frequency_mhz_before=$QUEST_FREQ_BEFORE"
    echo "capture_filter=$FILTER"
    echo "capture_buffer_kib=$CAPTURE_BUFFER_KIB"
    echo "max_capture_seconds=$MAX_CAPTURE_SECONDS"
    echo "quest_free_kb_before=$QUEST_FREE_KB"
    echo "host_free_kb_before=$HOST_FREE_KB"
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
    adb shell "su -c 'ip -s link show dev $QUEST_IF'" >"$OUT/quest-link-$tag.txt" 2>&1 || true
    adb shell "su -c 'cat /proc/net/snmp'" >"$OUT/quest-snmp-$tag.txt" 2>&1 || true
    adb shell "su -c 'cat /proc/net/netstat'" >"$OUT/quest-netstat-$tag.txt" 2>&1 || true
    adb shell "su -c 'cat /proc/net/udp; cat /proc/net/udp6'" >"$OUT/quest-udp-$tag.txt" 2>&1 || true
    adb shell "su -c 'ss -u -a -m -i 2>/dev/null || true'" >"$OUT/quest-sockets-$tag.txt" 2>&1 || true
    adb shell "su -c 'cmd wifi status 2>/dev/null || true'" >"$OUT/quest-wifi-status-$tag.txt" 2>&1 || true
}

host_sampler() {
    while :; do
        {
            echo "sample_epoch_ns=$(date +%s%N)"
            echo "loadavg=$(cat /proc/loadavg 2>/dev/null || true)"
            echo "cpu_pressure=$(tr '\n' ';' </proc/pressure/cpu 2>/dev/null || true)"
            for stat in rx_bytes tx_bytes rx_packets tx_packets rx_dropped tx_dropped rx_errors tx_errors; do
                value=$(cat "/sys/class/net/$HOST_IF/statistics/$stat" 2>/dev/null || echo unavailable)
                echo "$stat=$value"
            done
            echo "softnet_begin"
            cat /proc/net/softnet_stat 2>/dev/null || true
            echo "softnet_end"
            echo
        } >>"$OUT/host-system-samples.txt"
        sleep 1
    done
}

DASHBOARD="$ROOT/build-dashboard/server/wivrn-dashboard"
PREFIX="$ROOT/build-dashboard/dashboard/prefix.sh"
if pgrep -f "$DASHBOARD" >/dev/null 2>&1; then
    echo "  dashboard: already running; current-run log events will be time-filtered"
elif [[ -x "$DASHBOARD" && -f "$PREFIX" ]]; then
    (
        cd "$ROOT"
        bash -c 'source build-dashboard/dashboard/prefix.sh && exec build-dashboard/server/wivrn-dashboard'
    ) >"$OUT/dashboard-stdout.txt" 2>&1 &
    DASHBOARD_PID=$!
    echo "  dashboard: launched (pid $DASHBOARD_PID)"
else
    fail "existing dashboard build not found at $DASHBOARD"
fi

snapshot_host before
snapshot_quest before
adb shell "su -c 'logcat -b all -c'" >/dev/null 2>&1 || true

CAPTURE_START_EPOCH_NS=$(date +%s%N)
echo "capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS" >>"$OUT/metadata.txt"
echo "capture_started_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

adb shell "su -c 'rm -f $QUEST_TMP.pcap $QUEST_TMP.tcpdump.pid $QUEST_TMP.tcpdump.err'" >/dev/null 2>&1 || true
adb shell "su -c '$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- \"$FILTER\" >/dev/null 2>$QUEST_TMP.tcpdump.err </dev/null & echo \$! > $QUEST_TMP.tcpdump.pid'" >/dev/null 2>&1 \
    || fail "could not launch detached Quest tcpdump"

sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap" -- "$FILTER" >"$OUT/host-tcpdump.txt" 2>&1 &
HOST_TCPDUMP_PID=$!
host_sampler &
HOST_SAMPLER_PID=$!
CAPTURE_ACTIVE=1

sleep 1
kill -0 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || fail "host tcpdump exited before CAPTURE ARMED"
kill -0 "$HOST_SAMPLER_PID" >/dev/null 2>&1 || fail "host sampler exited before CAPTURE ARMED"
adb shell "su -c 'kill -0 \$(cat $QUEST_TMP.tcpdump.pid)'" >/dev/null 2>&1 || fail "detached Quest tcpdump exited before CAPTURE ARMED"
QUEST_TCPDUMP_STATUS=$(adb shell "su -c 'cat $QUEST_TMP.tcpdump.err 2>/dev/null || true'" | tr -d '\r')
if [[ "$QUEST_TCPDUMP_STATUS" != *"listening on $QUEST_IF"* ]]; then
    printf '%s\n' "$QUEST_TCPDUMP_STATUS" >&2
    fail "Quest tcpdump did not report an active capture loop before CAPTURE ARMED"
fi
HOST_TCPDUMP_STATUS=$(cat "$OUT/host-tcpdump.txt" 2>/dev/null || true)
if [[ "$HOST_TCPDUMP_STATUS" != *"listening on $HOST_IF"* ]]; then
    printf '%s\n' "$HOST_TCPDUMP_STATUS" >&2
    fail "host tcpdump did not report an active capture loop before CAPTURE ARMED"
fi

echo "Helix blackout capture"
echo "  tooling:   ${TOOL_COMMIT:0:12}"
echo "  runtime:   source-equivalent to ${RUNTIME_BASE:0:12}"
echo "  host:      $HOST_IP via $HOST_IF"
echo "  Quest:     $QUEST_IP via $QUEST_IF"
echo "  Wi-Fi:     ${QUEST_FREQ_BEFORE} MHz / $QUEST_BSSID_BEFORE"
echo "  scope:     host capture -> Quest wlan capture"
echo "  output:    $OUT"
echo
echo "CAPTURE ARMED. No ADB session remains attached during the workload."
echo "Reproduce the avatar load/unload blackout now. Press Enter when finished; capture auto-stops after ${MAX_CAPTURE_SECONDS}s."
if ! read -r -t "$MAX_CAPTURE_SECONDS" _; then
    echo "Capture duration limit reached; stopping automatically."
fi

CAPTURE_END_EPOCH_NS=$(date +%s%N)
echo "capture_end_epoch_ns=$CAPTURE_END_EPOCH_NS" >>"$OUT/metadata.txt"

snapshot_host after
snapshot_quest after

WIFI_STATUS_AFTER=$(cat "$OUT/quest-wifi-status-after.txt" 2>/dev/null || true)
QUEST_FREQ_AFTER=$(wifi_frequency_mhz <<<"$WIFI_STATUS_AFTER")
QUEST_BSSID_AFTER=$(wifi_bssid <<<"$WIFI_STATUS_AFTER")
WIFI_ENDPOINT_CONSISTENT=true
if [[ ! "$QUEST_FREQ_AFTER" =~ ^[0-9]+$ ]] || (( QUEST_FREQ_AFTER < 5925 || QUEST_FREQ_AFTER > 7125 )); then
    WIFI_ENDPOINT_CONSISTENT=false
fi
if [[ -z "$QUEST_BSSID_AFTER" || "$QUEST_BSSID_AFTER" != "$QUEST_BSSID_BEFORE" ]]; then
    WIFI_ENDPOINT_CONSISTENT=false
fi
{
    echo "quest_bssid_after=$QUEST_BSSID_AFTER"
    echo "quest_frequency_mhz_after=$QUEST_FREQ_AFTER"
    echo "wifi_endpoint_state_consistent=$WIFI_ENDPOINT_CONSISTENT"
} >>"$OUT/metadata.txt"

cleanup_capture

adb exec-out su -c "cat '$QUEST_TMP.pcap'" >"$OUT/quest.pcap" || fail "failed to read Quest PCAP as root"
adb shell "su -c 'cat $QUEST_TMP.tcpdump.err 2>/dev/null'" >"$OUT/quest-tcpdump.txt" 2>&1 || true
adb shell "su -c 'logcat -b all -d -v threadtime 2>/dev/null || logcat -d -v threadtime'" >"$OUT/quest-logcat.txt" 2>&1 || true
adb shell "su -c 'rm -f $QUEST_TMP.pcap $QUEST_TMP.tcpdump.pid $QUEST_TMP.tcpdump.err'" >/dev/null 2>&1 || true

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
    SERVER_LOG=$(find "$SERVER_LOG_DIR" -maxdepth 1 -type f -name 'server_logs_*.txt' -newermt "@$START_SEC" -printf '%T@ %p\n' 2>/dev/null \
        | sort -nr | head -n1 | cut -d' ' -f2-)
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
