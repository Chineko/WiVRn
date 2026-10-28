# Helix blackout attribution harness audit — pass 2 — 2026-10-28

## Purpose

A second independent pre-run audit was performed after the first harness audit because the next headset run is intended to close the shared-path attribution stage. The goal was to look specifically for ways the diagnostic itself could perturb the path, validate the wrong runtime, or preserve data with insufficient timing integrity.

## Additional findings and fixes

### 1. Android package `versionName` is not a reliable WiVRn runtime identity

WiVRn's Gradle configuration can legitimately use a generic Android package version while the native client embeds the git-derived WiVRn runtime version used in logcat.

Decision: the preflight now reads the installed base APK, opens its native shared libraries, and requires the validated runtime id `ffdc6bb7` to be embedded in the installed native code. The desktop server binary is independently checked for the same runtime id.

### 2. Default tcpdump capture buffers could invalidate a good network run

At high VR packet rates, a temporary scheduler or storage stall could cause tcpdump-local packet loss. Since absence from the Quest PCAP is meaningful only when the capture itself did not drop packets, this could turn a useful reproduction into a non-decisive run.

Decision: both host and Quest captures now request a 16 MiB capture buffer. The Quest preflight uses the same buffer option, so an unsupported option fails before `CAPTURE ARMED`. The reducer still requires zero tcpdump kernel drops for decisive attribution.

### 3. Packet-buffered `tcpdump -U` writes unnecessarily perturb the Quest

Immediate packet-buffered writes are unnecessary because the PCAP is never consumed during the workload and tcpdump is stopped cleanly with SIGINT. At VR packet rates, packet-buffered output can increase write/syscall pressure on the Quest and become part of the workload being measured.

Decision: remove `-U` from both captures and use normal buffered PCAP output. Clean SIGINT shutdown remains responsible for flushing the files before they are pulled/analyzed.

## Timing-model recheck

The reducer's global host/Quest clock offset is used only to retain broad decision windows with one second of padding. That is sufficient to preserve nearby corresponding traffic even if the two device clocks drift modestly over a five-minute run.

For final millisecond-level interpretation, packet timing should be locally re-aligned around each retained blackout using identical host/Quest UDP fingerprints from the reduced captures. The global offset alone must not be presented as millisecond-accurate causal timing.

## Capture semantics recheck

The capture filter is intentionally one-way PC-to-Quest UDP traffic. It excludes wireless ADB TCP traffic and therefore prevents the large diagnostic streams from appearing in the packet comparison. High-volume Quest PCAP and logcat data remain local on the headset until the experiment boundary has closed.

The Quest `wlan0` capture point remains a kernel/libpcap boundary, not a raw RF/firmware trace. A packet absent there supports loss before that capture point, but cannot by itself separate PC lower-NIC/driver, router/AP, RF, or Quest Wi-Fi firmware/driver loss below PF_PACKET.

## Repository/runtime recheck

A repository comparison against `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a` shows the attribution branch changes only files under `docs/` and `tools/`. No WiVRn runtime source is changed by the diagnostic branch.

## Validation limitation

An independent sandbox clone/syntax run was attempted but the sandbox cannot resolve github.com, so that external validation path could not execute. This is recorded as a tooling limitation, not a successful test.

The user-side preflight therefore remains authoritative for executable validation: it runs `bash -n` on the committed capture harness, Python compilation on the reducer, validates installed Quest native runtime identity, validates the desktop server binary identity, proves rooted tcpdump can create a local PCAP, proves the PCAP can be pulled and parsed, and refuses to proceed unless those gates pass.

## Run gate

Do not start VR unless the wrapper prints both the preflight success message and `CAPTURE ARMED`.

If the reducer later reports tcpdump kernel drops, missing capture coverage, missing current-run gap events, or invalid clock alignment, the run is non-decisive and no causal boundary should be claimed from it.