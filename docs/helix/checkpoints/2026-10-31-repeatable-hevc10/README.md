# Repeatable HEVC10 workload — saved current state

Date: 2026-10-31. Saved at the user's request before any further workload or encoder changes.

**Current state: implemented and run end-to-end; exact canary recovery PASS; full traffic fidelity NOT_ESTABLISHED.**

## Source and checkpoint identity

- Tested implementation: `dfaefc2f444ac6c9779a710d66623e2b453f5b20`.
- Branch: `helix-vrchat-hevc10-repeatable` (a destination/ref label, not source identity).
- Preserved original baseline: `392bb662ed20c6866af0942d219359518a885193`.
- This checkpoint is a documentation/results-only successor to the tested implementation. Its commit was not rebuilt or device-tested. The existing native artifacts remain tied to the exact tested commit above; do not label them as built from this documentation commit or bypass the runner's exact-commit check.
- No PR, issue, comment, integration merge, threshold adjustment or further workload repair is part of this checkpoint.

## What exists

The repository contains a canonical Python prepare/build/run/reduce tool, a deterministic graphics-bound Vulkan/OpenXR stimulus, a shared bounded UDP impairment scheduler, a pre-encode producer-stall/IDR controller, corrected Android probe/frame-metadata ordering, and component/mutation tests. The runner performs identity checks, installs only if APK bytes differ, launches the Quest explicitly, drives a bounded run, captures logs, tears down and reduces evidence. It uses no dashboard or prefix script and does not create ADB forwarding/reverse mappings.

The workload reuses the measured VRChat-derived model: seed 20261031, torture profile, 300 seconds, 26,933 stereo app submissions, six producer stalls, eight shared path events and six scheduled IDR requests. The calibrated total encoder bitrate is 45,921,000 bps. Both eyes use NVENC / H.265 / 10-bit, with resolved Main10 evidence. Host `192.168.0.44`, Quest `192.168.0.54`, explicit UDP-capable URI `wivrn://192.168.0.44`; ADB is used for installation, launch and evidence. Reliable IDRs retain WiVRn's normal LAN TCP control path.

The current local calibrated bundle and its exact native paths/hashes are recorded in [tested-artifacts.json](tested-artifacts.json). Binaries and complete raw captures remain local. This Git snapshot includes the model parameters, original reducer result, selected direct evidence and audit records.

## Latest completed run (run 02)

- Runtime/recovery gate: **PASS**; reducer errors: none.
- Both canaries satisfy exact drop → actual RTX send → matching received sequence → assembly → exact MediaCodec output → matching AImage.
- Eye 0: frame 607, packet sequence 13227, image frame 607.
- Eye 1: frame 907, packet sequence 19829, image frame 907.
- Probe overflow: 0 on both eyes; no pending media/image probes at teardown.
- All six planned production stalls were observed; actual IDR coverage passed on both eyes.
- Path scheduler: 1,183,759 sends; drops 177/205 by eye; failures=0; cancellations=0; peak queue 230 packets / 314,005 payload bytes; maximum scheduling lateness 1,579 us.

| Measurement | Eye 0 | Eye 1 |
|---|---:|---:|
| Encoded frames | 26,958 | 26,955 |
| Mean frame bytes | 29,778 | 29,773 |
| Maximum frame bytes | 62,005 | 83,785 |
| Mean frame gap (us) | 11,127 | 11,128 |
| Maximum frame gap (us) | 79,675 | 78,555 |

The reference mean is 29,731 bytes; reference maximum is 60,719 bytes. The existing peak gate allows up to 75,898.75 bytes (1.25 × reference maximum). Eye 1's 83,785-byte peak failed that unchanged gate. Thus **traffic_calibration=NOT_ESTABLISHED** and **overall=NOT_ESTABLISHED**, despite runtime/recovery PASS. Do not rewrite this as an overall calibrated PASS.

Pixel cleanliness remains **NOT_ESTABLISHED**. This is a traffic/decoder workload, with no pixel-content oracle or measurement of equivalent VRChat rendering cost. A second identical-artifact repeat run has not been performed.

## Earlier run and completed repairs

Run 01 completed unattended and captured both exact canary chains, but had a capability-probe summary contaminating the reducer, inherited an uncontrolled 50 Mbps bitrate, and failed to turn application pauses into real encoder gaps. Its original FAIL/NOT_ESTABLISHED result and full failure audit are preserved. The tested successor scoped the probe, enforced the explicit bitrate, and inhibited production before acquiring compositor images/present slots. No acceptance thresholds were loosened.

## Audit and Rule 40 status

- Full Audit A and Audit B passed **before** run 02 for that exact artifact set; see [pre-run-audits.md](pre-run-audits.md).
- The traffic-calibration miss invalidated the active audit gate. **Current runtime gate: CLOSED**, requiring full failure-class Audit A/B before another device run.
- Direct evidence: completed automation, exact per-eye recovery chains, zero probe overflow, measured production gaps/IDRs, path timing/bounds, and the right-eye peak mismatch. See [run-02-result.json](run-02-result.json) and [run-02-evidence.txt](run-02-evidence.txt).
- Supported inference: the production controller and bitrate calibration corrected the run-01 mean/cadence defects. The existing telemetry does not identify the exact oversized frame.
- Remaining ambiguity: the cause/frame identity of the 83,785-byte peak; stability of the peak distribution across repeated runs; pixel contents. No encoder/stimulus cause has been established for that outlier.
- Decision: preserve this checkpoint before changing anything. Next, audit the oversized-frame evidence and add only the necessary measurement before choosing a repair. Keep thresholds frozen and repeat both full audits before a further runtime attempt.

## Validation and deliberately unfinished work

Server/OpenXR runtime, Quest APK and stimulus builds passed. ELF architecture/export/manifest checks and independent SHA-256 checks passed. Five reducer tests, malformed plan/bitrate rejection tests, asynchronous payload lifetime/FIFO tests and producer-boundary/deferred-IDR tests passed. The frozen original server/APK/metadata hashes were unchanged.

The single fish launcher was created and syntax-checked locally, but its repeat invocation has **not** been executed because traffic fidelity did not pass and the gate is closed. Do not present it as a validated ready-to-repeat release.

Deferred: exact peak-frame diagnosis, any further encoder/stimulus modifications, another identical-artifact run, pixel oracle, tuning/promotion and unrelated changes. No additional runtime is part of this Git checkpoint request.
