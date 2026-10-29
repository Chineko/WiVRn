# Helix IDR pipeline-overlap recovery — full Rule 40–42 audit

Date: 2026-10-29
Branch: `helix-time-diverse-recovery`
Parent recovery base: `helix-fec` at `6ade85338a6d971e48a6c2ab8016b66c57e87dfe`
Runtime implementation head audited before this documentation commit: `73aec23730ea905e49b0277be930b8c7c6983ae8`

## Scope and success condition

This slice fixes one recovery-state race exposed by the existing decisive WiVRn run. It does not change the lower-path loss mechanism itself.

Success condition:

> When `default_idr_handler` has reserved one frame for IDR recovery but an older frame was already admitted into the asynchronous encoder pipeline, the older in-flight frame becomes the single recovery IDR, already-admitted newer work remains predictive, and the handler waits for feedback for that one IDR without generating an `inconsistent IDR state` multi-IDR sequence.

Runtime validation must show that characteristic packet-loss events no longer produce `inconsistent IDR state` warnings or repeated IDR churn attributable to this pipeline-overlap race. The change is not considered successful merely because it compiles.

## Evidence that motivated this slice

The existing decisive run already established two separate facts:

1. real short-lag events contain multi-packet/multi-frame downstream loss before Quest `wlan0`;
2. around some of those recovery periods the server later logs repeated `IDR frame needed` messages plus `inconsistent IDR state` warnings even without a corresponding new Helix UDP gap report.

A first proposed change that armed IDR directly from large gap reports was rejected during Audit B before build/runtime because the existing incomplete-frame feedback already requests IDR in the same logged millisecond as the gap report. That proposal was fully reverted. This slice therefore targets convergence of the existing IDR recovery rather than requesting it earlier.

## Audit A — local/function/final-code audit

### Exact changed code

Relative to the rules-only checkpoint `aebd90f423c84b6edcaca873f609b87b0188778d`, runtime code changes only `server/encoder/idr_handler.cpp`: 12 additions and 3 deletions.

No protocol, packet, client, decoder, RTX, pacing, bitrate, FEC, compositor, or encoder-specific source file is changed.

### Source-confirmed pipeline overlap

The compositor calls `present_image()` before publishing `encode_request` to a separate encoder worker. The worker consumes `encode_request` by exchanging it back to `-1` before it calls the encoders' later `encode()` stage. Therefore the compositor can admit the next frame and run `default_idr_handler::should_skip()` while the prior frame is still in the encoder worker.

`default_idr_handler::should_skip()` reserves an IDR frame by storing `wait_idr_feedback{frame_id}`. NVENC, x264, and FFmpeg later call `default_idr_handler::get_type(frame_index)` from the encoder stage. Consequently an older, already-admitted frame can legitimately reach `get_type()` after a newer frame has been reserved as the recovery IDR.

The previous implementation handled every `wait_idr_feedback` mismatch by logging `inconsistent IDR state` and returning `frame_type::i`, forcing another IDR without updating the feedback identity.

### Corrected state transition

For `wait_idr_feedback{id}`:

- `frame_index == id`: return I; the reserved frame is the recovery IDR.
- `frame_index < id`: this is older work that was admitted before the reservation. Retarget the pending feedback identity to this earlier in-flight frame and return I.
- `frame_index > id`: this is already-admitted newer work following a retargeted older IDR. Return P without changing the pending feedback identity.

After `wait_idr_feedback` exists, `should_skip()` rejects newly presented frames until the IDR is acknowledged, so a `frame_index > id` call at `get_type()` can only represent work already admitted before the retarget. The change therefore does not open an unbounded or continuously advancing pipeline.

### Ownership, locking, and lifetime

All state transitions remain under the existing `default_idr_handler::mutex`. No new allocation, queue, thread, callback, pointer lifetime, or cross-object state is added. `wait_idr_feedback` is visited by non-const reference only while the variant and mutex are owned by the handler.

Feedback remains keyed to one `idr_id`; retargeting updates that identity atomically under the same mutex before the encoder emits the corresponding frame.

### Encoder compatibility

- NVENC uses `default_idr_handler` and `get_type()`; an I result forces `NV_ENC_PIC_FLAG_FORCEIDR`, while P leaves normal encoder selection. IDR output already uses the reliable control-preferred path.
- x264 uses the same handler; I maps to `X264_TYPE_IDR`, P to `X264_TYPE_P`.
- FFmpeg-based encoders use the same handler; I controls `push_frame(is_idr, ...)` and control preference.
- Vulkan Video does **not** use `default_idr_handler`; it owns a separate DPB state object and is unaffected.
- Raw encoding uses its own dummy handler and is unaffected.

No ABI, serialization, dependency, or build-system change is introduced.

### Error paths and bounds

Existing timeout behavior remains unchanged: if feedback for the selected IDR never converges, `should_skip()` retains its existing `idr_id + 100` timeout. Existing dropped-IDR feedback still returns the state to `need_idr`. Existing reset/reconfiguration paths remain unchanged.

