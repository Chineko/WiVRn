# Peak diagnostic — full audit worksheet

Source: 34f7b98b372d42c1c8f4b6bc17ecd0c0784a609a.
Isolated root: /home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn.
Audit A: PASS. Audit B: PASS for one bounded diagnostic run of the sealed artifacts.

## Audit A — complete executable path

Reviewed prepare/build/seal/verify/run/reduce/cleanup together with unchanged
source paths and their previous complete audit at the saved checkpoint. Explicit
plans, bounded schedule parser, native source identity, configured build target,
manifest/ELF distinction, private dependency sources and named builds are required.
The other checkout and its mutable build outputs are excluded from execution.

Runner ownership: argument lists only; bounded subprocess waits; explicit LAN
route, WLAN and package/activity; APK comparison before installation; capture
before launch; direct owned server process and PID-start-time checked descendants;
actual application runtime maps; graceful decoder summaries; bounded cleanup;
postrun seal validation; durable result/evidence seal and invalidated gates on
failure. No dashboard, prefix script or ADB forwarding/reverse is used.

Shared impairment path: post-fork lazy worker; owned copied payload until synchronous
serialization completes; one mutex/FIFO for fresh and RTX traffic; bounded packets,
bytes and send timeout; explicit send failure/cancellation/lateness checks. Producer
controller: strict plan/bitrate bounds, shared host monotonic origin, pre-acquisition
skip, deferred synchronized IDR. Packet protocol and original recovery hooks unchanged.

Observers: exact shard/frame identity; assembly insertion before decoder queue;
metadata before asynchronous submission; epoch reset/flush invalidation; zero overflow
required. NVENC peak state has constant storage, one encode-thread writer and
teardown read after compositor encoder jthread destruction joins before encoder
members are destroyed. Sender peak uses the existing statistics mutex and first
tied maximum. No new allocation, per-frame logging, queue or thread. The locked
NVENC output timestamp is retained separately rather than assumed equal to input.
Independent sender/NVENC maxima must reconcile or diagnosis stays unestablished.

Reducer: exact canary chain remains separate from calibration and diagnostic integrity.
Missing, duplicate, nonnumeric or mismatched peak evidence cannot yield overall PASS.
Six reducer tests pass; FIFO copied-payload/drain and producer boundary/deferred-IDR
component tests pass. No new dependency/API version is introduced; bitstream fields
are present in the repo's actual NVENC header. Final binaries remain to be checked.

## Audit B — complete workload-to-conclusion experiment

Question: which exact frame/type accounts for each observed peak, and do encoder
and sender observations agree? The seed, visual input, path events, production
stalls, bitrate and all frozen acceptance thresholds are unchanged from run 02.
One bounded characterization run is proposed, not a prior calibrated PASS.

The two-eye oracle remains exact DROP(X,S) → actual RTX_SENT(X,S) → received
shard 0(X,S) → assembly(X) → MediaCodec output(X) → image(recovered=X,image>=X).
Aggregate counters and decoder submission cannot replace an absent link. Resolved
Main10 evidence is required on both eyes. Peak diagnostic failure is not decoder
failure. Cumulative invalidations and QP provide context, not causation.

Clock boundaries: host scheduler uses a common steady origin; frame IDs bind output
timestamps without host/Quest wall-clock subtraction. Capture completeness and
one decoder epoch are mandatory. No pixel-content oracle exists: pixel cleanliness
remains NOT_ESTABLISHED even if image availability and recovery pass.

Competing causes remain encoder rate control, content changes, reference handling,
sender accounting and incomplete teardown. A new run cannot retrospectively identify
the old outlier. One retained maximum cannot characterize a tail distribution or
prove exact VRChat rendering-cost equivalence. A repeated calibrated run is still
required before declaring a repeatable release.

Resource pressure remains bounded by the existing five-minute stimulus and queue
limits; diagnostic state is constant space with teardown-only logs. Shared Quest/GPU
use with another tool requires an explicit reservation before launch. Final sealed
builds, installed provenance, system dependencies and frozen baseline hashes must
pass before the gate can open. Any failure triggers a full re-audit.

## Build environment failure
Direct evidence: Gradle could not create its wrapper lock in the sandbox read-only cache. Server/runtime and stimulus compiled; APK compilation had not started. Classification: build-execution environment blocker, no device or decoder conclusion. Whole failure class: Gradle wrapper, daemon, dependency/cache and Android SDK writes need host access. Decision: retain logs, retry unchanged clean source with host access; both full audits remain pending and runtime CLOSED.

