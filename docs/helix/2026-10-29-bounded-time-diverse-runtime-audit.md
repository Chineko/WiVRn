# Helix bounded time-diverse recovery runtime audit

Date: 2026-10-29

Frozen implementation source base: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`

Runtime harness implementation before this audit: `79191e14e22fd56104368d158186d05ec1f51454`

## Success condition

A runtime is diagnostic only when desktop server/dashboard and installed Quest native libraries are built from the same current runtime commit while all non-tool/non-doc source remains equivalent to the frozen prototype source base.

The prototype earns a provisional pass only if the time-diverse replay path actually executes and no hard recovery/encoder failure signal appears. Promotion still requires comparison of incomplete-frame and IDR fallout with the established baseline.

## Audit A — local/final-artifact

- The harness requires one USB ADB device and a working rooted Quest shell before building/installing.
- The working tree must be clean.
- All non-`docs/`/`tools/` source must be identical to the frozen prototype source base.
- Desktop server and dashboard are built together from the repository `everything` preset and discovered from the resulting build tree rather than from a guessed path.
- The server binary must contain the current runtime commit short ID before the session can start.
- The debug Quest APK is rebuilt after deleting the previous debug APK output directory; exactly one generated APK is required.
- The installed APK is read back from the Quest and its native libraries must contain the same current runtime commit short ID.
- Only dashboard/server processes matching the new build-tree paths are stopped before launch.
- Quest logcat is cleared before launch.
- Runtime capture is bounded to 240 seconds by default and can be ended early with one Enter press.
- The dashboard process is covered by an exit/interrupt cleanup trap.
- The runtime server log is selected only from files updated after the test starts.
- Runtime identity is verified again from both server log and Quest logcat after the session.
- The reducer reports replay events, gap events, IDR requests/retargets, inconsistent-IDR warnings, IDR/encoder timeouts, Quest incomplete frames, and old-shard drops.

## Audit B — whole-system/evidence chain

- The question is whether the bounded one-frame-delayed replay path executes safely and improves the recovery path enough to justify further development.
- This test intentionally does not reopen AP/radio attribution. The initiating lower-path loss mechanism remains outside this prototype's scope.
- A run with zero `Helix time-diverse replay` events is nondiagnostic, not a success.
- A replaying run with `inconsistent IDR state`, IDR timeout, or encoder timeout is a hard failure.
- A replaying run without those hard failures is only a provisional pass until incomplete-frame and IDR fallout are compared with the prior baseline.
- Runtime identity is checked at artifact level and again from actual runtime logs to prevent testing stale desktop or Quest builds.
- The test does not add packet capture, tracefs, router instrumentation, or other observers that could materially perturb this first functional recovery validation.
- The workload remains user-representative VR use; no synthetic low-load test is substituted for the known failure class.

## Gate status

Runtime gate is open for one representative headset validation using `tools/helix-runtime-validate-bounded-recovery.sh` after pulling this audit commit. Any preflight/build/install/launch/log/reduction failure resets the Rule 42 gate before another runtime attempt.
