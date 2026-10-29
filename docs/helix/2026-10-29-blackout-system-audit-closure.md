# Helix blackout system-audit closure — 2026-10-29

This record closes the pre-run blockers identified in `2026-10-29-blackout-system-audit.md` without changing WiVRn runtime code.

## Scope decision

The next run is intentionally a **two-interface boundary attribution test**:

`host packet-capture point -> network/AP/RF/lower-driver region -> Quest wlan0 packet-capture point`

It is not a Linux `TX_SCHED/TX_SOFTWARE` experiment and it is not a Quest socket/syscall tracing experiment.

Therefore this run may establish whether traffic visible at the host capture point is also visible at the Quest `wlan0` capture point during a Helix-reported blackout. It may not claim physical NIC transmission, exact RF loss, Linux qdisc residence, or Quest kernel-to-userspace delivery without additional evidence.

If the paired capture leaves the boundary ambiguous, deeper TX timestamping or Quest receive tracing remains a later diagnostic slice rather than being silently inferred from this run.

## Closed blockers

1. **Persistent wireless ADB sessions removed.** Quest tcpdump is launched with a detached `nohup` process whose ADB setup command exits before `CAPTURE ARMED`. The exact detached lifecycle is preflighted first. No logcat ADB stream remains attached during the workload.
2. **Quest log write perturbation reduced.** Continuous `logcat -f` output to `/data/local/tmp` is removed. Android's existing in-memory log buffers are cleared before the run and dumped afterward.
3. **6 GHz conditions gated.** The harness parses `cmd wifi status`, requires a 6 GHz frequency before the run, records BSSID/frequency, and checks the post-run state. A changed/unknown radio path marks the reduced result non-decisive.
4. **Capture format preflighted.** A real ICMP capture is produced at both host and Quest capture points before VR. Both PCAP global headers must report Ethernet/DLT_EN10MB and both files must parse successfully.
5. **Local clock/capture correlation added.** The reducer retains a coarse global alignment only as a search aid. Each blackout window derives its own local offset from matching packets and reports local timing spread.
6. **Normal-traffic baseline and fingerprint uniqueness gated.** Each blackout window reports host/Quest packet counts, matched count, match ratio, unique matches, duplicate-fingerprint ratios, local offset, and local MAD. Weak correlation, excessive duplicates, or unstable local timing marks the result non-decisive rather than supporting a causal claim.
7. **Capture integrity remains explicit.** Host/Quest tcpdump kernel-drop counts remain part of the decision gate. A reduced bundle is still preserved when a decision gate fails so the run is not discarded blindly.
8. **Storage margin increased.** Quest capture requires at least 1.5 GiB free under `/data/local/tmp`; the host requires at least 2 GiB free before arming.
9. **Competing host load is observed.** A local-only one-second host sampler records total NIC counters, load average, CPU pressure, and `/proc/net/softnet_stat` throughout the workload. This adds no network traffic and allows avatar-download/host-pressure correlation to be checked instead of ignored.
10. **Tool workflow remains one-command.** `tools/helix-blackout-run.sh` verifies tooling/runtime identity, then delegates all network/capture preflight to one capture implementation instead of duplicating partially different preflight logic.

## Decision-capability contract

The reducer emits `decision_capable=true` only when its paired-capture integrity and local-correlation gates pass. Otherwise it emits `decision_capable=false` plus explicit `decision_blocker_N` entries while still preserving the reduced bundle.

A `decision_capable=true` result means the data are suitable for the declared **host-capture -> Quest-wlan** boundary question only. It does not upgrade the experiment into a deeper host-driver, RF, or Quest-socket attribution test.

## Runtime impact

No WiVRn runtime source, packet format, pacing setting, recovery mechanism, FEC behavior, RTX behavior, bitrate control, or decoder behavior is changed by this closure work.
