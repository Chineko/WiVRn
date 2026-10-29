# Helix blackout dual-audit gate — 2026-10-29

This checkpoint applies Development Rule 42 to the blackout-attribution tooling after the system-audit closure changes.

## Audit A — local/function audit

Reviewed the concrete control flow and interfaces of:

- `tools/helix-blackout-run.sh`
- `tools/helix-blackout-capture.sh`
- `tools/helix-blackout-reduce.py`

The audit checked command dependencies, cleanup paths, detached Quest process lifecycle, capture preflight, PCAP parsing assumptions, storage bounds, capture duration, metadata integration, local packet-correlation logic, duplicate handling, and reducer decision gating.

Findings discovered and fixed during this audit:

1. Host ICMP/tcpdump preflight could wait indefinitely if no packet was captured. It is now bounded by an 8-second timeout.
2. `helix-blackout-capture.sh` used `pgrep` without declaring it as a required command. It is now included in the dependency preflight.
3. Capture and reducer Wi-Fi metadata keys diverged after the system-audit change. They now use `wifi_endpoint_state_consistent` consistently.
4. Capture duration remained user-unbounded. It now auto-stops after 480 seconds so a missed Enter cannot silently turn the experiment into a storage-pressure test.

The wrapper still performs a real Bash syntax check of the committed capture harness and Python compilation check of the committed reducer on the user's machine before runtime state is touched. Those checks have not yet been executed on the user's updated checkout, so this document does not claim they have passed there.

## Audit B — whole-system audit

Reviewed the experiment end to end:

`avatar workload -> host load -> host capture -> network/AP/RF/lower-driver region -> Quest wlan0 capture -> Helix gap telemetry -> reducer -> engineering conclusion`

The experiment is deliberately narrowed to the two-interface boundary. It does not claim Linux `TX_SCHED/TX_SOFTWARE`, physical RF transmission, or Quest socket/userspace delivery evidence.

System-level protections now include:

- no persistent ADB session during the active workload;
- Quest tcpdump launched detached and preflighted using the same mechanism;
- no continuous local `logcat -f` writer;
- 6 GHz required before arming;
- BSSID/frequency endpoint state recorded before and after;
- host and Quest Ethernet PCAP link types verified before VR;
- 16 MiB tcpdump capture buffers;
- 1.5 GiB minimum Quest free space and 2 GiB minimum host free space;
- hard 480-second capture duration;
- local-only host NIC/load/CPU-pressure/softnet sampling;
- per-blackout local packet-clock alignment;
- local PC-to-Quest match-rate baseline;
- fingerprint duplicate-rate gating;
- tcpdump kernel-drop gating;
- explicit `decision_capable=true/false` output with blockers preserved in the reduced bundle.

## Remaining limitations — not blockers for the declared scope

- Host packet capture proves visibility at the host capture point, not physical transmission from the NIC.
- Quest `wlan0` absence combines host lower-driver/NIC, wired/router/AP, RF, and Quest lower-driver/firmware possibilities.
- Matching BSSID/frequency before and after the run does not prove there was no transient roam in the middle; it records endpoint consistency only.
- Android in-memory log buffers may not retain every log line from the full run; logs are supporting evidence rather than the primary two-interface decision signal.
- Router/AP internal queue state and traffic from unrelated devices are not directly observed. Host total-network/CPU telemetry covers the reproduction machine's competing load but not every external network participant.
- Deeper PC TX timestamping or Quest socket/syscall tracing remains a follow-up only if the two-interface result is insufficient.

## Gate status

Static local/function audit: **complete after fixes**.

Whole-system audit: **complete for the explicitly narrowed host-capture -> Quest-wlan scope**.

Repository/runtime scope: branch remains docs/tools-only relative to validated runtime base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a`.

User-machine executable preflight: **not yet run after these commits**. The next local command must pass its preflight before `CAPTURE ARMED` is considered valid.
