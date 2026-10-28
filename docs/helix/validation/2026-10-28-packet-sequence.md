# Helix packet-sequence validation — 2026-10-28

## Checkpoint

Branch: `helix-retransmission`

Runtime candidate: `5fa0184c5cae9a96adda89e288fd69b264f8b6d3`

This checkpoint validated the corrected packet-sequence design before implementing retransmission requests or a resend cache.

## Design under test

- UDP video shards use a monotonic sequence per `stream_item_idx`.
- Exact UDP transport identity is `(stream_item_idx, packet_sequence)`.
- Reliable control/fallback video shards use `packet_sequence = 0` and are excluded from UDP discontinuity telemetry.
- Client telemetry is summary-only on the hot path.
- A forward discontinuity is recorded as a candidate until later sequence-state logic can distinguish permanent loss from a late arrival.

## Build and runtime gate

Both matching Quest and desktop/server builds completed successfully before the runtime test.

The Quest connected and streamed normally with the matching build. No serialization/deserialization failure was observed during the captured session.

## Packet-sequence results

Main video streams at shutdown:

- stream 0: `received=234829`, `forward_gap_candidates=139`, `late_or_duplicate=0`, `unsequenced_control_or_fallback=6`, `highest=234968`
- stream 1: `received=236492`, `forward_gap_candidates=142`, `late_or_duplicate=0`, `unsequenced_control_or_fallback=6`, `highest=236634`
- stream 2: unused in this run

For both main streams:

`received + forward_gap_candidates == highest`

No late or duplicate sequence observations occurred. In this run, the 281 forward-gap candidates therefore did not later arrive out of order and are strong evidence of real missing UDP shards rather than reorder artifacts.

Aggregate main-stream observation:

- sequenced positions: 471602
- received UDP shards: 471321
- missing sequence positions: 281
- observed missing-position rate: approximately 0.060%

This is low average loss, but it is frequent enough over a high packet-rate VR stream to justify selective recovery.

## Burst / decoder incident

The capture included a severe network-side burst near frame 4858:

- several frames reported no shard received
- frame 4858 was abandoned with `13 data shards, 17 missing`
- both decoder watchdogs then qualified a stall near frame 4863
- each stream requested one IDR
- decoder output resumed roughly 7.8–8.0 ms after the recovery request

Final decoder summaries:

- stream 1: `submitted=11422 decoded=11416 watchdog_candidates=4 deferred=3 stalls=1 recovery_sent=1 recovery_suppressed=2 recoveries=1 flush=0/0/0 latency_avg=4096us latency_max=14576us errors=0/0/0/0/0`
- stream 0: `submitted=11423 decoded=11416 watchdog_candidates=2 deferred=1 stalls=1 recovery_sent=1 recovery_suppressed=2 recoveries=1 flush=0/0/0 latency_avg=4245us latency_max=15277us errors=0/0/0/0/0`

The diagnostic summaries continued to show healthy ordinary MediaCodec submission latency. No decoder flush was required and no MediaCodec callback/input/output/image error was recorded.

## Interpretation

The packet-sequence foundation passed its runtime gate.

The corrected per-stream UDP sequence model did not produce false reorder activity in this session. It also exposed a measurable amount of real UDP loss.

The evidence now supports implementing selective retransmission rather than spending another validation cycle on sequence telemetry alone.

The 17-missing-shard burst is unlikely to be cheaply recoverable with RTX by itself, but the average loss rate indicates that isolated missing shards should occur often enough for deadline-aware RTX to have useful opportunities. FEC remains a later mechanism for burst loss if RTX evidence shows that retransmissions frequently miss the deadline or that loss clusters are too large.

## Decision

Promote the packet-sequence foundation as the RTX transport-observation checkpoint.

Do not run another packet-sequence-only headset session.

Next implementation slice:

1. maintain bounded exact missing-sequence / missing-shard state on the Quest
2. add a compact headset-to-server retransmission request keyed by exact shard identity
3. add a bounded server resend cache that owns payload memory safely
4. preserve the original packet sequence on retransmission
5. gate requests by receiver-local usefulness deadline / RTT before tuning thresholds
6. add request/hit/arrival/usefulness telemetry required to prove an end-to-end recovered frame

Do not add FEC or another reorder-window experiment in the same validation slice.
