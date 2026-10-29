# Helix bounded recovery evidence salvage re-audit

Date: 2026-10-29

Frozen runtime implementation: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`

Completed test runtime head recorded by the run: `c114c2949ff40569ff1285fa02430da8a3893ae4`

Audited salvage helper implementation: `124bd2d003fc2dd6189e599ffbc0e24dfd1b29b3`

## Governing rules applied

This re-audit follows Rules 6, 8, 9, 10, 12, 13, 18, 19, 24, 27, 30, 31, 32, 34, 35, 37, 38, 40, 41, and 42 from `docs/HELIX_DEVELOPMENT_RULES.md`.

The prior runtime collection failed after the headset workload because the harness guessed the server-log directory instead of consuming the authoritative path printed by the dashboard. Under Rule 42 that failure invalidated the prior audit gate for the experiment/evidence chain.

## Exact branch/artifact identity

- Recovery branch: `helix-bounded-time-diverse-recovery`.
- Frozen runtime source implementation: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`.
- Tested runtime head: `c114c2949ff40569ff1285fa02430da8a3893ae4`.
- Git comparison proves the tested runtime is four commits ahead of the frozen implementation and all differences are confined to `docs/` and `tools/`; no executable runtime source differs.
- Salvage helper path: `tools/helix-recover-bounded-runtime.sh`.
- The helper requires its local file hash to match the blob stored at `HEAD` before touching evidence.

## Audit A — local/function/final-artifact

Inputs and identity:
- Requires the expected branch and the frozen source-base commit locally.
- Requires the helper on disk to be byte-identical to the helper committed at the checked-out `HEAD`.
- Requires the selected run directory plus non-empty `dashboard-stdout.txt`, `quest-logcat.txt`, and `metadata.txt`.
- Requires valid recorded `source_base`, 40-hex `runtime_head`, and numeric `capture_start_epoch`.
- Requires the recorded runtime commit locally and proves all non-`docs/`/`tools/` files are byte-equivalent to the frozen runtime source.

Dependencies and syntax assumptions:
- Explicitly checks every host command used by normal and fallback paths: `awk`, `cp`, `cut`, `date`, `find`, `git`, `grep`, `head`, `python3`, and `sort`.
- Uses Bash intentionally; the user invokes it from fish via `bash tools/...`.
- Python reducers are embedded in quoted heredocs and have no shell interpolation.

Log ownership and retrieval:
- The dashboard is the process that starts the matching server and its source prints the exact server log path as `Saving logs in "...server_logs_....txt"`.
- Salvage parses that authoritative path from the run-specific `dashboard-stdout.txt`; it does not guess a state directory or select by mtime.
- Requires the reported server path to be absolute and non-empty.
- Verifies the tested runtime short ID in both the selected server log and the run's Quest log before copying or modifying evidence metadata.
- Evidence files are only written after all provenance gates pass.

Reducer correctness:
- Replay execution is counted from `Helix time-diverse replay` server events.
- Gap events, IDR requests/retargets, inconsistent-IDR warnings, IDR timeouts, and encoder timeouts use the exact server log strings.
- Quest incomplete-frame and old-shard expressions match the exact client `shard_accumulator` log strings.
- Every `Helix time-diverse summary` line is parsed and aggregated across streams.
- `td_send_errors > 0` is a hard failure.
- Aggregate replay payload must obey `replay_bytes * 5 <= fresh_bytes`, matching the frozen 20% long-run byte-budget contract.
- Shutdown-summary aggregate `replayed` must equal the number of replay-event lines; a mismatch is nondiagnostic rather than silently accepted.
- Missing time-diverse shutdown summary after replay is nondiagnostic.

Bounds/cleanup/side effects:
- Salvage launches no dashboard, server, Quest application, packet capture, or network workload.
- It performs no device action and introduces no runtime observer effect.
- It copies the authoritative server log into the already-created run directory and appends only salvage provenance to metadata.
- It creates/overwrites only `result.txt` inside the specified run directory.

Audit A result: PASS for evidence salvage. No material local/final-artifact blocker remains.

## Audit B — whole-system/experiment

Decision question:
- Can the already-completed representative VR run establish that the bounded one-frame-delayed replay mechanism actually executed, remained inside its frozen traffic budget, and avoided hard recovery/encoder/send-state failures?

Success-condition boundary:
- This salvage can establish mechanism execution and bounded-safety signals.
- It cannot by itself establish that replay caused fewer perceptible stalls or that a specific replay repaired a specific lower-path gap.
- A provisional pass therefore remains provisional until event-level effectiveness is compared with the established baseline.

