# Helix blackout attribution system audit — 2026-10-29

## Purpose

This is a whole-experiment audit, not a function-level code review. It checks whether the next reproduction run can actually answer the engineering decision Helix needs without silently depending on unmeasured assumptions.

The audit covers the chain:

`reproduction workload -> host/runtime state -> PC capture boundary -> network/AP/RF path -> Quest interface boundary -> Quest kernel/socket -> WiVRn userspace -> gap telemetry -> reducer/correlation -> causal conclusion`

The next headset run is **not approved yet**. The blockers below must be addressed or explicitly narrowed before `CAPTURE ARMED` is treated as decision-capable.

## Findings

### 1. The written slice and the implemented harness currently promise different attribution depth

The design document calls for Linux `SO_TIMESTAMPING` (`TX_SCHED` and `TX_SOFTWARE`) and, when practical, Quest socket/syscall receive observation. The implemented harness currently collects paired PC/Quest interface PCAPs, before/after counters, server logs, and Quest logs.

Therefore the current harness can directly classify only a coarser boundary:

- packet visible at the host packet-capture point;
- packet visible or absent at the Quest `wlan0` packet-capture point;
- WiVRn later reports a sequence gap.

It cannot by itself prove abnormal Linux qdisc residence, prove physical NIC transmission, or distinguish Quest kernel/socket delivery from WiVRn userspace receive/decrypt/dispatch when a packet is visible at `wlan0`.

Decision: either add the missing low-level observations before the run, or explicitly narrow the success condition. Do not claim the deeper design buckets from dual-PCAP evidence alone.

### 2. Persistent wireless ADB sessions still exist during the workload

The harness correctly stopped streaming PCAP/logcat data over wireless ADB, but it still launches Quest tcpdump and logcat through foreground `adb shell` sessions held open for the entire run.

That traffic is much smaller than streaming a PCAP, but it is not zero and contradicts the intended non-perturbing design.

Decision: prefer fully detached local Quest processes whose ADB setup sessions exit before `CAPTURE ARMED`. Preflight the exact detached launch/stop/pull lifecycle before using it in VR.

### 3. Reproduction conditions do not currently gate the intended 6 GHz link

Previous attribution work established the Quest on the intended 6 GHz link, but the current preflight does not fail if the headset roams to 5 GHz, changes BSSID, or otherwise changes radio conditions before the run.

Decision: record and gate the active Wi-Fi frequency/band before `CAPTURE ARMED`, and record BSSID/RSSI/link-rate information when available. If the platform output cannot be parsed reliably, fail before VR and report the status rather than silently changing conditions.

### 4. Capture link type is validated only after the expensive run

The reducer requires Ethernet (`DLT_EN10MB`) captures for its current packet parser. The preflight proves the Quest can produce and pull a PCAP but does not yet reject an incompatible link type before headset use.

Decision: parse the preflight PCAP global header and verify link type/snaplen before the run. Do the corresponding host-interface sanity check before `CAPTURE ARMED`.

### 5. Clock alignment is currently global, not local to each blackout

The reducer derives one Quest-vs-host timestamp offset from up to the first 1,000 matching packets and applies it to all blackout windows. That is adequate for retaining a generous +/-1 s window, but it is not evidence for millisecond-level clock agreement over a multi-minute run.

Decision: retain the broad windows, then derive a local offset from matching normal packets immediately around each blackout before making millisecond timing claims. If local alignment is unstable, classify only packet presence/absence, not sub-millisecond ordering.

### 6. The reducer does not yet enforce a local normal-traffic match baseline

Finding enough identical packets to align clocks does not prove that the two capture points observe ordinary traffic symmetrically around a specific event. Capture offload, link-layer representation, fingerprint collisions, or capture-side behavior could otherwise mimic missing packets.

Decision: before treating host-present/Quest-absent packets as path loss, compute a nearby normal-traffic match ratio and fingerprint uniqueness/collision rate. Refuse a causal classification if the local baseline itself does not correlate strongly.

### 7. Packet-fingerprint uniqueness is assumed rather than empirically gated

The current matcher uses UDP metadata plus a truncated payload prefix. Encryption makes uniqueness plausible, but the experiment should not depend on that assumption.

Decision: report duplicate fingerprint frequency in each local analysis window. If duplicates are non-negligible, use a longer/full captured payload fingerprint or another discriminator before classifying packet absence.

