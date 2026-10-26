# Helix 0.1 Recovery Telemetry Plan

## Purpose

This slice prepares the measurements needed to validate decoder recovery before adding MediaCodec recreation or moving on to transport changes.

It is intentionally stacked on `helix-decoder-recovery` and must not be promoted independently. If the parent decoder-recovery branch changes during CI, recreate or rebase this slice from the corrected parent before integration.

## Scope

Telemetry only. No protocol changes, no decoder recreation, no pacing, no retransmission, and no FEC.

The first implementation should stay inside the existing Android decoder recovery path unless measurement proves a shared telemetry abstraction is needed.

## Timing rule

Use receiver-local monotonic time for watchdog and recovery durations.

Do not compare absolute PC and headset clocks for these measurements. Cross-device clock synchronization is outside the scope of Helix 0.1.

Suggested clock:

`std::chrono::steady_clock`

## Required counters

Per decoder stream, track at minimum:

- complete frames submitted to MediaCodec
- decoded outputs observed from `AImageReader`
- decoder-output stalls detected
- recovery requests actually sent
- recovery requests suppressed by the anti-storm guard
- MediaCodec asynchronous errors
- MediaCodec input submission failures
- decoder input-buffer overflows
- output-buffer release failures
- image-output processing failures
- MediaCodec flush attempts
- successful MediaCodec flush/restarts
- failed MediaCodec flush/restarts
- successful recovery completions

Do not add a decoder recreation counter until recreation exists as its own validated slice.

## Required timing measurements

### Submit-to-output latency

For complete frames, record a local monotonic timestamp when the completed frame is handed into the decoder path.

When decoded output for that frame is observed, calculate:

`decoded_output_time - submitted_time`

Track at minimum:

- last latency
- maximum observed latency
- running total and sample count for an average

Avoid an unbounded per-frame history. A bounded map/ring keyed by frame index is sufficient.

### Recovery duration

When the first recovery request of an incident is actually sent, store:

`recovery_started_at = steady_clock::now()`

When decoded output resumes beyond the recovery-request frame, calculate:

`steady_clock::now() - recovery_started_at`

Record/log the recovery duration before clearing the incident state.

A suppressed duplicate request must not restart the recovery timer.

## Existing hook points

The current decoder-recovery branch already provides the necessary control-flow hooks:

### `helix_note_submitted`

Increment submitted-frame telemetry and record the frame's local submit timestamp.

This is also where outstanding decoded-frame distance is currently used to detect a stall.

### `helix_note_decoded`

Increment decoded-output telemetry.

If a matching submit timestamp exists, update submit-to-output latency statistics.

If recovery is pending and output has advanced beyond the recovery request, mark the incident recovered and record recovery duration.

### `helix_request_recovery`

Increment `recovery_requests_sent` only when feedback is actually emitted.

If the anti-storm guard rejects the request, increment `recovery_requests_suppressed` instead.

Start the recovery timer only for the first emitted request in a recovery incident.

### `helix_should_flush` / flush job

Increment flush attempts when escalation is selected.

Increment success/failure after the `AMediaCodec_flush()` + `AMediaCodec_start()` result is known.

### MediaCodec error paths

Increment the relevant error-class counter at the exact failure location rather than deriving error classes later from log text.

## Logging strategy

Avoid per-frame info-level logs during healthy streaming.

Use event-driven logs for:

- stall detected
- recovery request emitted
- recovery request suppressed only at debug/trace level
- flush escalation
- flush success/failure
- recovery completion, including duration

Emit one compact summary when the decoder is destroyed or the stream ends.

Suggested summary fields:

- stream index
- submitted frames
- decoded outputs
- stalls
- recovery requests sent/suppressed
- successful recoveries
- flush attempts/successes/failures
- average submit-to-output latency
- maximum submit-to-output latency

## Bounded state

Telemetry must not introduce an unbounded map of frame timestamps.

Use one of:

- a small fixed-size ring keyed by frame index, or
- a map/deque pruned as decoded output advances

The initial target should retain only enough history to cover the decoder's normal in-flight depth plus the recovery threshold.

## Validation plan

### Build gate

The telemetry slice must pass the same Android CI matrix as the decoder-recovery parent.

### Healthy-stream test

Confirm:

- submitted and decoded counters advance
- no false stall/recovery events occur
- submit-to-output latency is plausible and bounded
- telemetry does not produce high-volume logs

### Injected output-stall test

Confirm the event sequence is visible in telemetry:

`healthy -> stall detected -> IDR request -> output resumes`

and that recovery duration is recorded once.

### Persistent-stall test

Confirm:

`stall -> IDR request -> second recovery opportunity -> one MediaCodec flush -> fresh IDR request -> output resumes`

Verify the flush attempt is counted once for the incident.

### Failure-path tests

Where practical, exercise or instrument:

- input-buffer overflow
- `AMediaCodec_queueInputBuffer` failure
- async MediaCodec error
- output-buffer release failure

The goal is to prove each failure class increments its own counter and enters the common recovery path.

## Success criterion

After one device test session, logs must be sufficient to answer:

1. Did the decoder stop producing output?
2. How many frames were outstanding when the stall was detected?
3. Was an IDR recovery request actually sent or suppressed?
4. Was a MediaCodec flush attempted, and did flush/restart succeed?
5. Did decoded output resume?
6. How long did recovery take?
7. What was normal submit-to-output latency before and after recovery?

If those questions cannot be answered from one captured run, the telemetry slice is not complete.

## Deferred

Explicitly defer until later slices:

- protocol-level decoder failure reasons
- server-side telemetry transport/dashboard
- full MediaCodec recreation
- packet-loss/reorder statistics
- pacing and congestion telemetry
- RTX/FEC telemetry

The purpose of this slice is to make Helix 0.1 measurable, not to build the final observability system.
