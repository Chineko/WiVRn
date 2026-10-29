# Helix bounded cross-frame matrix prototype

Date: 2026-10-30
Branch: `helix-cross-frame-matrix-prototype`
Parent checkpoint: `e1ef626c4e292de6fe9e33cf99992c27cc75e413`

## Why this branch exists

The one-frame delayed full-replay prototype proved that time-diverse recovery can execute safely, but the measured healthy-path cost was too high for the target workload:

- replay events: 11,763
- replay bytes: 264,402,859
- fresh bytes: 1,327,318,079
- replay ratio: 19.9201%
- send errors: 0
- encoder timeouts: 0
- IDR timeouts: 0

The user also observed materially more gameplay lag and slower avatar loading in dense VRChat worlds while the replay prototype was active. Treat that observation as a healthy-path regression signal, not as isolated proof of a specific network mechanism.

The next slice must preserve time diversity without paying a ~20% steady-state replay tax.

## Source-confirmed latency boundary

`client/decoder/shard_accumulator` owns only `current` and `next` frame sets. It accepts a shard only when its frame index is the current frame or the immediately following frame. Shards older than current are dropped. The matrix prototype therefore MUST NOT assume a multi-frame receiver wait or add an open-ended recovery buffer.

This is a hard design boundary for the first slice.

## Observed burst geometry

The decisive loss capture contains 10 mapped burst events. Missing positions per stream event were:

`23, 38, 42, 48, 29, 31, 59, 47, 33, 46`

The mapped send spans were approximately 10.3-23.4 ms and covered 2-3 encoded frames. The pacing summaries show about 21 shards/frame and about 11.1 ms average inter-frame spacing per stream.

## Feasibility result: fixed 5-8% parity alone is rejected

For arbitrary erasures, recovering N missing source shards requires at least N independent repair symbols.

At roughly 21 shards/frame and 11.1 ms/frame, one stream carries about 1,890 source shards/s. An 8% fixed repair stream supplies only about 151 repair shards/s, or about 1.7 repair shards/frame.

Even the smallest observed event lost 23 shards. Accumulating 23 independent repair symbols at 8% would require roughly 152 ms after the lost data; 59 symbols would require roughly 390 ms. That is far outside the current receiver's useful current+next-frame window.

Therefore the first implementation MUST NOT be a static low-rate Reed-Solomon/XOR matrix presented as sufficient for the measured 23-59-shard bursts. That would violate the measured latency and information bounds.

## Selected architecture: bounded rateless matrix repair

The matrix idea remains useful, but it changes form.

Use a hybrid design:

1. **Very small steady-state seed parity**
   - hard target: <= 4% fresh payload bytes
   - emitted with temporal separation from the source data
   - purpose: repair small losses immediately and provide surviving equations around burst edges
   - never allowed to queue ahead of fresh video or IDR/control traffic

2. **Burst-triggered rateless extension**
   - the existing `video_gap_report` already identifies `stream_index`, `first_missing_sequence`, `missing_count`, `exposing_sequence`, and `exposing_frame_idx`
   - the sender keeps a bounded cache of source shards already needed for RTX/gap mapping
   - on a gap report, the server may generate additional independent repair equations over only still-useful cached source shards
   - repair generation is bounded by frame age, receiver current/next acceptance, payload budget, and a maximum symbol count
   - if useful repair cannot complete before the bounded deadline, abandon it and use the existing IDR fallback

3. **No receiver latency expansion in slice 1**
   - retain current+next frame ownership
   - reconstructed shards are inserted into the existing `shard_set` path before decoder submission
   - no third-frame queue and no waiting for an arbitrary coding block

4. **No large adaptive controller in slice 1**
   - fixed seed percentage
   - fixed generation/window bound
   - fixed repair-symbol cap
   - explicit counters for generated, received, independent, reconstructed, expired, rank-deficient, and fallback events

## Why rateless / matrix-coded repair instead of whole-frame replay

Whole-frame replay spends bandwidth on data the receiver already has. A repair matrix spends burst traffic on independent information that can satisfy any missing symbol in the protected generation. This is especially useful when the server knows a contiguous sequence range vanished but does not want to resend unaffected payload.

The long-run objective is therefore not "recover a 59-shard outage with 8% parity." That is impossible under the current latency bound. The objective is:

- keep healthy-path overhead <= 4%;
- use rare, bounded burst repair only when loss is actually observed;
- reconstruct while the affected frame is still current/next;
- otherwise stop spending bandwidth and escalate cleanly to IDR.

## First implementation slice

The first compiled slice should answer only these questions:

1. Can a compact linear repair symbol be represented and serialized without disturbing normal video-shard semantics?
2. Can the Quest collect repair symbols for current/next frames and reconstruct missing payload exactly before the existing submission path advances?
3. Can the server generate bounded additional equations from the existing cache on a gap report without blocking fresh video?
4. Does the steady-state seed traffic stay <= 4% and does burst repair stop at the configured age/byte/symbol bounds?
5. Does unrecoverable/rank-deficient/late repair fall through to the existing IDR path without creating a new stall loop?

## Coding choice for the prototype

Use GF(256) linear combinations, not XOR-only parity.

Reason: the measured outage can remove several adjacent shards from the same frame/window. XOR-only equations frequently become rank-deficient when more than one protected source is missing. A small GF(256) coefficient row allows the receiver to solve multiple erasures as long as it receives enough independent equations.

For the prototype, coefficients should be deterministically generated from a compact equation seed so the packet carries a seed/generation description rather than a full coefficient vector.

Do not optimize SIMD/GF arithmetic before the mechanism is validated.

## Proposed packet metadata

A dedicated repair packet should identify at minimum:

- stream index
- generation/base sequence identifier
- protected source count
- equation seed/index
- payload length / symbol width information needed to reconstruct exact source payloads
- repair payload

Protocol/version handling must be explicit. Do not overload `video_stream_data_shard::retransmission` with parity bytes that the old receiver would interpret as encoded video.

## Bounds for slice 1

Initial hard bounds to preserve reversibility:

- NVENC only, matching the previous prototype scope
- current+next receiver window only
- seed parity <= 4% of fresh payload bytes
- no repair packet may delay IDR/control traffic
- no open-ended queue
- no repair generation for source frames already older than receiver usefulness
- burst extension has explicit symbol and byte caps
- all matrix state is cleared on stream reset / IDR discontinuity

Exact burst caps should be derived from compile-time/source-path inspection before runtime validation rather than tuned by repeated headset runs.

## Validation order

Before any headset runtime:

1. read relevant Helix rules
2. verify exact branch/artifact
3. static protocol/serialization audit
4. source ownership/lifetime/bounds audit
5. unit/offline encode-decode tests for exact reconstruction and rank failure
6. matching desktop + Quest build
7. full Rule 42 Audit A
8. full Rule 42 Audit B
9. only then device/runtime validation
10. Rule 40 evidence classification and checkpoint

## Success condition

The matrix slice is successful only if it demonstrates all of the following:

- exact reconstruction of missing current/next-frame shards when enough independent repair symbols arrive;
- bounded failure when rank/age/deadline is insufficient;
- <= 4% steady-state seed overhead;
- burst repair traffic only on observed loss;
- no new decoder wait or extra frame queue;
- no hard send/encoder/IDR-state failures;
- runtime evidence from at least one real mapped gap before claiming recovery effectiveness.

Perceptual improvement is a separate claim and requires event-level/baseline comparison.