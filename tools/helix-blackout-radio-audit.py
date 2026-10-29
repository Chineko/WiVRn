#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: helix-blackout-radio-audit.py <final-generated-capture-script>")

path = Path(sys.argv[1])
text = path.read_text()


def one(fragment: str, label: str) -> int:
    hits = []
    start = 0
    while True:
        pos = text.find(fragment, start)
        if pos < 0:
            break
        hits.append(pos)
        start = pos + 1
    if len(hits) != 1:
        raise SystemExit(f"Audit A: {label}: expected exactly one occurrence, found {len(hits)}")
    return hits[0]


anchors = {
    "trace_format": one('format lacks required field', 'trace-format fidelity gate'),
    "trace_probe": one('did not observe the setup UDP probe', 'live tracepoint preflight'),
    "trace_watchdog": one('could not launch Quest trace safety watchdog', 'detached trace watchdog'),
    "quest_capture_verified": one('detached Quest tcpdump exited before USB detach', 'Quest capture pre-detach gate'),
    "host_capture_launch": one('sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap"', 'host capture launch'),
    "host_capture_verified": one('host tcpdump did not report an active capture loop before CAPTURE ARMED', 'host capture readiness gate'),
    "usb_prompt": one('USB-DETACHED WORKLOAD MODE', 'USB detach prompt'),
    "zero_adb": one('Quest is still visible to ADB; unplug USB and ensure wireless ADB is disconnected', 'zero-ADB gate'),
    "capture_start": one('capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS', 'declared workload start'),
    "armed": one('CAPTURE ARMED. No ADB session remains attached during the workload.', 'CAPTURE ARMED banner'),
    "capture_end": one('capture_end_epoch_ns=$CAPTURE_END_EPOCH_NS', 'declared workload end'),
    "workload_complete": one('WORKLOAD COMPLETE', 'USB reconnect boundary'),
    "same_quest": one('reconnected ADB device does not match the Quest used for setup', 'same-Quest reconnect gate'),
    "trace_stop": one('could not stop/preserve Quest WLAN trace after USB reconnect', 'trace stop/preserve'),
    "trace_retrieve": one('quest-wlan-dp-rx-udp.trace', 'trace retrieval target'),
    "base_reduce": one('helix-blackout-reduce.py', 'paired-PCAP reducer invocation'),
}

expected_order = [
    "trace_format", "trace_probe", "trace_watchdog", "quest_capture_verified",
    "host_capture_launch", "host_capture_verified", "usb_prompt", "zero_adb",
    "capture_start", "armed", "capture_end", "workload_complete", "same_quest",
    "trace_stop",
]
positions = [anchors[name] for name in expected_order]
if positions != sorted(positions):
    raise SystemExit("Audit A: final observer/detach/workload/reconnect ordering is invalid")

# No host->Quest control session is allowed between the zero-ADB gate and the
# declared workload end. Post-workload host-only shutdown is allowed.
active = text[anchors["zero_adb"]:anchors["capture_end"]]
for forbidden in ('adb shell', 'adb exec-out', 'adb devices'):
    if forbidden in active:
        raise SystemExit(f"Audit A: {forbidden!r} remains in active detached workload window")

# No interactive sudo acquisition is allowed after USB detach. The background
# noninteractive keepalive is started and verified before the detach prompt.
if 'sudo -v' in text[anchors["usb_prompt"]:anchors["workload_complete"]]:
    raise SystemExit("Audit A: interactive sudo refresh remains after USB-detach prompt")
if 'sudo -n -v' not in text[:anchors["usb_prompt"]]:
    raise SystemExit("Audit A: sudo keepalive is not established before USB detach")

required = (
    'MAX_CAPTURE_SECONDS=480',
    'TRACE_WATCHDOG_SECONDS=570',
    'TRACE_BUFFER_KB=16384',
    'quest_driver_trace_event=wlan:dp_rx_udp_pkt',
    'attribution_scope=host_capture_to_quest_driver_trace_to_wlan',
    'quest-wlan-trace-stats.txt',
    'wifi_endpoint_state_consistent',
    'host-system-samples.txt',
    'tcpdump kernel-drop',
)
for fragment in required:
    if fragment not in text:
        raise SystemExit(f"Audit A: missing required integrity/safety element: {fragment}")

# Trace collection must be read-only with respect to WLAN configuration: only
# tracefs control files are written. No Wi-Fi property, link, channel, power,
# QoS, bitrate, pacing, or runtime setting may be changed by this slice.
for forbidden in (
    'setprop persist.vendor.wifi', 'cmd wifi set-', 'iw dev', 'iwconfig',
    'tc qdisc replace', 'ethtool -K', 'HELIX_NET_PACKETS_PER_BURST',
):
    if forbidden in text:
        raise SystemExit(f"Audit A: runtime/network mutation escaped scope: {forbidden}")

print("Audit A PASS: exact generated capture artifact satisfies lifecycle, isolation, cleanup, and scope gates.")
