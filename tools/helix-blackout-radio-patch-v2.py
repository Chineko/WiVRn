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
    '[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"\nFILTER="udp and src host $HOST_IP and dst host $QUEST_IP"\n',
    '[[ "$QUEST_NOHUP" == /* ]] || fail "nohup did not resolve to an absolute executable path on the rooted Quest"\n\nTRACE_ROOT=/sys/kernel/tracing\nTRACE_INSTANCE="$TRACE_ROOT/instances/helix_blackout_$STAMP"\nTRACE_EVENT="$TRACE_INSTANCE/events/wlan/dp_rx_udp_pkt"\nTRACE_BUFFER_KB=4096\nadb shell "su -c \'test -r $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format && test -w $TRACE_ROOT/instances\'" >/dev/null 2>&1 || fail "Quest wlan:dp_rx_udp_pkt tracepoint/tracefs instance support is unavailable"\n\nFILTER="udp and src host $HOST_IP and dst host $QUEST_IP"\n',
    "trace capability preflight",
)

replace_once(
    '    echo "attribution_scope=host_capture_to_quest_wlan"\n',
    '    echo "attribution_scope=host_capture_to_quest_wlan_plus_quest_driver_trace"\n    echo "quest_driver_trace_event=wlan:dp_rx_udp_pkt"\n    echo "quest_driver_trace_buffer_kb_per_cpu=$TRACE_BUFFER_KB"\n    echo "quest_driver_trace_overwrite=true"\n',
    "trace metadata",
)

needle = 'adb shell "su -c \'$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- \\\\"$FILTER\\\\" >/dev/null 2>$QUEST_TMP.tcpdump.err </dev/null & echo \\\\$! > $QUEST_TMP.tcpdump.pid\'" >/dev/null 2>&1 \\\n    || fail "could not launch detached Quest tcpdump"\n'
insert = 'adb shell "su -c \'mkdir $TRACE_INSTANCE; echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_INSTANCE/events/enable; echo $TRACE_BUFFER_KB > $TRACE_INSTANCE/buffer_size_kb; echo 1 > $TRACE_INSTANCE/options/overwrite; cat $TRACE_ROOT/events/wlan/dp_rx_udp_pkt/format > $QUEST_TMP.trace-format; echo 1 > $TRACE_EVENT/enable; echo 1 > $TRACE_INSTANCE/tracing_on\'" >/dev/null 2>&1 || fail "could not arm bounded Quest wlan:dp_rx_udp_pkt trace"\nadb shell "su -c \'grep -q 1 $TRACE_INSTANCE/tracing_on && grep -q 1 $TRACE_EVENT/enable\'" >/dev/null 2>&1 || fail "Quest WLAN trace did not remain armed"\n\n' + needle
replace_once(needle, insert, "arm Quest WLAN trace")

replace_once(
    '[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"\n\nsnapshot_quest after\n',
    '[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"\n\nadb shell "su -c \'echo 0 > $TRACE_INSTANCE/tracing_on; echo 0 > $TRACE_EVENT/enable; cat $TRACE_INSTANCE/trace > $QUEST_TMP.wlan-dp-rx-udp.trace; cat $TRACE_INSTANCE/per_cpu/cpu*/stats > $QUEST_TMP.trace-stats\'" >/dev/null 2>&1 || fail "could not stop/preserve Quest WLAN trace after USB reconnect"\nadb exec-out su -c "cat \'$QUEST_TMP.wlan-dp-rx-udp.trace\'" >"$OUT/quest-wlan-dp-rx-udp.trace" || fail "could not retrieve Quest WLAN driver trace"\nadb exec-out su -c "cat \'$QUEST_TMP.trace-format\'" >"$OUT/quest-wlan-dp-rx-udp-format.txt" || fail "could not retrieve Quest WLAN trace format"\nadb exec-out su -c "cat \'$QUEST_TMP.trace-stats\'" >"$OUT/quest-wlan-trace-stats.txt" || fail "could not retrieve Quest WLAN trace-buffer stats"\n\nsnapshot_quest after\n',
    "stop and retrieve Quest WLAN trace",
)

path.write_text(text)
