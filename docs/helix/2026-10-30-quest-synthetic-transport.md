# Helix Quest synthetic transport validation

Parent policy commit: `cc9e68c09d863ed32559116a0edea2e1caa5ffde`
Branch: `helix-quest-synthetic-transport`

## Decision question

Can the production WiVRn Quest transport/receiver path reproduce controlled packet-loss and frame-advance scenarios with predictable feedback and bounded state, without requiring a VR workload?

This layer validates the real Quest UDP stream socket, production packet serialization, `video_stream_data_shard` dispatch, `shard_accumulator` current/next semantics, and Quest-to-host feedback. It does not claim GPU reference-invalidation success, RF resilience under real gameplay, decoder visual quality, or perceptual recovery.

## Promotion thresholds

A transport battery is promotable when:

- >= 95% of injected scenarios produce the expected Quest receiver/feedback outcome.
- >= 95% of deliberately unrecoverable scenarios produce the expected clean fallback/advance behavior.
- 0 crashes, deadlocks, receiver-state corruption, unbounded queues, or runaway packet generation.
- The original recorded Helix burst corpus is represented as a named regression subset and cannot be hidden by aggregate scoring.
- Harness mutation/sanity checks prove that deliberately broken expectations are rejected.

## Architecture

Use the production WiVRn control handshake and production UDP stream socket. Do not add a second test transport.

Host side:

1. Start a dedicated synthetic transport sender using WiVRn's existing socket and packet serialization code.
2. Complete the normal protocol handshake with the Quest client.
3. Send deterministic `to_headset::video_stream_data_shard` sequences with synthetic payloads and valid frame/shard metadata.
4. Inject loss by omitting selected shards/frames before transmission; do not rely on kernel packet filters for the first slice.
5. Record all `from_headset::feedback` received over the production path.
6. Emit a machine-readable scenario/result summary.

Quest side:

1. Reuse the normal `wivrn_session` production stream receive path.
2. Reuse `shard_accumulator` unchanged for packet acceptance, current/next frame advancement, old-shard dropping, and feedback generation.
3. Add only the minimum synthetic-test seam needed to avoid feeding arbitrary synthetic payload into a real hardware decoder. The seam must sit *after* `shard_accumulator` frame assembly so network and receiver semantics remain production-real.
4. Synthetic completion must still exercise `try_submit_frame`, frame-complete accounting, and `send_feedback`; it may substitute a no-op/test decoder sink for the codec-specific decode call.
5. Emit bounded telemetry with scenario id, stream, current/next frame state transitions, complete/incomplete frame counts, old shard drops, frame jumps, and feedback fields.

## Initial scenario families

- healthy sequential frames
- one missing shard in current frame
- missing contiguous shard run
- zero-shard/full-frame erasure
- next frame completes while current is incomplete
- frame jump of two
- frame jump greater than two
- late old-shard arrival after advance
- duplicate shard
- retransmission-marked shard
- two-stream interleave
- repeated burst trains derived from the recorded ten Helix events
- timing perturbations around the current/next boundary

## Recorded burst corpus

Use the ten established events as named scenarios, preserving their measured missing counts, send spans, report delays, and stream indices. The synthetic sender cannot recreate the RF cause, but it can recreate the receiver-visible consequence: contiguous shard omission spanning the corresponding number of packets/frames, followed by an exposing packet/frame.

The corpus result must be reported separately from randomized cases.

## Observation boundaries

Directly observable at this layer:

- host packets intentionally sent/omitted
- Quest packets accepted/dropped by `shard_accumulator`
- current/next frame transitions
- Quest feedback generated
- host feedback received
- transport timing and packet counts
- receiver diagnostic counters

Not directly observable/proven at this layer:

- NVENC `nvEncInvalidateRefFrames` runtime success
- real RF/AP loss mechanism
- hardware decoder visual output quality
- perceptual stall duration under VR workload
- contention with VRChat asset traffic

## Safety/bounds

- fixed scenario packet caps
- fixed per-run duration
- no open-ended wait for feedback
- no unbounded receive or result queue
- no automatic retries that can hide failure
- synthetic mode must be explicit and impossible to enter from normal streaming accidentally
- normal Quest streaming behavior must remain unchanged when synthetic mode is off

## Implementation order

1. Identify exact stream packet dispatch hook on Quest and exact server/session send/receive hook on host.
2. Implement a no-op synthetic decoder sink or equivalent seam after shard assembly.
3. Implement host sender using production packet serialization/sockets.
4. Add deterministic scenario ids and result telemetry.
5. Build host sender + Quest APK from one exact commit.
6. Full Audit A and Audit B.
7. One controlled Quest transport battery run.
8. Score against 95%/95% thresholds before any real VR test.

## Evidence classification target

Direct evidence: packet send/omission log, Quest receiver telemetry, returned feedback, exact source/APK/host commit provenance.

Supported inference: receiver/feedback state machine behaves correctly under controlled transport loss.

Remaining ambiguity: GPU invalidation, real RF behavior, hardware decoder visual quality, perceptual recovery.

Decision: only after this transport layer passes may the deferred-IDR policy advance to a real runtime/perceptual validation layer.