Observation boundaries:
- Server replay lines directly prove replay sends were attempted/completed without throwing for those logged events.
- Server shutdown counters directly report fresh/replay bytes, replayed frames, expiry, and send-error counts accumulated by the prototype.
- Gap events directly report receiver-reported missing-sequence episodes reaching the server; they do not prove the cause of those gaps.
- Quest incomplete-frame lines directly report accumulator frames abandoned incomplete; they do not alone identify whether the initiating cause was RF/AP/radio loss, sender behavior, or another lower-path mechanism.
- IDR lines directly report recovery-state decisions, not user-visible severity.

Competing failure classes retained:
- AP/air/Quest lower-path disappearance remains the established initiating-loss class but is not re-attributed by this experiment.
- Existing RTX, IDR, decoder freshness behavior, and the new delayed replay can coexist in one episode; global counts cannot uniquely attribute a perceptual outcome to one mechanism.
- Workload variability remains possible because this is representative VR use rather than deterministic injected loss.

Identity/provenance:
- The tested desktop/Quest runtime head was `c114c2949ff40569ff1285fa02430da8a3893ae4`.
- Git comparison against frozen implementation `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336` shows only documentation/tooling changes, so executable source is equivalent to the frozen prototype.
- The original runtime harness verified matching server/dashboard and installed Quest native-runtime IDs before arming the workload.
- Salvage verifies those runtime IDs again from the actual server and Quest logs.

Clocks/timestamps:
- The salvage verdict uses counts and shutdown aggregates, not cross-device timestamp subtraction, so host/Quest clock-domain alignment is not required for this first execution/safety decision.
- Event-level effectiveness analysis will require careful temporal correlation and must not infer causation from global counts.

Capture/telemetry integrity:
- No packet capture or trace observer was active for this functional test.
- Server evidence comes from the exact log file selected by the dashboard itself for the tested server process.
- Quest evidence comes from logcat collected after the bounded workload.
- Missing shutdown summary or replay-summary/event reconciliation failure makes the run nondiagnostic.

Observer/resource effects:
- Additional runtime overhead is the prototype itself plus normal logging; salvage adds no runtime load.
- Replay-byte budget is checked from measured counters rather than assumed from configuration.
- A nominally clean run with replay but no gap events is classified execution-only, not evidence of loss recovery.

Rules 24/31/32 next-step check:
- Reusing the completed run is higher value and lower cost than repeating a headset session solely because collection tooling failed.
- No new mechanism or tuning should be introduced until this preserved evidence is reduced.
- If preserved evidence is nondiagnostic, then and only then should another runtime run be considered after a fresh Rule 42 audit.

Audit B result: PASS for salvage of the completed run, with effectiveness explicitly narrowed as above.

## Runtime-validation status

The representative headset workload already occurred under the source-equivalent tested runtime. The previous collection failure was tooling-only and occurred after the workload. No new runtime/device validation is authorized by this checkpoint. The next action is evidence salvage of that preserved run only.

## Rule 40 status before salvage result

Direct evidence already established:
- the representative runtime reached `RUNTIME TEST ARMED` and completed the bounded workload window;
- the tested runtime commit is source-equivalent to the frozen prototype outside `docs/` and `tools/`;
- the earlier failure was post-workload server-log retrieval, not a reported prototype runtime failure.

Supported inference:
- the completed evidence may still be sufficient for a mechanism execution/safety decision if the dashboard-reported server log and Quest logcat remain intact and identities match.

Remaining ambiguity:
- whether time-diverse replay actually executed during the run;
- whether its shutdown counters were captured;
- whether the run contained gap events;
- whether any hard recovery/send failures occurred;
- whether replay materially improved incomplete-frame/IDR fallout.

Decision justified by evidence:
- salvage the preserved run before asking for any new headset workload.
- do not claim mechanism success or failure until the salvaged result is classified under Rule 40.

## Checkpoint

Current active slice: bounded time-diverse recovery prototype.

Frozen implementation: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`.

Actually validated so far:
- implementation source compiled and linked as `wivrn-server`;
- matching desktop/Quest runtime build/install/identity gate reached successfully;
- one representative headset workload completed;
- final evidence reduction has not yet completed.

Known failures:
- earlier malformed patch/build workflow failures are closed process failures;
- runtime harness prefix nounset failure is closed;
- post-workload guessed-server-log retrieval failure is closed in the salvage path but the preserved evidence still needs reduction.

Next highest-priority action:
- reduce the preserved completed runtime with the audited salvage helper; then perform the final Rule 40 evidence classification and checkpoint decision.

Deferred:
- event-level comparison against baseline;
- cross-frame coding matrix;
- further FEC/replay tuning;
- renewed AP/radio attribution.