The new information log is emitted only when an actual older in-flight frame causes an IDR retarget; it is not a per-frame hot-path log in normal running.

### Diff-size gate

The runtime diff is intentionally small: one source file, 15 changed lines. The earlier oversized formatting diff from a rejected prototype was treated as a Rule 18 stop condition and removed before this slice.

## Audit B — whole-system/recovery audit

### Actual question

The lower-path burst loss remains the established initiating failure. This slice asks a different question:

> Once normal WiVRn feedback decides an IDR is required after that loss, does asynchronous encoder overlap cause the recovery state machine to generate multiple inconsistent IDRs instead of converging on one recovery point?

The slice must not be interpreted as fixing the GE550/AP/RF/Quest-radio packet disappearance itself.

### Why this remains high-value

The measured burst class is too large for the existing bounded RTX path and ordinary adjacent frame-local FEC is poorly matched to the correlated blackout. The client also abandons stale incomplete frames once a newer complete frame is available, making delayed cross-frame packet repair incompatible with the current freshness policy without a larger latency redesign.

By contrast, the existing run already shows the IDR recovery path entering an internally inconsistent state after some loss events. Fixing recovery convergence changes only what happens after an unrecoverable burst and does not add network overhead during healthy streaming.

### Recovery/feedback-loop analysis

The change cannot request IDR more often than before:

- it replaces the previous behavior that forced I for every mismatch;
- an older overlap frame becomes the single pending IDR and changes the pending feedback identity to match it;
- an already-admitted newer frame becomes P rather than another forced I;
- newly presented frames remain skipped while feedback for the one IDR is pending.

Therefore the expected direction is fewer forced IDRs and less recovery burst traffic, not more.

The mechanism remains separate from RTX, congestion control, bitrate control, FEC, and decoder-health escalation. No queues are lengthened and no stale video is retained.

### Validation evidence required

A matching desktop/dashboard/server and Quest build from the same commit is required before runtime validation even though the packet protocol is unchanged.

For a representative session that reproduces at least one characteristic gap/loss event, inspect existing telemetry first. A successful recovery-state result requires:

1. no `inconsistent IDR state` warning for the pipeline-overlap pattern;
2. `IDR frame retargeted ...` may appear when overlap occurs, proving the corrected path was exercised;
3. no repeated `IDR frame needed` cluster attributable solely to the same recovery episode after the retarget;
4. no new encoder timeout, connection instability, persistent sender backlog, or decoder-recovery loop;
5. characteristic loss morphology remains separable from recovery behavior rather than being relabeled as a network fix.

If no retarget event is exercised, the run can establish ordinary compatibility but cannot validate the race fix itself.

### Observer effects

Only one bounded server log line is added on the exceptional retarget path. No new packet, client instrumentation, timer, capture, tracepoint, or storage writer is added. Observer effect is therefore materially smaller than the earlier driver-attribution tooling.

### Remaining ambiguity

Even if this slice eliminates repeated IDR churn, the initiating 10–23 ms downstream packet disappearance remains attributed only to the established AP/RF/Quest-lower-radio region. Improved recovery does not identify which lower component caused the loss.

If repeated IDR requests remain after this race is removed, they may reflect genuinely dropped recovery frames, decoder rejection, another feedback/state bug, or a distinct loss event. They must not automatically be blamed on this fixed overlap path.

## Rule 40 status before build/runtime validation

### Direct evidence

- The compositor and encoder run in separate stages; the worker clears the single pending request before finishing encode, permitting the next `present_image()` while the previous frame remains in encoder work.
- `should_skip()` can therefore reserve a newer IDR while an older admitted frame has not yet called `get_type()`.
- The previous `get_type()` mismatch branch forced I but did not retarget `idr_id`.
- Existing decisive logs contain `inconsistent IDR state` and repeated IDR requests during recovery periods.

### Supported inference

The source-confirmed pipeline ordering is sufficient to explain the specific `inconsistent IDR state` warning class and can cause more than one forced IDR during one recovery episode.

### Remaining ambiguity

The existing logs do not prove that every repeated IDR request is caused by this race, nor do they quantify how much of the user's perceived short lag comes from recovery churn versus the initiating lower-path outage.

### Decision justified by the evidence

Implement and validate the minimal state-machine correction before adding FEC, delayed parity, larger buffering, or new lower-path diagnostics. The slice is small, reversible, produces a direct exercise signal, and can reduce unnecessary recovery traffic without changing healthy-path latency.

## Gate status

- Rules 41–42: committed on this branch.
- Runtime implementation: committed.
- Audit A: complete at source/final-diff level; no material blocker found.
- Audit B: complete for the IDR pipeline-overlap recovery question; no material blocker found.
- Build validation: not yet performed.
- Matching Quest/dashboard/server runtime validation: not yet performed.
- Measured improvement: not yet established.
