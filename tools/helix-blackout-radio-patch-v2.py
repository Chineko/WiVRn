#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: helix-blackout-radio-patch-v2.py <generated-capture-script>")

path = Path(sys.argv[1])
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    text = text.replace(old, new, 1)


replace_once(
    'MAX_CAPTURE_SECONDS=480\n',
    'MAX_CAPTURE_SECONDS=480\nRADIO_TRACE_ARMED=0\nSUDO_KEEPALIVE_PID=""\nTRACE_WATCHDOG_SECONDS=570\n',
    "radio observer state",
)

replace_once(
    '''cleanup_all() {
    cleanup_capture
    if [[ -n "$DASHBOARD_PID" ]]; then
''',
    '''cleanup_all() {
    cleanup_capture
    if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
        kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        wait "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
        SUDO_KEEPALIVE_PID=""
    fi
    if [[ "$RADIO_TRACE_ARMED" -eq 1 ]]; then
        local adb_now
        adb_now=$(adb devices 2>/dev/null | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
        if [[ "$adb_now" -eq 1 ]]; then
            adb shell "su -c 'test -f $QUEST_TMP.trace-watchdog.pid && kill \\$(cat $QUEST_TMP.trace-watchdog.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on 2>/dev/null || true; echo 0 > $TRACE_EVENT/enable 2>/dev/null || true'" >/dev/null 2>&1 || true
            RADIO_TRACE_ARMED=0
        fi
    fi
    if [[ -n "$DASHBOARD_PID" ]]; then
''',
    "observer cleanup",
)

replace_once(
    '[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"\nFILTER="udp and src host $HOST_IP and dst host $QUEST_IP"\n',
    '''[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"

TRACE_ROOT=/sys/kernel/tracing
TRACE_INSTANCE="$TRACE_ROOT/instances/helix_blackout_$STAMP"
TRACE_EVENT="$TRACE_INSTANCE/events/wlan/dp_rx_udp_pkt"
TRACE_BUFFER_KB=16384
adb shell "su -c 'test -r $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format && test -w $TRACE_ROOT/instances'" >/dev/null 2>&1 || fail "Quest wlan:dp_rx_udp_pkt tracepoint/tracefs instance support is unavailable"
TRACE_FORMAT=$(adb shell "su -c 'cat $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format'" | tr -d '\\r')
for field in ip_id srcport dstport; do
    grep -q "$field" <<<"$TRACE_FORMAT" || fail "Quest wlan:dp_rx_udp_pkt format lacks required field: $field"
done

FILTER="udp and src host $HOST_IP and dst host $QUEST_IP"
''',
    "trace capability/format preflight",
)

replace_once(
    '    echo "attribution_scope=host_capture_to_quest_wlan"\n',
    '''    echo "attribution_scope=host_capture_to_quest_driver_trace_to_wlan"
    echo "quest_driver_trace_event=wlan:dp_rx_udp_pkt"
    echo "quest_driver_trace_buffer_kb_per_cpu=$TRACE_BUFFER_KB"
    echo "quest_driver_trace_overwrite=true"
    echo "quest_driver_trace_watchdog_seconds=$TRACE_WATCHDOG_SECONDS"
''',
    "trace metadata",
)

launch_marker = 'adb shell "su -c \'$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- '
launch_pos = text.find(launch_marker)
if launch_pos < 0 or text.find(launch_marker, launch_pos + 1) >= 0:
    raise SystemExit("trace arm: could not locate unique detached Quest tcpdump launch")
