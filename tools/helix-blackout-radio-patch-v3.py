#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: helix-blackout-radio-patch-v3.py <generated-capture-script>")

path = Path(sys.argv[1])
text = path.read_text()


def replace_once(old: str, new: str, label: str) -> None:
    global text
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}")
    text = text.replace(old, new, 1)


# Bounded observer lifecycle state. These bounds include setup/positioning,
# the 480-second workload cap, and USB reconnect/retrieval allowance.
replace_once(
    'MAX_CAPTURE_SECONDS=480\n',
    'MAX_CAPTURE_SECONDS=480\nRADIO_TRACE_ARMED=0\nSUDO_KEEPALIVE_PID=""\nTRACE_WATCHDOG_SECONDS=960\nDETACH_PROMPT_SECONDS=180\nRECONNECT_PROMPT_SECONDS=180\n',
    "radio observer state",
)

# Extend the existing cleanup path without changing Wi-Fi/runtime settings.
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
            adb shell "su -c 'test -f $QUEST_TMP.trace-watchdog.pid && kill \\$(cat $QUEST_TMP.trace-watchdog.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on 2>/dev/null || true; echo 0 > $TRACE_EVENT/enable 2>/dev/null || true; rmdir $TRACE_INSTANCE 2>/dev/null || true'" >/dev/null 2>&1 || true
            RADIO_TRACE_ARMED=0
        fi
    fi
    if [[ -n "$DASHBOARD_PID" ]]; then