## Final checks after environment failure
Full executable path and experiment rechecked after the Gradle permission failure. Clean exact committed source, all native builds, APK CRC/native commit probes, independent Python/system SHA checks, x86-64 ELF negotiation export, exact manifest target and system dependencies PASS. Copied model/frame/path/production plans and retained calibration are byte-identical to run 02. Frozen original hashes PASS unchanged. Quest/LAN preflight and no ADB mappings PASS; user reserved Quest/GPU. Full Audit A and B PASS for one diagnostic run. All prior uncertainty and failure-reset conditions above remain binding.

## Full failure re-audit after pre-connection timeout
Direct evidence: run 03 activity launch succeeded; server stayed alive waiting; client OpenXR reached IDLE only; no stream/stimulus started; host power evidence reported Quest Asleep. Classification: launch/readiness blocker, not a network-loss or decoder result. Supported inference: sleep prevented session readiness; remaining ambiguity is proximity/runtime readiness and connection after wake. No authentication failure was observed. No retry or code tuning is justified solely by missing connection.
Audit A rechecked the entire launch/capture/timeout/cleanup path, plans, clean source, installed APK comparison, native build identity and bounded observers. Existing cleanup closed logs, stopped owned processes, preserved result/evidence and invalidated both gates. No source, plans, binaries or thresholds changed. Wake was requested once as a nonpersistent launch prerequisite; power now reports Awake.
Audit B rechecked the full original experiment, observation boundaries, competing sleep/proximity/pairing/network failures, host/device clocks, actual Main10/exact recovery/peak oracle requirements, resource reservation, capture/reduction provenance, bounds and nondecisive-run criteria. A sleep timeout cannot answer the traffic/decoder question. One awake characterization attempt is admissible; failure again closes both gates. Pixel cleanliness stays NOT_ESTABLISHED.
Full Audit A PASS and Audit B PASS after the readiness intervention, conditional on ordinary runner LAN/process preflight.

## Second launch failure — full re-audit
Run 04 am start -W timed out before connection or stimulus. Direct Android evidence: power Awake, keyguard not showing, GuardianDialogActivity is the resumed/focused activity. Classification: headset system-dialog readiness blocker. Supported inference: Guardian prevents the WiVRn launch from completing; no stream/decoder conclusion. Remaining ambiguity: successful foreground launch after user clears the dialog. No boundary settings are changed or bypassed.
Audit A reviewed the complete unchanged source/build/launch/capture/timeout/cleanup/reducer path again: owned server stopped, no stimulus started, logs/results retained, previous gate invalidated. Build/artifact tests remain historical PASS; runtime authorization is CLOSED pending readiness and fresh complete preflight/seal checks. Audit B reviewed the whole experiment, provenance, clocks, counters, observer effects and competing readiness/pairing/network/decoder classes: this run proves no traffic or recovery outcome. Manual clearing of the system dialog is the smallest necessary intervention. No further blind timeout retry is authorized.

## Final complete re-audit after user cleared Guardian
Readiness evidence: Quest Awake, Guardian no longer resumed, no conflicting WiVRn process. User reservation persists. Audit A re-evaluated the complete unchanged prepare/build/seal/launch/LAN/observer/peak/cleanup/reducer chain described above: clean exact source, independent hashes and unchanged plans PASS; previous builds/component tests remain applicable. Audit B re-evaluated the full unchanged workload, exact Main10/output oracle, diagnostic identity, clocks, capture integrity, bounds, observer costs and all remaining ambiguities above. No source or threshold changed. Both full audits PASS for one bounded diagnostic run; the runner must still enforce all LAN, APK and mapping preflights. Any failure resets the gate.

## Full Audit A/B for identical-artifact repeat
Run 05 completed with runtime/recovery, traffic calibration and reconciled peak diagnostics PASS. Complete path and experiment audited again as above: source/plan/artifact identity, ownership, bounds, concurrency, observers, abort/capture/cleanup, clocks, protocol and dependencies remain unchanged; independent postrun hashes and frozen original hashes PASS. Both exact canary chains and zero overflow/pending probes were retained. Full Audit A PASS; full Audit B PASS for one identical-artifact repeat, user reservation confirmed. No threshold, code, plan, bitrate or stimulus change. A single passing run does not establish stability or explain the old outlier; pixel cleanliness remains NOT_ESTABLISHED. Any repeat failure closes the gate.

## Run 06 failure reset
Full failure-class Audit A/B and Rule 40 analysis are in peak-diagnostic-final-checkpoint.md. Diagnostic implementation integrity PASS; repeatable calibration BLOCKED, runtime gate CLOSED. No repair or third runtime attempted.