trace_arm = '''adb shell "su -c 'mkdir $TRACE_INSTANCE; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_INSTANCE/events/enable; echo $TRACE_BUFFER_KB > $TRACE_INSTANCE/buffer_size_kb; echo 1 > $TRACE_INSTANCE/options/overwrite; cat $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format > $QUEST_TMP.trace-format; echo 1 > $TRACE_EVENT/enable; echo 1 > $TRACE_INSTANCE/tracing_on'" >/dev/null 2>&1 || fail "could not arm bounded Quest wlan:dp_rx_udp_pkt trace"
RADIO_TRACE_ARMED=1
adb shell "su -c 'grep -q 1 $TRACE_INSTANCE/tracing_on && grep -q 1 $TRACE_EVENT/enable'" >/dev/null 2>&1 || fail "Quest WLAN trace did not remain armed"
python3 - "$QUEST_IP" <<'PYTRACEPROBE'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"helix-trace-preflight", (sys.argv[1], 9))
s.close()
PYTRACEPROBE
sleep 0.2
adb shell "su -c 'grep -q dp_rx_udp_pkt $TRACE_INSTANCE/trace'" >/dev/null 2>&1 || fail "Quest wlan:dp_rx_udp_pkt did not observe the setup UDP probe"
adb shell "su -c ': > $TRACE_INSTANCE/trace'" >/dev/null 2>&1 || fail "could not clear Quest WLAN trace after setup probe"
adb shell "su -c '$QUEST_NOHUP sh -c \"sleep $TRACE_WATCHDOG_SECONDS; test -f $QUEST_TMP.tcpdump.pid && kill -2 \\$(cat $QUEST_TMP.tcpdump.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_EVENT/enable\" >/dev/null 2>&1 </dev/null & echo \\$! > $QUEST_TMP.trace-watchdog.pid'" >/dev/null 2>&1 || fail "could not launch Quest trace/capture safety watchdog"

'''
text = text[:launch_pos] + trace_arm + text[launch_pos:]

host_launch_fragment = 'sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap"'
host_launch_pos = text.find(host_launch_fragment)
if host_launch_pos < 0 or text.find(host_launch_fragment, host_launch_pos + 1) >= 0:
    raise SystemExit("host observer: could not locate unique host tcpdump launch")
keepalive = '''sudo -v || fail "could not refresh sudo credentials immediately before host capture"
(
    while sleep 30; do
        sudo -n -v >/dev/null 2>&1 || exit 1
    done
) &
SUDO_KEEPALIVE_PID=$!

'''
text = text[:host_launch_pos] + keepalive + text[host_launch_pos:]

lines = text.splitlines(keepends=True)


def unique_line(substr: str, label: str) -> int:
    matches = [i for i, line in enumerate(lines) if substr in line]
    if len(matches) != 1:
        raise SystemExit(f"{label}: expected one generated line containing {substr!r}, found {len(matches)}")
    return matches[0]


usb_prompt = unique_line('echo "USB-DETACHED WORKLOAD MODE"', "USB prompt anchor")
host_start = unique_line('sudo -v || fail "could not refresh sudo credentials immediately before host capture"', "host observer block start")
armed_banner = unique_line('echo "Helix blackout capture"', "capture banner anchor")
if not (usb_prompt < host_start < armed_banner):
    raise SystemExit("generated host observer block is not in the expected post-detach position")
host_block = lines[host_start:armed_banner]
del lines[host_start:armed_banner]
lines[usb_prompt:usb_prompt] = host_block + ["\n"]
text = "".join(lines)

