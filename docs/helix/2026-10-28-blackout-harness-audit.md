# Helix blackout attribution harness audit — 2026-10-28

## Purpose

This audit was performed before another headset run because prior capture attempts exposed process, privilege, packaging, and timestamp-correlation flaws. The goal is to make the next reproduction session decision-capable rather than merely collect more data.

## Governing rules applied

- Rule 7: stop repeating a failing tool strategy.
- Rule 18: unexpectedly broad changes are a stop condition.
- Rule 27: do not claim validation that was not performed.
- Rule 30: every diagnostic must be decision-relevant.
- Rule 34/35: Quest validation requires matching desktop evidence and verified runtime identity.
- Rule 37: user commands must be shell-compatible; the harness is invoked explicitly through Bash.
- Rule 40: conclusions must remain proportional to the evidence.
- Rule 41: minimize manual user-side workflow and verification loops.

## Audit findings

### 1. Streaming Quest PCAP over wireless ADB would perturb the path under test

The Quest uses wireless ADB on `wlan0`. Streaming `tcpdump -w -` through `adb exec-out` would send the high-volume capture back over the same Wi-Fi link whose blackout behavior is being measured.

Decision: do not stream PCAP or logcat over ADB during the VR workload. Write both locally on the Quest and pull them only after the capture boundary is closed.

### 2. Foreground root context must be preserved for Quest tcpdump

Manual validation proved `/system/bin/tcpdump -Z root` can capture on `wlan0`. Earlier nested/background launch variants could fail despite that capability.

Decision: keep tcpdump as the foreground process of an attached rooted ADB shell, but write the PCAP locally on the Quest. Record its PID before `exec` so it can be stopped cleanly.

### 3. Capture startup must fail before headset use

Earlier versions could discover capture failure only after a VR session.

Decision: preflight root, tcpdump filter compilation, a real one-packet local Quest capture, free storage, host privileges, process liveness, and PCAP header creation before printing `CAPTURE ARMED`.

### 4. Runtime identity and tooling identity are different

The blackout branch intentionally adds only docs/tools on top of validated runtime base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a`. Recording branch HEAD alone as runtime identity is misleading.

Decision: guard that tracked runtime source is unchanged relative to the validated base, record the tooling commit separately, and capture server/Quest runtime identity from the produced logs.

### 5. Old dashboard log events must not enter the current capture

A dashboard process may already be running and its log may contain prior sessions.

Decision: record a precise current-run capture boundary and have the reducer accept only gap events whose report timestamp falls within that boundary.

### 6. The report timestamp is not the loss timestamp

For a fully mapped gap, `report_delay` is measured from the last mapped missing packet send-attempt to report receipt, while `send_span` measures first-to-last mapped missing send attempts.

Decision: reconstruct the sender-side missing interval as:

`last_missing_send = report_timestamp - report_delay`

`first_missing_send = last_missing_send - send_span`

Reduction windows are built around that reconstructed interval, not blindly around the later report timestamp.

### 7. Host and Quest PCAP clocks cannot be assumed synchronized

PC and Quest packet timestamps come from different machines. Wall-clock agreement at second resolution is insufficient for millisecond blackout analysis.

Decision: align the Quest capture to the host capture using identical PC-to-Quest UDP ciphertext prefixes and UDP metadata seen at both ends. The reducer uses the median timestamp delta from many matched datagrams and reports the median absolute deviation. This removes dependence on manually synchronized clocks.

### 8. Missing packets in a capture are meaningful only if the capture itself did not drop

A packet absent from the Quest PCAP cannot be treated as path loss if tcpdump dropped packets locally.

Decision: require both host and Quest tcpdump statistics to report zero kernel capture drops for a decisive run. Otherwise the reducer refuses to produce a decisive bundle.

### 9. Live socket evidence must be collected before server shutdown

Stopping WiVRn before the post-run socket snapshot can destroy the state needed to distinguish receive-buffer/socket behavior.

Decision: mark the experiment end, collect host and Quest post-run socket/network counters while the session is still alive, then stop captures/server.

### 10. Full archives are unnecessary and wasteful

The full PCAP pair is large and encrypted payload compresses poorly.

Decision: keep the original capture directories locally, but do not create a full tar archive. Automatically reduce to decision-relevant windows and produce only the reduced upload bundle.

## Validation performed on the tooling

The audited capture script was checked with `bash -n`.

The reducer was checked with Python bytecode compilation and an end-to-end synthetic PCAP test containing:

- Ethernet/IPv4/UDP packets with unique high-entropy payload prefixes;
- host and Quest captures deliberately offset by `+2.345678 s`;
- one fully mapped Helix gap with known `send_span` and `report_delay`;
- zero tcpdump kernel drops.

The reducer matched 1,000 identical UDP packets, recovered a median Quest clock offset of approximately `+2.345678 s` with near-zero median absolute deviation, reconstructed the expected sender loss interval, retained the correct packet windows, and generated a small reduced archive.

## Remaining limitations

- `wlan0` packet capture observes packets only once they reach the Quest kernel/libpcap capture point; absence there cannot distinguish AP/air loss from lower Quest NIC/firmware/driver loss before that point.
- Host packet capture proves visibility at the host capture point, not physical RF transmission.
- The host-to-Quest packet matcher assumes Ethernet (`DLT_EN10MB`) captures and immutable UDP payload bytes end to end. The reducer checks link type and refuses unsupported captures.
- Packet matching aligns clocks and supports boundary attribution; it does not expose Helix packet sequence numbers because the UDP stream payload is encrypted.
- If the reproduced blackout does not occur, or either capture reports kernel drops, the run is non-decisive and must not be promoted into a causal conclusion.

## Expected next-run workflow

One command starts the harness. It performs all preflight checks before printing `CAPTURE ARMED`, collects the paired PC/Quest evidence locally, snapshots live counters, pulls Quest artifacts after the run, selects only current-run server events, aligns PCAP clocks by packet identity, validates capture integrity, and automatically emits a reduced uploadable bundle.

No recovery mechanism, pacing parameter, FEC parameter, RTX threshold, or decoder behavior is changed by this diagnostic slice.
