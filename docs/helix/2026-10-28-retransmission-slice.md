# Helix 0.3 retransmission slice — 2026-10-28

## Why this slice exists

The 2 ms reorder-grace experiment produced 27 grace opportunities and 0 recovered frames. The primary Helix line therefore does not carry the experimental reorder implementation forward. The next high-impact target is selective loss recovery rather than nearby reorder-window tuning.

This slice implements the minimum protocol foundation required for deadline-aware retransmission while preserving bounded latency and freshness.

## Current transport facts

`to_headset::video_stream_data_shard` already carries:

- `stream_item_idx`
- `frame_idx`
- `shard_idx`
- optional first-shard `view_info`
- optional final-shard `timing_info`
- payload

The `(stream_item_idx, frame_idx, shard_idx)` tuple already identifies a particular encoded video shard within a session. However, Helix also needs a globally monotonic packet sequence number so the receive path can distinguish packet-order discontinuity from frame-local shard holes and can later measure retransmission behavior precisely across interleaved streams.

WiVRn serialization reflects aggregate fields, so adding an integral field to the shard changes the wire format automatically. Client and server must therefore be built from the same Helix revision for this work.

## Slice A — packet sequence foundation

Add `uint64_t packet_sequence` to `to_headset::video_stream_data_shard`.

Sender requirements:

- one monotonic counter shared across video streams 0/1/2
- assign exactly once immediately before first transmission of each video shard
- sequence values identify original packets; later retransmission of a cached shard must retain the original sequence value
- control-path video sends and stream-path video sends must use the same sequence namespace
- counter wrap is accepted as practically unreachable for this milestone; comparisons must eventually be wrap-safe before relying on arithmetic ordering

Receiver requirements for the first compile/runtime checkpoint:

- packet sequence must be visible before per-stream demultiplexing
- do not request retransmission yet
- add low-noise telemetry sufficient to prove that the client receives the field and to count forward discontinuities, duplicates/old packets, and reordered arrivals
- do not treat every sequence gap as packet loss: video streams share one sequence namespace, and transport/control routing must be accounted for before classifying a gap as loss

## Slice B — missing-shard request

Only after Slice A builds and runs normally:

- add a compact headset-to-server retransmission request carrying the exact shard identity needed by the server cache
- prefer explicit `(stream, frame, shard)` identity for the request; `packet_sequence` remains the transport observation identity
- request only shards known missing from an incomplete current frame
- suppress duplicate requests for the same shard
- never request a shard for a frame that has already been abandoned for freshness

## Slice C — bounded server retransmission cache

Server cache requirements:

- cache recently transmitted video shards for a short bounded lifetime
- retain payload ownership safely; never keep spans into encoder-owned transient buffers
- key by exact shard identity and preserve original `packet_sequence`
- hard cap cache by age and memory
- retransmitted packets must not enter an unbounded queue behind fresh video
- fresh video remains higher priority than stale retransmission work

## Slice D — deadline gate

The Quest decides whether a missing shard is still useful.

Use receiver-local monotonic time for the local deadline. Do not compare absolute host and headset clocks.

Request RTX only when:

`estimated RTT + safety margin < remaining local usefulness window`

Initial implementation should use existing WiVRn timing/RTT information if it is already available at the receive path. Do not create a second clock-sync model for RTX.

If the retransmission cannot plausibly arrive in time, abandon the frame and recover at the higher layer.

## Telemetry required before tuning

Client:

- original video packets observed
- packet-sequence discontinuities
- reordered/old/duplicate sequence observations
- incomplete frames with exact missing shard count
- RTX requests sent
- RTX requests suppressed by deadline
- RTX requests suppressed as duplicate/stale
- retransmitted shard arrivals
- frames completed because of RTX
- RTX arrivals too late to help

Server:

- RTX requests received
- cache hits/misses
- retransmitted bytes/shards
- request-to-resend delay
- stale-cache rejects

## Validation gates

### Packet-sequence checkpoint

1. matching Quest + desktop build succeeds
2. normal stream connects and runs
3. no serialization/deserialization failures
4. sequence telemetry is present
5. no decoder-recovery loop or connection instability

### RTX checkpoint

1. at least one real missing-shard event is observed
2. RTX request is sent only while useful
3. server cache hit causes retransmission of the exact original shard
4. Quest records whether the frame completed because of RTX
5. retransmission traffic does not create persistent sender backlog or materially increase latency

## Stop conditions

- Do not reintroduce a 1/2/3 ms reorder sweep.
- Do not add FEC in the same validation slice as first RTX.
- Do not add a large generic jitter buffer.
- Do not tune retransmission thresholds before proving at least one end-to-end recovery.
- If RTX rarely beats the deadline or measured loss is bursty, move to FEC rather than repeatedly widening the useful window.

## Immediate next action

Implement Slice A only, build both sides from the same commit, and run one short protocol-compatibility session before adding request/cache logic.
