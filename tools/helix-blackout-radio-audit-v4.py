#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: helix-blackout-radio-audit-v4.py <final-generated-capture-script>")

text = Path(sys.argv[1]).read_text()


def one(fragment: str, label: str) -> int:
    hits = []
    pos = 0
    while True:
        i = text.find(fragment, pos)
        if i < 0:
            break
        hits.append(i)
        pos = i + 1
    if len(hits) != 1:
        raise SystemExit(f"Audit A: {label}: expected exactly one occurrence, found {len(hits)}")
    return hits[0]


anchors = {
    "format": one('format lacks required field', 'trace format gate'),
    "trace_arm": one('could not arm bounded Quest wlan:dp_rx_udp_pkt trace', 'trace arm'),
    "watchdog": one('could not launch Quest trace/capture safety watchdog', 'Quest watchdog'),
    "quest_ready": one('detached Quest tcpdump exited before USB detach', 'Quest tcpdump readiness'),
    "sync_start": one('did not observe sync-start UDP port', 'sync-start gate'),
    "sudo_refresh": one('could not refresh sudo credentials immediately before host capture', 'sudo refresh'),
    "host_launch": one('sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap"', 'host tcpdump launch'),
    "host_ready": one('host tcpdump did not report an active capture loop before CAPTURE ARMED', 'host tcpdump readiness'),
    "detach_prompt": one('USB-DETACHED WORKLOAD MODE', 'USB detach prompt'),
    "zero_adb": one('Quest is still visible to ADB; unplug USB and ensure wireless ADB is disconnected', 'zero-ADB gate'),
    "start": one('capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS', 'capture start'),
    "armed": one('CAPTURE ARMED. No ADB session remains attached during the workload.', 'CAPTURE ARMED'),
    "end": one('capture_end_epoch_ns=$CAPTURE_END_EPOCH_NS', 'capture end'),
    "sync_end_send": one('helix-trace-sync-end', 'post-workload sync-end send'),
    "complete": one('WORKLOAD COMPLETE', 'workload complete boundary'),
    "same_quest": one('reconnected ADB device does not match the Quest used for setup', 'same-Quest gate'),
    "sync_end_verify": one('did not retain sync-end UDP port', 'sync-end retention gate'),
    "trace_stop": one('could not stop/preserve Quest WLAN trace after USB reconnect', 'trace stop/preserve'),
    "trace_pull": one('>"$OUT/quest-wlan-dp-rx-udp.trace"', 'trace retrieval'),
    "base_reduce": one('python3 "$ROOT/tools/helix-blackout-reduce.py" "$OUT"', 'base reducer'),
}

ordered = [
    "format", "trace_arm", "watchdog", "quest_ready", "sync_start",
    "sudo_refresh", "host_launch", "host_ready", "detach_prompt", "zero_adb",
    "start", "armed", "end", "sync_end_send", "complete", "same_quest",
    "sync_end_verify", "trace_stop", "trace_pull", "base_reduce",
]
positions = [anchors[k] for k in ordered]
if positions != sorted(positions):
    raise SystemExit("Audit A: exact final observer/sync/detach/workload/reconnect/reduction order is invalid")

# No host->Quest control session exists inside the declared workload interval.
active = text[anchors["zero_adb"]:anchors["end"]]
for forbidden in ('adb shell', 'adb exec-out', 'adb devices'):
    if forbidden in active:
        raise SystemExit(f"Audit A: {forbidden!r} remains inside active USB-detached workload")

# The end sync is explicitly outside the measurement interval and before USB
# reconnect. It is the only deliberate host->Quest probe in that transition.
post = text[anchors["end"]:anchors["complete"]]
if 'helix-trace-sync-end' not in post:
    raise SystemExit("Audit A: end sync is not in post-workload/pre-reconnect boundary")
if 'adb shell' in post or 'adb exec-out' in post or 'adb devices' in post:
    raise SystemExit("Audit A: ADB control appears before USB reconnect")

if 'sudo -v' in text[anchors["detach_prompt"]:anchors["complete"]]:
    raise SystemExit("Audit A: interactive sudo refresh remains after detach prompt")
if 'sudo -n -v' not in text[:anchors["detach_prompt"]]:
    raise SystemExit("Audit A: sudo keepalive is not established before detach")

required = (
    'MAX_CAPTURE_SECONDS=480',
    'TRACE_WATCHDOG_SECONDS=960',
    'DETACH_PROMPT_SECONDS=180',
    'RECONNECT_PROMPT_SECONDS=120',
    'TRACE_BUFFER_KB=32768',
    'TRACE_SYNC_START_PORTS="49171,49172,49173"',
    'TRACE_SYNC_END_PORTS="49271,49272,49273"',
    'quest_driver_trace_event=wlan:dp_rx_udp_pkt',
    'quest_driver_trace_sync_start_ports=$TRACE_SYNC_START_PORTS',
    'quest_driver_trace_sync_end_ports=$TRACE_SYNC_END_PORTS',
    'attribution_scope=host_capture_to_quest_driver_trace_to_wlan',
    'read -r -t "$DETACH_PROMPT_SECONDS"',
    'read -r -t "$RECONNECT_PROMPT_SECONDS"',
    'trace-watchdog.pid',
    'tcpdump.pid',
    'quest-wlan-trace-stats.txt',
    'wifi_endpoint_state_consistent',
    'host-system-samples.txt',
    'host-tcpdump.txt',
    'quest-tcpdump.txt',
    'rmdir $TRACE_INSTANCE',
)
for fragment in required:
    if fragment not in text:
        raise SystemExit(f"Audit A: missing required lifecycle/integrity element: {fragment}")

for forbidden in (
    'setprop persist.vendor.wifi', 'cmd wifi set-', 'iw dev', 'iwconfig',
    'tc qdisc replace', 'tc qdisc add', 'ethtool -K',
    'HELIX_NET_PACKETS_PER_BURST', 'HELIX_NET_PACKET_SPACING',
):
    if forbidden in text:
        raise SystemExit(f"Audit A: out-of-scope runtime/network mutation present: {forbidden}")

if 'echo 0 > $TRACE_INSTANCE/events/enable' not in text:
    raise SystemExit("Audit A: trace instance is not globally disabled before selective enable")
if text.count('echo 1 > $TRACE_EVENT/enable') != 1:
    raise SystemExit("Audit A: expected exactly one selective dp_rx_udp_pkt enable")
if 'echo 1 > $TRACE_INSTANCE/events/enable' in text:
    raise SystemExit("Audit A: all trace events are enabled")

print("Audit A PASS: final generated capture artifact satisfies ordering, measurement isolation, bounds, cleanup, and scope gates.")