### 8. Quest capture storage/I/O is part of the experiment

The capture is written locally under `/data/local/tmp`, and the existing free-space gate requires only 512 MiB. Earlier runs produced multi-million-packet captures, so a five-minute run can plausibly consume hundreds of MiB even with snaplen truncation. Local logcat also writes continuously.

The previous audit already improved this by removing tcpdump `-U` and increasing packet-capture buffers, but the storage budget is still static and potentially too small.

Decision: raise the free-space margin substantially or bound/rotate the capture in a way that preserves every event needed for analysis. Treat capture/local-log write load as possible perturbation and compare runtime health against prior runs.

### 9. Continuous local `logcat -f` adds Quest storage activity

Although it avoids wireless ADB traffic, `logcat -f` continuously writes to flash during the exact workload under study.

Decision: consider using the existing in-memory Android log buffers and dumping them after the run, with a verified buffer capacity large enough for the reproduction period, or explicitly measure/accept the local write overhead. Do not describe the instrumentation as non-perturbing while ignoring this write path.

### 10. The avatar reproduction workload introduces a competing host/router load that is currently filtered out

Loading/unloading many avatars can generate substantial WAN downloads, decompression/CPU work, storage traffic, and router forwarding load. The paired PCAP intentionally captures only PC-to-Quest UDP, so it can completely miss a simultaneous WAN/host-load spike.

This matters because the observed blackout may be associated with router/AP contention or host scheduler/network pressure induced by the reproduction workload rather than an isolated Wi-Fi random-loss mechanism.

Decision: add low-overhead local host telemetry during the same run: total NIC RX/TX byte/packet rates, CPU/softnet pressure, and relevant qdisc/NIC counters. This must be local-only and should not add network traffic.

### 11. Host packet capture is not proof of physical transmission

A packet visible in the host PCAP is visible at the host packet-capture point. Depending on Linux capture placement/offload, that is not equivalent to proving it physically left the NIC. Zero qdisc drops and zero obvious NIC TX errors strengthen the inference but do not convert it into proof.

Decision: preserve this limitation in every conclusion. If the next result is host-present/Quest-absent, the supported boundary remains somewhere after the host capture point and before the Quest capture point unless stronger TX evidence is added.

### 12. Quest `wlan0` absence still combines several physical/lower-driver possibilities

A packet absent from a clean Quest `wlan0` PCAP can be lost at the host lower NIC/driver, wired/router/AP path, RF hop, or below the Quest packet-capture point in Wi-Fi firmware/driver processing.

Decision: that result is still useful for Helix because it separates userspace receive/decoder mechanisms from path loss, but it does not identify the exact physical hop. Do not write “wireless RF loss proven” unless additional evidence supports it.

## What is already sound

- Runtime source remains equivalent to validated base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a`; branch changes are docs/tools only.
- Desktop/Quest build identity is gated before the run, with runtime identity captured again afterward.
- Quest root and tcpdump capability are checked before headset use.
- Root-created PCAP pull/readability is preflighted.
- Host and Quest PCAPs use the same narrow PC-to-Quest UDP direction.
- Capture buffers were enlarged and tcpdump packet-buffered `-U` writes were removed.
- High-volume PCAP data is kept local to the Quest during the workload.
- Gap windows are reconstructed from `report_delay` and `send_span`, not centered blindly on report receipt.
- Old server-log events are bounded to the current run.
- Live socket/network counters are taken before shutdown.
- The reducer refuses missing/empty captures and nonzero tcpdump kernel-drop counts.
- Full giant archives are not the intended upload artifact; decision windows are reduced automatically.

## Required pre-run closure

Before another headset run, close these items:

1. Decide whether to add PC TX / Quest socket-level instrumentation or explicitly narrow the run's success condition to the two interface capture points.
2. Remove persistent wireless ADB sessions during the workload, or document and justify them as accepted perturbation.
3. Gate/record the intended 6 GHz radio state.
4. Preflight the exact PCAP link type used by the reducer.
5. Add local per-event alignment/baseline/collision validation to the analysis path.
6. Increase/bound Quest storage budget and reconsider continuous `logcat -f` write load.
7. Add low-overhead host total-network/CPU/softnet telemetry so avatar-download/router/host-load correlation is not invisible.

Until these are closed, another run can still provide useful evidence, but it should not be advertised as the final attribution run.
