# Helix bounded recovery runtime provenance failure re-audit

Date: 2026-10-29

Frozen recovery implementation: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`

Replacement runtime harness implementation before this checkpoint: `cc019c131860815dd672c5f1f08512913c0f6a31`

## Failure classification

The completed 240-second runtime attempt reached the headset workload but post-run evidence collection could not find an authoritative dashboard-created server log. The later salvage helper also failed because `dashboard-stdout.txt` contained no `Saving logs in ...` line.

Static source inspection shows that the dashboard attaches to an already-owned `io.github.wivrn.Server` D-Bus service instead of spawning its sibling server. The prior harness only stopped processes matching the freshly-built full paths. Therefore an installed or otherwise pre-existing `wivrn-server` could survive and be adopted by the dashboard. Because the harness did not prove `/proc/<pid>/exe` before arming, the server that actually handled the completed run is not proven to be the frozen prototype build.

This is an artifact/runtime-provenance failure. It invalidates the previous Rule 42 gate for that runtime attempt. The run is not usable to claim prototype success or failure.

## Audit A — local/function/final-artifact

Exact replacement artifact: `tools/helix-runtime-validate-bounded-recovery-v2.sh`.

Checks completed:

- the exact script content was syntax-checked with `bash -n` before commit;
- the committed artifact was fetched back from commit `cc019c131860815dd672c5f1f08512913c0f6a31` and compared structurally with the audited script;
- required host commands are explicitly gated, including `busctl`, `pgrep`, `pkill`, `readlink`, `realpath`, `seq`, `dirname`, and the prior build/install dependencies;
- branch identity, clean working tree, frozen source-base availability, and non-doc/non-tool source equivalence are checked before build/install;
- exactly one rooted USB ADB device is required before install;
- desktop server and dashboard are built together from the repository `everything` preset;
- exactly one executable server and dashboard are discovered;
- dashboard and server must be sibling runtime artifacts because dashboard source resolves its server as `applicationDirPath()/wivrn-server`;
- server binary must contain the runtime commit identifier;
- Quest APK is rebuilt, installed, read back from the device, and its native libraries must contain the same runtime identifier;
- all `wivrn-server` and `wivrn-dashboard` processes are stopped before launch;
- the `io.github.wivrn.Server` user D-Bus name must be unowned before launch;
- generated dashboard prefix is sourced with nounset relaxed only for that source operation;
- the harness does not arm until the dashboard reports a newly-created authoritative `server_logs_*.txt` path;
- exactly one `wivrn-server` process must exist after dashboard launch;
- `/proc/<server-pid>/exe` must resolve exactly to the verified freshly-built server binary;
- the authoritative new server log must contain the runtime identifier before `RUNTIME TEST ARMED`;
- Quest workload is bounded to 240 seconds by default;
- after wireless workload, the script explicitly waits up to 120 seconds for USB reconnection before Quest evidence retrieval;
- Quest logcat retrieval is a hard gate instead of best-effort;
- dashboard shutdown is performed before final server-log copy so shutdown summaries can be captured;
- reducer checks replay execution, gap events, IDR state, encoder timeouts, Quest incomplete frames/old shards, replay send errors, replay-byte budget, replay-event/summary reconciliation, and shutdown summary presence;
- missing or inconsistent evidence produces `NONDIAGNOSTIC`, not a pass;
- replay payload above the frozen 20% long-run byte budget is a failure.

No unbounded runtime queues, packet captures, tracefs observers, or new network instrumentation are added by the harness.

## Audit B — whole-system/experiment

Decision question:

> Does the bounded one-frame-delayed recovery path actually execute on the intended frozen implementation, stay inside its bounded traffic budget, avoid hard recovery/encoder failures, and coexist with the representative short-lag workload strongly enough to justify event-level effectiveness analysis?

Observation boundaries:

- server process executable identity proves which server binary ran;
- pre-arm server log identity proves that binary reached the normal dashboard-managed runtime path;
- installed Quest native-library identity plus runtime log identity proves matching client provenance;
- `Helix time-diverse replay` proves the new replay path executed, but does not by itself prove a perceptible stall was repaired;
- gap events prove the run included Helix gap reports, but do not establish that any individual replay repaired a particular gap;
- incomplete-frame and IDR counts describe fallout, but causal improvement requires comparison with baseline/event timing;
- replay-byte/fresh-byte summaries test the frozen bandwidth bound;
- `send_errors`, IDR inconsistency/timeouts, and encoder timeouts are hard safety failures for this slice.

Competing failure classes retained:

- lower-path AP/RF/Quest-radio loss remains outside this prototype;
- a gap may still be too long for the one-frame replay window;
- a replay may arrive after the client has advanced and therefore be logged as an old shard;
- perceived short lag can still include host-production or unrelated runtime effects not isolated by this functional test.

Clock/timestamp handling:

This first gate does not use cross-device timestamps to claim causation. Event-level effectiveness analysis will use existing server/Quest log timing only after provenance and mechanism execution pass.

Observer effects:

The harness adds no packet capture or trace observer during the workload. Runtime overhead is the prototype itself plus normal logging already required for validation.

Non-decisive-success protection:

- zero replay events -> `NONDIAGNOSTIC`;
- replay without shutdown summary -> `NONDIAGNOSTIC`;
- summary/event mismatch -> `NONDIAGNOSTIC`;
- replay with no gap event -> execution-only provisional pass;
- clean replay with gap events -> provisional pass only; effectiveness still requires event-level/baseline comparison.

Highest-value next action under Rules 24/31/32:

Run exactly one provenance-gated representative headset validation with v2. Do not return to AP/radio attribution, pacing sweeps, bitrate tuning, or cross-frame coding until this bounded mechanism has a trustworthy execution/safety result.

## Rule 40 classification of the failed completed run

### Direct evidence

- the prior runtime reached `RUNTIME TEST ARMED` and completed the 240-second workload;
- post-run collection reported `no dashboard server log updated during the runtime test`;
- the salvage helper then found no authoritative `Saving logs in ...` line in dashboard stdout;
- dashboard source can attach to an existing `io.github.wivrn.Server` service without launching its own server.

### Supported inference

A pre-existing WiVRn server is a plausible explanation for why the dashboard did not create a new server log while the session still ran.

### Remaining ambiguity

Without an authoritative new server log or `/proc/<pid>/exe` captured during that completed run, the exact server binary that handled it cannot be reconstructed reliably after the fact.

### Decision justified by the evidence

Discard that run for prototype validation. Do not salvage or classify the recovery mechanism from it. Require runtime provenance before arming the next workload.

## Checkpoint

- current feature implementation remains frozen at `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`;
- prior completed runtime evidence is invalid for mechanism conclusions because server provenance is unproven;
- replacement harness is `tools/helix-runtime-validate-bounded-recovery-v2.sh` at implementation commit `cc019c131860815dd672c5f1f08512913c0f6a31`;
- exact harness blob at that commit is `0a75c2d23d5284a1bfc1b967b0eafabe963be26c`;
- no new runtime validation has occurred after this re-audit;
- next action is one provenance-gated runtime attempt only after this checkpoint is committed and branch head re-verified.
