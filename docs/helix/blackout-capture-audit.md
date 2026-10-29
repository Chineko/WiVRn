# Blackout capture validation audit

This note records the Rule 40–42 gate for the USB-detached real-WiVRn blackout capture.

## Engineering question

When WiVRn reports a Helix packet-gap event during a reproduced blackout, were the corresponding PC-to-Quest UDP packets visible at the host capture point also visible at the Quest `wlan0` capture point?

## Rule 42 Audit A — local/function audit

The capture preflight validates the concrete capture and reducer scripts before runtime work, verifies the validated runtime source identity, checks matching desktop and Quest native runtime identity, validates root and tcpdump availability, verifies both PCAP link types with a real preflight packet, and checks storage.

`tools/helix-blackout-usb-detached-run.sh` applies guarded, exactly-once transformations to the existing audited capture harness and syntax-checks both generated Bash scripts before running them. The wrapper:

- requires the initial ADB transport to be USB, not wireless;
- verifies the detached Quest tcpdump is running before USB removal;
- requires zero ADB devices before the measured workload begins;
- records the measured capture start only after USB is detached;
- performs no ADB command during the measured workload;
- stops host-side observers at the declared capture end;
- explicitly asks for USB reconnection before Quest post-run snapshots and retrieval;
- verifies the reconnected device is the same USB Quest and is not wireless ADB.

No source/runtime behavior is modified; the change is limited to capture orchestration.

## Rule 42 Audit B — whole-system audit

The paired capture observes the path at two boundaries:

1. the host wired-interface capture point;
2. the Quest `wlan0` capture point.

The reducer reconstructs current-run Helix gap windows from the server log, aligns host and Quest PCAP clocks by matching identical UDP packet fingerprints, then independently checks local alignment and match quality around every decision window. It rejects low match ratios, excessive fingerprint duplication, insufficient local matches, excessive local timing spread, endpoint/BSSID changes, missing PCAP coverage, and tcpdump kernel drops.

Starting the Quest capture before USB detach and stopping it after USB reconnect creates harmless extra Quest-side capture tail. Decision windows are derived from the host-side current-run capture interval, packet alignment only uses fingerprints that also exist in the host PCAP, and the reduced Quest PCAP is trimmed to locally aligned decision windows.

## Rule 40 evidence limits

### Direct evidence

A decision-capable run can establish whether a host-visible PC-to-Quest UDP packet is also visible at the Quest `wlan0` capture point around a reproduced Helix gap event.

### Supported inference

If host-visible packets are absent from the Quest capture during the event while surrounding correlation remains healthy, the loss occurred somewhere after the host capture point and before the Quest `wlan0` capture point.

If the same packets are visible at both capture points, the failure lies after the Quest `wlan0` capture point or in higher-level packet/frame/decoder handling.

### Remaining ambiguity

An absence at the Quest capture point does **not** by itself distinguish among AP/router buffering or loss, RF delivery/retry failure, and portions of the Quest Wi-Fi/driver path below the `wlan0` packet-capture tap.

Running tcpdump on the host and Quest is an observer and may perturb timing or load. Therefore, a reproduced blackout under capture is attributable within the measured boundaries, but failure to reproduce a blackout under capture does not prove the observer-free system is healthy.

The test does not provide an over-the-air 802.11 observation point and must not be described as proving the exact RF or AP cause.

## Gate decision

The USB-detached paired capture is suitable for the next runtime validation cycle **for host-capture -> Quest-`wlan0` attribution**, subject to the reducer returning `decision_capable=true` and an actual current-run Helix gap event being reproduced.
