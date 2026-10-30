# Prediction invalidation policy handoff

Date: 2026-10-30
Branch: `helix-prediction-chain-defer-idr`
Parent compiled checkpoint: `133cea01b7d9d8884a902c1c901c119175d28ce5`

## Evidence boundary

The parent slice compiled successfully and established:

- unique NVENC `inputTimeStamp = frame_index`
- capability gating through `NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION`
- bounded invalidation queue (16 entries)
- stale horizon (64 frames)
- actual NVENC output `NONREF_P` classification before non-reference skip decisions
- reset/reconfigure queue clearing
- encoder-thread application of `nvEncInvalidateRefFrames`
- full-replay prototype disabled (`helix_td_enabled(false)`)
- shutdown telemetry for queued/applied/skipped/duplicate/overflow/stale/error/pending invalidations

The parent slice does **not** yet improve recovery behavior because failed reference feedback is still forwarded immediately to `default_idr_handler::on_feedback()`. In `running`, that changes the state to `need_idr`; the next `get_type()` therefore chooses an IDR before the queued invalidation is applied.

No headset runtime is justified for the parent slice as an effectiveness experiment.

## Next bounded slice: invalidation before IDR

Goal: allow a failed reference-bearing P frame to attempt NVENC reference invalidation before forcing an IDR, while retaining IDR as the bounded fallback.

### Required ordering

For a failed frame (`sent_to_decoder == false`):

1. If reference invalidation is unsupported, keep the existing IDR path unchanged.
2. If the frame is known `NONREF_P`, keep the existing non-reference behavior and do not invalidate it.
3. If the IDR handler is already waiting for feedback on an IDR, do not suppress IDR-state handling. A failed IDR remains an immediate IDR failure.
4. Otherwise queue the failed reference frame for invalidation and **defer only that failure's transition to `need_idr`**.
5. On the encoder thread, process queued invalidation **before the next frame type is selected**.
6. If `nvEncInvalidateRefFrames()` succeeds, remain in the current running state. Do not advance decoder acknowledgement from the failed frame.
7. If invalidation fails, is stale, overflows, or cannot be applied, request IDR immediately through an explicit handler API.
8. Existing stale-decoder protection remains active, so a stream that stops producing successful decoder feedback still falls back to IDR.

### State-machine constraint

Do not infer or mutate `default_idr_handler` internals from NVENC code. Add a narrow explicit handler API for this policy, e.g.:

- classification of whether a failed frame may be deferred for invalidation
- explicit `request_idr()` fallback after invalidation failure

The API must preserve the existing IDR-overlap retarget semantics.

### Concurrency constraint

No NVENC API calls from the feedback thread.

The feedback thread may only classify/queue bounded work. The encoder thread owns invalidation application and the decision to keep running or request IDR after the NVENC result is known.

Lock ordering must avoid nesting the IDR mutex and invalidation mutex. Classification should return a value while holding the IDR mutex, release it, then queue under the invalidation mutex.

### Telemetry required before runtime

Add counters/logs for:

- failure deferred for invalidation
- invalidation succeeded and IDR suppressed
- invalidation failed and IDR requested
- invalidation stale and IDR requested
- queue overflow and IDR requested
- failed IDR bypassed invalidation deferral
- unsupported-capability fallback to ordinary IDR

Shutdown accounting must reconcile deferred failures with one terminal outcome: suppressed-by-success or IDR-fallback (plus any explicitly documented teardown-pending case).

## Success condition for the next slice

The next slice is source/build successful only if:

- parent behavior remains unchanged when invalidation is unsupported
- failed IDRs retain immediate fallback behavior
- a failed reference P frame can be invalidated before frame-type selection
- successful invalidation prevents that one failure from immediately forcing IDR
- any invalidation failure/stale/overflow path deterministically requests IDR
- no old 20% replay traffic is re-enabled
- no Quest protocol change is introduced

A later runtime experiment may then ask whether successful invalidation reduces prediction-chain/IDR fallout. It must not claim to recover the already-lost frame itself.

## Rule 40 classification

### Direct evidence

- Parent source forwards failed feedback to the existing IDR handler after queueing invalidation.
- Existing IDR handler transitions a failed reference frame in `running` to `need_idr`.
- NVENC frame type is selected before the parent slice drains invalidations.
- NVIDIA documents `inputTimeStamp` as the unique identifier used by `NvEncInvalidateRefFrames`; successful invalidation affects future reference use, not the already-lost frame.

### Supported inference

A successful invalidation can plausibly reduce subsequent prediction corruption/IDR fallout if older usable references remain in the DPB.

### Remaining ambiguity

- Actual GPU/codec support is runtime-dependent.
- Current/default DPB depth may limit how useful invalidation is after success.
- Feedback delay still bounds how many frames may already have referenced the failed picture before invalidation.

### Decision

Implement the bounded policy handoff before any headset effectiveness run. Keep IDR as deterministic fallback and preserve the matrix simulator for partial-loss work.