''',
    "observer cleanup",
)

# Verify the actual Quest tracepoint schema before arming anything.
replace_once(
    '[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"\nFILTER="udp and src host $HOST_IP and dst host $QUEST_IP"\n',
    '''[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"

TRACE_ROOT=/sys/kernel/tracing
TRACE_INSTANCE="$TRACE_ROOT/instances/helix_blackout_$STAMP"
TRACE_EVENT="$TRACE_INSTANCE/events/wlan/dp_rx_udp_pkt"
TRACE_BUFFER_KB=16384
TRACE_SYNC_START_PORTS="49171,49172,49173"
TRACE_SYNC_END_PORTS="49271,49272,49273"
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
    echo "quest_driver_trace_sync_start_ports=$TRACE_SYNC_START_PORTS"
    echo "quest_driver_trace_sync_end_ports=$TRACE_SYNC_END_PORTS"
    echo "detach_prompt_seconds=$DETACH_PROMPT_SECONDS"
    echo "reconnect_prompt_seconds=$RECONNECT_PROMPT_SECONDS"
''',
    "trace metadata",
)

# Arm only the one Qualcomm RX-UDP tracepoint. The autonomous Quest watchdog
# bounds both trace and Quest tcpdump if the host disappears while USB is out.
launch_marker = 'adb shell "su -c \'$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- '
launch_pos = text.find(launch_marker)
if launch_pos < 0 or text.find(launch_marker, launch_pos + 1) >= 0:
    raise SystemExit("radio generator: could not locate unique detached Quest tcpdump launch")
trace_arm = '''adb shell "su -c 'mkdir $TRACE_INSTANCE; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_INSTANCE/events/enable; echo $TRACE_BUFFER_KB > $TRACE_INSTANCE/buffer_size_kb; echo 1 > $TRACE_INSTANCE/options/overwrite; cat $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format > $QUEST_TMP.trace-format; echo 1 > $TRACE_EVENT/enable; echo 1 > $TRACE_INSTANCE/tracing_on'" >/dev/null 2>&1 || fail "could not arm bounded Quest wlan:dp_rx_udp_pkt trace"
RADIO_TRACE_ARMED=1
adb shell "su -c 'grep -q 1 $TRACE_INSTANCE/tracing_on && grep -q 1 $TRACE_EVENT/enable'" >/dev/null 2>&1 || fail "Quest WLAN trace did not remain armed"
adb shell "su -c '$QUEST_NOHUP sh -c \"sleep $TRACE_WATCHDOG_SECONDS; test -f $QUEST_TMP.tcpdump.pid && kill -2 \\$(cat $QUEST_TMP.tcpdump.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_EVENT/enable; rmdir $TRACE_INSTANCE 2>/dev/null || true\" >/dev/null 2>&1 </dev/null & echo \\$! > $QUEST_TMP.trace-watchdog.pid'" >/dev/null 2>&1 || fail "could not launch Quest trace/capture safety watchdog"

'''
text = text[:launch_pos] + trace_arm + text[launch_pos:]

# Once Quest tcpdump is proven live, emit a three-port setup marker. The same
# packets must be visible in the Qualcomm trace. This proves the event is live
# before the headset is unplugged and records a non-workload sync marker.
quest_ready = '''    fail "Quest tcpdump did not report an active capture loop before USB detach"
fi
'''
sync_start = quest_ready + '''python3 - "$QUEST_IP" <<'PYTRACESYNCSTART'
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for port in (49171, 49172, 49173):
    s.sendto(b"helix-trace-sync-start", (sys.argv[1], port))
    time.sleep(0.02)
s.close()
PYTRACESYNCSTART
sleep 0.2
for port in 49171 49172 49173; do
    adb shell "su -c 'grep -q \\\"dstport=$port\\\" $TRACE_INSTANCE/trace'" >/dev/null 2>&1 || fail "Quest wlan:dp_rx_udp_pkt did not observe sync-start UDP port $port"
done
'''
replace_once(quest_ready, sync_start, "trace sync-start marker")

# Refresh sudo and keep it non-interactively valid before any USB detach. The
# entire host observer launch/readiness block is then moved before the prompt.
host_launch_fragment = 'sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap"'
host_launch_pos = text.find(host_launch_fragment)
if host_launch_pos < 0 or text.find(host_launch_fragment, host_launch_pos + 1) >= 0:
    raise SystemExit("radio generator: could not locate unique host tcpdump launch")
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
    raise SystemExit("radio generator: host observer block is not in expected post-detach position")
host_block = lines[host_start:armed_banner]
del lines[host_start:armed_banner]
lines[usb_prompt:usb_prompt] = host_block + ["\n"]
text = "".join(lines)

# Bound the human detach/position transition now that host observers are active.
replace_once(
    'read -r -p "Press Enter only after USB is unplugged and the Quest is in the normal VR position: " _\n',
    '''if ! read -r -t "$DETACH_PROMPT_SECONDS" -p "Press Enter only after USB is unplugged and the Quest is in the normal VR position: " _; then
    fail "USB detach/position prompt timed out after ${DETACH_PROMPT_SECONDS}s"
fi
''',
    "bounded USB detach prompt",
)

# Bound reconnect too; the Quest-side watchdog remains the final fail-safe.
replace_once(
    'read -r -p "Press Enter after USB ADB has reconnected: " _\n',
    '''if ! read -r -t "$RECONNECT_PROMPT_SECONDS" -p "Press Enter after USB ADB has reconnected: " _; then
    fail "USB reconnect prompt timed out after ${RECONNECT_PROMPT_SECONDS}s"
fi
''',
    "bounded USB reconnect prompt",
)

# After the same-Quest reconnect gate, emit a different three-port marker while
# Quest tcpdump and the driver trace are still active. This tail marker anchors
# tracefs's monotonic clock directly to Quest-PCAP time even if the trace ring
# has overwritten the setup marker.
replace_once(
    '[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"\n\nsnapshot_quest after\n',
    '''[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"

python3 - "$QUEST_IP" <<'PYTRACESYNCEND'
import socket, sys, time
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for port in (49271, 49272, 49273):
    s.sendto(b"helix-trace-sync-end", (sys.argv[1], port))
    time.sleep(0.02)
s.close()
PYTRACESYNCEND
sleep 0.2
for port in 49271 49272 49273; do
    adb shell "su -c 'grep -q \\\"dstport=$port\\\" $TRACE_INSTANCE/trace'" >/dev/null 2>&1 || fail "Quest wlan:dp_rx_udp_pkt did not observe sync-end UDP port $port"
done

adb shell "su -c 'test -f $QUEST_TMP.trace-watchdog.pid && kill \\$(cat $QUEST_TMP.trace-watchdog.pid) 2>/dev/null || true; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_EVENT/enable; cat $TRACE_INSTANCE/trace > $QUEST_TMP.wlan-dp-rx-udp.trace; for s in $TRACE_INSTANCE/per_cpu/cpu*/stats; do echo ===== \\$s =====; cat \\$s; done > $QUEST_TMP.trace-stats'" >/dev/null 2>&1 || fail "could not stop/preserve Quest WLAN trace after USB reconnect"
RADIO_TRACE_ARMED=0
adb exec-out su -c "cat '$QUEST_TMP.wlan-dp-rx-udp.trace'" >"$OUT/quest-wlan-dp-rx-udp.trace" || fail "could not retrieve Quest WLAN driver trace"
adb exec-out su -c "cat '$QUEST_TMP.trace-format'" >"$OUT/quest-wlan-dp-rx-udp-format.txt" || fail "could not retrieve Quest WLAN trace format"
adb exec-out su -c "cat '$QUEST_TMP.trace-stats'" >"$OUT/quest-wlan-trace-stats.txt" || fail "could not retrieve Quest WLAN trace-buffer stats"
[[ -s "$OUT/quest-wlan-dp-rx-udp.trace" ]] || fail "Quest WLAN driver trace is empty after the workload"
adb shell "su -c 'rmdir $TRACE_INSTANCE 2>/dev/null || true'" >/dev/null 2>&1 || true

snapshot_quest after
''',
    "sync-stop-retrieve Quest WLAN trace",
)

# Keep sudo alive through all sudo-owned host teardown, then stop it before the
# reconnect phase. No network activity is generated by this keepalive.
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

path.write_text(text)
