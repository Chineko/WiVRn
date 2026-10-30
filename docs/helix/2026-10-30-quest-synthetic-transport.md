# Helix Quest synthetic transport validation

Parent policy commit: `cc9e68c09d863ed32559116a0edea2e1caa5ffde`
Branch: `helix-quest-synthetic-transport`

## Decision question

Can the production WiVRn Quest transport/receiver path reproduce controlled packet-loss and frame-advance scenarios with predictable feedback and bounded state, without requiring a VR workload?

This layer validates the real Quest UDP stream socket, production packet serialization, `video_stream_data_shard` dispatch, `shard_accumulator` current/next semantics, the existing raw decoder path, and Quest-to-host feedback. It does not claim GPU reference-invalidation success, RF resilience under real gameplay, hardware-codec visual quality, or perceptual recovery.

## Promotion thresholds

A transport battery is promotable when:

- >= 95% of injected scenarios produce the expected Quest receiver/feedback outcome.
- >= 95% of deliberately unrecoverable scenarios produce the expected clean fallback/advance behavior.
- 0 crashes, deadlocks, receiver-state corruption, unbounded queues, or runaway packet generation.
- The original recorded Helix burst corpus is represented as a named regression subset and cannot be hidden by aggregate scoring.
- Harness mutation/sanity checks prove that deliberately broken expectations are rejected.

## Frozen source boundaries

Production receiver path already confirmed:

- `wivrn_session::poll()` drains the production UDP stream and TCP control sockets.
- `scenes::stream::operator()(video_stream_data_shard&&)` performs packet-sequence gap accounting, gap reports, bounded RTX decisions, then calls `shard_accumulator::push_shard()`.
- `shard_accumulator` owns only current/next frame state, drops old shards, advances on completed next frames/frame jumps, and sends normal `from_headset::feedback`.
- `decoder::make()` already supports `video_codec::raw` on Android.
- `raw_decoder` accepts arbitrary raw frame bytes and still exercises frame assembly, frame completion, Vulkan upload, and the normal feedback path without requiring valid H.264/HEVC/AV1 syntax.
- `wivrn-server` already owns the accepted `wivrn_connection`, which provides the production encrypted handshake, UDP stream socket, `send_stream()`, `send_control()`, and feedback polling.

## Architecture

Use the production WiVRn server/client control handshake and production UDP stream socket. Do not add a second test transport and do not duplicate handshake/encryption code.

### Host side

The first slice extends the existing `wivrn-server` with an explicit debug-only CLI mode, tentatively `--helix-synthetic-transport`.

When the flag is absent, server behavior is byte-for-byte/control-flow equivalent to the normal path.

When the flag is present:

1. Accept and complete the normal Quest handshake through `wivrn_connection`.
2. Do **not** start Monado/OpenXR or a configured VR application.
3. Start one bounded synthetic scenario thread using that exact `wivrn_connection`.
4. Send a small `video_stream_description` using `video_codec::raw`.
5. Send deterministic `to_headset::video_stream_data_shard` sequences with valid raw frame payload sizes and production serialization.
6. Inject loss by omitting selected shards/frames before transmission; do not use kernel packet filters for the first slice.
7. Poll and record production `from_headset::feedback`, `video_gap_report`, and `video_retransmission_request` packets.
8. Emit a machine-readable scenario/result summary and terminate after a hard run deadline.

The synthetic mode is explicitly debug-only and must never activate implicitly from configuration, packet contents, or normal pairing state.

### Quest side

No Quest source modification is required for the first slice.

1. Reuse the normal `wivrn_session` production stream receive path.
2. Reuse `stream_network.cpp` packet sequence/gap/RTX logic unchanged.
3. Reuse `shard_accumulator` unchanged.
4. Reuse the existing production `raw_decoder` path rather than adding a synthetic decoder seam.
5. Collect existing Helix diagnostics/logcat plus returned protocol feedback.

This is preferred over a no-op decoder because it exercises more production code with less test-only code.

## Raw synthetic frame format

Use modest fixed dimensions that produce enough UDP shards to reproduce the recorded burst sizes while keeping GPU/memory cost bounded. Initial candidate: 256x160 per eye, 8-bit raw YUV420 for streams 0/1.

A full color raw frame is `width * height * 3 / 2` bytes. The host sender splits that buffer using the production `video_stream_data_shard::max_payload_size` rules. First shard carries `view_info`; last shard carries `timing_info`.

Before implementation, verify that chosen dimensions and metadata cannot create an unbounded render/blit backlog. If the existing raw path would queue frames indefinitely under synthetic display timestamps, reduce frame count or add a bounded test-only presentation suppression seam rather than weakening receiver semantics.

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

Use the ten established events as named scenarios, preserving their measured missing counts, send spans, report delays, and stream indices. The synthetic sender cannot recreate the RF cause, but it can recreate the receiver-visible consequence: contiguous shard omission spanning the corresponding number of packet sequence positions/frames, followed by an exposing packet/frame.

The corpus result must be reported separately from randomized cases.

## Observation boundaries

Directly observable at this layer:

- host packets intentionally sent/omitted
- production packet sequence numbers
- Quest gap reports and RTX requests
- Quest complete/incomplete frame feedback
- old-shard/frame-jump diagnostics
- host feedback receipt and timing
- bounded process health / completion

Not directly observable/proven at this layer:

- NVENC `nvEncInvalidateRefFrames` runtime success
- real RF/AP loss mechanism
- H.264/HEVC/AV1 hardware decoder visual output quality
- perceptual stall duration under VR workload
- contention with VRChat asset traffic

## Safety/bounds

- fixed scenario packet caps
- fixed total run duration
- fixed per-scenario feedback deadline
- no open-ended wait for feedback
- no unbounded receive/result/render queue
- no automatic retries that can hide failure
- synthetic mode explicit via CLI debug flag
- normal server path unchanged when the flag is absent
- server terminates the synthetic session after result emission

## Implementation order

1. Verify raw-decoder/render queue boundedness for the planned synthetic frame count.
2. Add the explicit server CLI flag and synthetic-success branch at `headset_connected_success`.
3. Implement a small synthetic raw-frame sender/scenario runner using the existing `wivrn_connection`.
4. Add deterministic scenario ids, packet plans, feedback oracles, and machine-readable result output.
5. Build server + matching Quest APK from one exact commit.
6. Full Audit A and Audit B of the exact artifacts and harness.
7. Run one controlled Quest transport battery.
8. Score against 95%/95% thresholds before any real VR test.

## Evidence classification target

Direct evidence: packet send/omission plan, Quest diagnostics, returned feedback/gap/RTX packets, exact source/APK/server commit provenance.

Supported inference: production Quest transport/receiver state machine behaves correctly under controlled packet loss.

Remaining ambiguity: GPU invalidation, real RF behavior, hardware compressed-decoder visual quality, perceptual recovery.

Decision: only after this transport layer passes may the deferred-IDR policy advance to a real runtime/perceptual validation layer.