replace_once(
    '[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"\n\nsnapshot_quest after\n',
    '''[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"

adb shell "su -c 'test -f $QUEST_TMP.trace-watchdog.pid && kill \\$(cat $QUEST_TMP.trace-watchdog.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_EVENT/enable; cat $TRACE_INSTANCE/trace > $QUEST_TMP.wlan-dp-rx-udp.trace; for s in $TRACE_INSTANCE/per_cpu/cpu*/stats; do echo ===== \\$s =====; cat \\$s; done > $QUEST_TMP.trace-stats'" >/dev/null 2>&1 || fail "could not stop/preserve Quest WLAN trace after USB reconnect"
RADIO_TRACE_ARMED=0
adb exec-out su -c "cat '$QUEST_TMP.wlan-dp-rx-udp.trace'" >"$OUT/quest-wlan-dp-rx-udp.trace" || fail "could not retrieve Quest WLAN driver trace"
adb exec-out su -c "cat '$QUEST_TMP.trace-format'" >"$OUT/quest-wlan-dp-rx-udp-format.txt" || fail "could not retrieve Quest WLAN trace format"
adb exec-out su -c "cat '$QUEST_TMP.trace-stats'" >"$OUT/quest-wlan-trace-stats.txt" || fail "could not retrieve Quest WLAN trace-buffer stats"
[[ -s "$OUT/quest-wlan-dp-rx-udp.trace" ]] || fail "Quest WLAN driver trace is empty after the workload"

snapshot_quest after
''',
    "stop and retrieve Quest WLAN trace",
)

replace_once(
    'echo "WORKLOAD COMPLETE"\n',
    '''if [[ -n "$SUDO_KEEPALIVE_PID" ]]; then
    kill "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    wait "$SUDO_KEEPALIVE_PID" >/dev/null 2>&1 || true
    SUDO_KEEPALIVE_PID=""
fi

echo "WORKLOAD COMPLETE"
''',
    "sudo keepalive shutdown",
)


def pos(fragment: str, label: str) -> int:
    i = text.find(fragment)
    if i < 0:
        raise SystemExit(f"generated-path audit: missing {label}")
    if text.find(fragment, i + 1) >= 0:
        raise SystemExit(f"generated-path audit: duplicate {label}")
    return i


p_format = pos('format lacks required field', "trace format gate")
p_probe = pos('did not observe the setup UDP probe', "live tracepoint gate")
p_trace = pos('could not arm bounded Quest wlan:dp_rx_udp_pkt trace', "Quest driver trace arm")
p_watchdog = pos('could not launch Quest trace/capture safety watchdog', "trace/capture safety watchdog")
p_quest_verify = pos('detached Quest tcpdump exited before USB detach', "Quest tcpdump pre-detach verification")
p_host_launch = pos(host_launch_fragment, "host tcpdump launch")
p_host_verify = pos('host tcpdump did not report an active capture loop before CAPTURE ARMED', "host tcpdump verification")
p_usb_prompt = pos('USB-DETACHED WORKLOAD MODE', "USB detach prompt")
p_zero_adb = pos('Quest is still visible to ADB; unplug USB and ensure wireless ADB is disconnected', "zero-ADB gate")
p_start = pos('capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS', "workload start timestamp")
p_armed = pos('CAPTURE ARMED. No ADB session remains attached during the workload.', "capture armed banner")
p_reconnect = pos('WORKLOAD COMPLETE', "USB reconnect boundary")
p_trace_stop = pos('could not stop/preserve Quest WLAN trace after USB reconnect', "trace stop/retrieval")

order = [p_format, p_trace, p_probe, p_watchdog, p_quest_verify, p_host_launch, p_host_verify, p_usb_prompt, p_zero_adb, p_start, p_armed, p_reconnect, p_trace_stop]
if order != sorted(order):
    raise SystemExit("generated-path audit: observer/preflight/detach/start/stop ordering is wrong")

workload_window = text[p_zero_adb:p_reconnect]
for forbidden in ('adb shell', 'adb exec-out', 'adb devices', 'sudo -v'):
    if forbidden in workload_window:
        raise SystemExit(f"generated-path audit: {forbidden!r} remains inside detached workload window")

for required in ('MAX_CAPTURE_SECONDS=480', 'TRACE_WATCHDOG_SECONDS=570', 'cleanup_all()', 'quest-wlan-trace-stats.txt', 'kill -2 \\$(cat $QUEST_TMP.tcpdump.pid)'):
    if required not in text:
        raise SystemExit(f"generated-path audit: missing required safety element {required!r}")

path.write_text(text)
