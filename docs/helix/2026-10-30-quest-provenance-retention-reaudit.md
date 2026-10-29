# Helix Quest provenance-retention failure re-audit

Date: 2026-10-30
Branch: `helix-bounded-time-diverse-recovery`
Frozen recovery source base: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`
Failed runtime tooling/head: `2e74030b5f03d63a665e96f70890a1b1d5b77141`

## Failure classification

The runtime reached the bounded-duration workload and evidence-collection stage, then failed at the old v2 end-of-run assertion:

`Quest runtime log does not contain 2e74030b`

This is an evidence-provenance retention failure, not a newly observed recovery-path failure and not an OpenXR startup failure.

The failed v2 control flow could reach `RUNTIME TEST ARMED` only after all of the following had succeeded:

1. a fresh debug APK output directory was built;
2. `org.meumeu.wivrn.local` was installed;
3. the installed package path was resolved;
4. the installed `base.apk` was read back from the Quest;
5. native libraries inside that installed APK were scanned and at least one contained the current runtime commit prefix;
6. the package was force-stopped;
7. logcat was cleared;
8. the exact package was launched automatically with `adb shell monkey -p org.meumeu.wivrn.local 1`.

The client source logs `Starting WiVRn version <description> (<full git commit>)` at startup for non-tag builds. The old harness did not preserve that line when it was observable. It waited until after a workload of up to 240 seconds and then required the bounded Android logcat ring buffer still to retain the startup commit. Therefore absence of the startup line at final collection is not equivalent to a mismatched installed APK.

## Failure-class inspection

The provenance chain has two distinct questions that the old gate incorrectly combined:

- **Artifact identity before arm:** Is the Quest package actually the APK produced for the current runtime head?
- **Durable evidence identity:** Is there an artifact retained in the output bundle proving that the launched client announced that same runtime head?

The installed-APK readback already answers the first question before arm. The missing piece was a durable copy of the startup log line while USB/logcat access was still available.

WiVRn's version generation is safe across tooling-only HEAD changes: `wivrn-version` is an `ALL` custom target, regenerates `version.cpp`/`u_git_tag.cpp` from Git on each build invocation, and `wivrn-common-base` depends on it. A tools/docs-only commit therefore changes the generated Git identity when the native targets are rebuilt; the harness does not need a destructive full Android clean solely for version regeneration.

## Fix

`tools/helix-runtime-validate-bounded-recovery-v2.sh` now:

1. retains the existing clean APK output rebuild, install, installed-APK readback, and native-library identity scan;
2. force-stops and automatically launches the exact `.local` package as before;
3. while USB is still attached, polls logcat for `Starting WiVRn version` containing the **full** current Git commit;
4. writes that matching line to `quest-startup-provenance.txt` inside the run output directory;
5. refuses to print `RUNTIME TEST ARMED` unless that durable provenance artifact is non-empty;
6. at final collection validates the durable provenance artifact rather than assuming the startup line remains in the bounded end-of-run logcat buffer.

No recovery/client/server executable source was changed by this fix.

A separate `tools/helix-salvage-bounded-recovery.sh` reduces the already-completed failed run without another headset workload. It selects the newest completed output bundle whose `metadata.txt` names exactly the failed head `2e74030b5f03d63a665e96f70890a1b1d5b77141`, requires its server and Quest logs, verifies the server runtime id, then runs the same bounded-recovery reducer. Because the old run did not persist the pre-arm Quest startup line, salvage explicitly records Quest provenance as **not self-contained** and states the control-flow basis rather than upgrading that inference into direct evidence.

## Audit A — local/function/final-artifact

### Inputs and identity

- Branch is fixed to `helix-bounded-time-diverse-recovery`.
- Runtime recovery source is still frozen at `fa68cb3a...`; docs/tools changes are excluded from the source-drift comparison.
- Desktop server identity remains checked in the binary, in the newly-created server log before arm, and through `/proc/<pid>/exe`.
- Quest artifact identity remains checked against the installed `base.apk`, not merely the local APK file.
- New Quest runtime provenance uses the full Git commit and the client startup message, not an arbitrary substring from final logcat.

### Ownership/lifetime

- `quest-startup-provenance.txt` is created inside the per-run output directory before arm and remains independent of later logcat eviction.
- The exact package is force-stopped before launch.
- The launch occurs while USB is attached, so provenance is collected before the user is told to unplug.
- End-of-run collection no longer depends on retention of a startup-only log line.

### Bounds/error paths

- Startup-provenance polling is bounded to 120 x 0.1 s (~12 s).
- Failure to launch, failure to observe the exact full commit, missing/empty provenance, or loss of the provenance artifact prevents/invalidates the run.
- Existing 240 s workload and 120 s reconnect bounds remain unchanged.
- Existing cleanup trap remains responsible for dashboard teardown on abort.
- Failed output directories are preserved.

### Build/version assumptions

- `wivrn-version` is an always-run custom target and generates both version source files from current Git state.
- `wivrn-common-base` depends on `wivrn-version`.
- The Android client uses the common version object and logs `wivrn::git_commit` on non-tag builds.
- Therefore the current full commit is a valid expected startup identity after a successful current-head native build.

### Serialization/protocol/recovery behavior

- No packet format, FEC/replay behavior, queue, encoder, decoder, pacing, protocol, or runtime recovery state was modified.
- The change is validation tooling only.

### Salvage artifact

- Salvage never launches ADB, server, dashboard, Gradle, or the headset workload.
- It accepts only a completed bundle for the exact failed runtime head.
- It preserves the provenance limitation in the result.
- It does not turn the failed run into a self-contained provenance pass.

## Audit B — whole experiment/evidence chain

### Question and success condition

The current experiment still asks whether the bounded time-diverse recovery prototype can execute under the real workload, remain within its frozen byte budget, avoid hard recovery/encoder/send failures, and encounter decision-relevant gap events. Effectiveness still requires event-level/baseline comparison; execution alone is not a perceptual-success claim.

### Observation boundaries

- Desktop executable provenance is direct before arm.
- Installed Quest APK provenance is direct before arm via readback/native-library identity.
- Future Quest startup provenance is direct and durable via `quest-startup-provenance.txt`.
- The old failed run lacks that durable direct startup artifact; salvage therefore remains explicitly weaker.
- Final logcat remains useful for runtime telemetry but is no longer treated as an archival store for startup-only identity.

### Competing failure classes

The final end-of-run absence of a startup commit can arise from logcat eviction/retention and therefore cannot distinguish a mismatched APK from a correctly launched APK by itself. Moving the observation before arm removes that ambiguity instead of broadening the log buffer, extending retention, or weakening identity matching.

### Observer effects/resource pressure

The added pre-arm operation is a bounded logcat read while USB is already attached. It occurs before the measured workload and adds no network recovery traffic, queues, buffering, or runtime instrumentation during the workload.

### Nondiagnostic successful runs

A future run can still be nondiagnostic if no replay event occurs, if replay occurs without a shutdown summary, if summary counts do not reconcile, or if no gap event occurs. The reducer already classifies these separately. A provenance pass does not imply recovery effectiveness.

### Highest-value next action

Do not repeat the headset workload merely because the old final-logcat identity assertion failed. First salvage the already-completed run. Only if that evidence is nondiagnostic or establishes a reason for a new runtime should the repaired provenance gate be used.

## Rule 40 evidence classification

### Direct

- The failed terminal reached evidence collection and stopped specifically on the Quest-log commit assertion.
- The old harness performs installed-APK readback/native-library commit verification before arm.
- The old harness launches the exact `.local` package before arm.
- The client startup source logs the full Git commit for non-tag builds.
- The old harness checked that startup identity only in final collected logcat after the bounded runtime.
- WiVRn's CMake version target regenerates Git-derived version sources and is a dependency of the common version library.

### Supported inference

- The missing final startup line is consistent with bounded logcat retention/eviction and does not overturn the already-passed installed-APK identity check.
- Because no durable pre-arm startup line was saved in the failed run, its Quest provenance cannot be made fully self-contained after the fact.

### Remaining ambiguity

- Until the failed bundle is salvaged, the recovery result of that completed workload is unknown.
- The old retained Quest log may or may not still contain enough Helix telemetry for all client-side counts.

### Decision

Salvage the completed run with no headset rerun. Future runtime validation, if needed, must use the repaired pre-arm durable Quest provenance gate. No recovery-source change is justified by this provenance failure.
