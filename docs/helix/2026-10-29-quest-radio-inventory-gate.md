# Helix Quest radio capability inventory gate — 2026-10-29

## Purpose

Before spending the single remaining blackout reproduction, discover which Quest-side radio/driver/kernel telemetry surfaces actually exist on the rooted headset.

This is a setup/capability step, not a workload experiment and not an attribution result.

## Success condition

One USB/root-only command produces enough information to choose the strongest low-overhead Quest-side telemetry for the next and only planned reproduction run.

Useful outcomes include any of:

- Wi-Fi driver/module identity;
- driver statistics exposed by `ethtool -S`;
- station/radio statistics exposed by `iw`;
- readable sysfs/debugfs driver counters;
- relevant tracefs events;
- kernel/firmware messages that identify usable fault signals.

If none are exposed, that is itself decision-relevant: the final run should not add speculative tracing that the platform cannot support.

## Rule 40 evidence contract

Direct evidence from this step is limited to capability presence/absence and current static counter/log output.

This step does **not** prove where a blackout occurs and must not be used to infer AP, RF, firmware, or driver causation.

The engineering decision enabled by the inventory is only which Quest telemetry can be collected in the final reproduction without blind instrumentation.

## Rule 41 workflow

`tools/helix-quest-radio-inventory.sh` is one command. It discovers the active Quest Wi-Fi interface itself, requires exactly one USB ADB device, requires root, rejects wireless ADB, gathers the capability report, saves it under the user's home directory, and prints a bounded decision-relevant summary.

No source editing or manual device probing is required from the user.

## Rule 42 Audit A — local/function

Reviewed the inventory script control flow and command boundaries.

- `set -euo pipefail` is enabled.
- Required host commands are checked before device access.
- Exactly one ADB device is required.
- ADB serials containing `:` are rejected so wireless ADB is not used.
- Root is verified before privileged reads.
- The active Wi-Fi interface is derived from the Quest default route, with `wlan0` only as a fallback.
- Reads are bounded with `head`/`tail` where potentially large debugfs, tracefs, or kernel-log output is involved.
- Missing optional Quest tools such as `ethtool` or `iw` degrade to `unavailable` instead of failing the inventory.
- The script performs reads only; it does not enable tracepoints, change Wi-Fi configuration, modify sysfs/debugfs controls, start background processes, or alter WiVRn runtime state.
- The output file must be non-empty before success is reported.

User-machine Bash parsing/execution is not claimed until the committed script is run locally.

## Rule 42 Audit B — whole system

The inventory runs before the VR workload over USB and therefore does not share the measured wireless path during the final reproduction.

It adds no persistent process, tracepoint, sampler, packet capture, Wi-Fi configuration change, or runtime code change. Consequently it cannot perturb the later blackout workload except through ordinary state that already exists on the Quest.

The next-run instrumentation must be selected from the inventory result with the following priority:

1. already-maintained driver/firmware counters and logs;
2. low-rate read-only counters sampled locally on the Quest;
3. low-volume state/error tracepoints if they exist;
4. avoid high-volume packet/RX tracepoints unless no lower-overhead signal can answer the question.

The final reproduction remains limited to distinguishing evidence consistent with a Quest lower-driver/firmware fault from a clean Quest-side lower stack while packets remain absent from `wlan0`. Even with root, absence of a pre-`wlan0` receive signal cannot uniquely distinguish AP non-transmission, RF decode failure, and hardware/firmware rejection when the platform exposes no such observation point.

## Gate status

Capability-inventory implementation: committed.

Static Audit A: complete.

Whole-system Audit B for the inventory step: complete.

Final workload instrumentation: deliberately not implemented until the actual Quest capability report is available, avoiding speculative or unnecessarily invasive instrumentation.
