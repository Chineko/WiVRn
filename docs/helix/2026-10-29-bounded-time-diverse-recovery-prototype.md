# Helix bounded time-diverse recovery prototype

Date: 2026-10-29
Branch: `helix-bounded-time-diverse-recovery`
Base: `helix-time-diverse-recovery` at `20616b623698e0d761450ad0e906fb35daf17877`

## Goal

Provide a small, bounded recovery mechanism for the measured short correlated downstream erasure class without adding an open-ended jitter buffer, changing the Quest frame-retention policy, or reopening pacing/bitrate/router attribution work.

This prototype is not expected to recover every observed 10–23 ms event. It targets the subset that can be recovered with roughly one frame of temporal diversity while preserving Helix's freshness policy. Longer events remain an IDR fallback case.

## Evidence constraints

Existing decisive captures established host-visible UDP groups disappearing before Quest `wlan0`, with characteristic gaps spanning tens of packets and multiple frame generations. Reorder-window tuning did not recover frames; ordinary adjacent frame-local FEC is poorly matched to the correlated loss; bounded RTX remains useful only for small/deadline-viable loss.

The Quest `shard_accumulator` retains only `current` and `next` frames and abandons an incomplete current frame once the next frame completes. Therefore a causal code cannot provide >one-frame time separation without either changing freshness policy or adding decode delay. This first prototype deliberately does neither.

## Prototype mechanism

The first slice uses complete one-frame-delayed replay of selected reference-bearing NVENC frames, reusing the existing `video_stream_data_shard` packet and `retransmission` semantics. No new packet type is introduced.

Eligibility is intentionally strict:

1. NVENC only, matching the encoder configuration that produced the decisive evidence.
2. The encoded frame must be reference-bearing according to the existing NVENC/default-IDR non-reference classification.
3. The entire frame must fit a hard limit of 48 UDP shards. Partial-frame protection is forbidden because it cannot establish reconstruction of an arbitrary missing region.
4. A token budget limits long-run recovery payload to 20% of fresh video payload. A frame is replayed only when enough credit exists to replay the complete eligible frame.

When an eligible frame N is protected, all of its cached UDP shards are replayed once when frame N+1 begins. Replayed shards keep the original frame index, shard index, view/timing metadata and packet sequence, and set `retransmission=true` exactly like the existing selective RTX path.

The replay is sent before fresh N+1 shards. This is deliberate: the current Quest accumulator can then fill missing shards of frame N before frame N+1 becomes complete and causes N to be abandoned. No new client wait timer or larger frame window is introduced.

Recovery replay uses the existing 50 us shard spacing. The hard 48-shard limit therefore bounds replay pacing to approximately 2.4 ms per protected frame, before syscall/network overhead. If this bound proves too disruptive, the prototype fails rather than increasing it in the same slice.

## Why complete replay rather than small parity

The observed gaps can erase dozens of consecutive payload packets. Generic recovery of N arbitrary erased packets requires approximately N packets' worth of independent recovery information. A small static parity percentage cannot reconstruct a 40–60 packet erasure merely because parity is interleaved.

Complete replay of a bounded reference frame is intentionally inefficient but falsifiable: it proves or disproves whether approximately one-frame temporal separation can materially reduce corruption/recovery churn without redesigning the decoder or introducing a large coding subsystem. If it works, a later slice can replace duplication with a more efficient code. If it does not, we stop rather than tune duplicate spacing repeatedly.

## Success criteria fixed before implementation

A representative matching-build session must exercise at least one protected-frame replay and at least one characteristic loss event. Success requires all of the following:

1. At least one incomplete protected reference frame is completed using one-frame-delayed replay before the normal accumulator abandons it.
2. The recovered frame reaches the decoder without image corruption attributable to missing shards.
3. Protected-event recovery does not create an IDR storm or `inconsistent IDR state` sequence.
4. Long-run replay payload is at or below 20% of fresh video payload per stream.
5. Per-protected-frame replay pacing remains bounded by the 48-shard cap; no unbounded queue is added.
6. Existing healthy-path sender queue telemetry shows no persistent backlog and no material new major latency spike.

A run that exercises no protected recovery opportunity is compatibility evidence only, not a successful validation.

## Failure / stop criteria

Stop this mechanism rather than tuning it if any of the following occurs:

- replay causes persistent sender backlog or major latency spikes;
- protected-frame replay routinely arrives too late because N+1 completes first;
- useful protection requires raising the 48-shard cap or 20% long-run budget materially;
- characteristic losses commonly remain longer than the one-frame diversity window, leaving replay ineffective;
- decoder corruption persists even when the protected frame is reconstructed completely;
- recovery traffic materially increases the frequency or severity of the lower-path loss events.

No same-slice sweep of replay delay, cap, or budget is allowed after such a failure. A failed slice changes method.

## Recovery hierarchy

The intended hierarchy remains:

1. normal fresh delivery;
2. bounded selective RTX for small/deadline-viable loss;
3. this bounded one-frame time-diverse replay for eligible reference-bearing frames;
4. clean IDR resynchronization for anything still unrecoverable.

The IDR pipeline-overlap fix on the parent branch remains a correctness prerequisite and is not counted as the time-diverse recovery mechanism itself.

## Rule 40 status before code validation

### Direct evidence

- The measured failure is a correlated multi-packet/multi-frame erasure before Quest `wlan0`.
- The client retains only current + next frames and abandons an incomplete current frame when next completes.
- Existing packet semantics already support late retransmission shards for the current frame.
- Existing NVENC handling records non-reference P frames and already distinguishes loss that should not trigger IDR.

### Supported inference

A complete replay of a bounded reference-bearing frame, delayed by one frame but delivered before the next frame completes, can repair missing shards without increasing the client frame-retention window.

### Remaining ambiguity

The measured 10–23 ms burst envelope may be too long for one-frame diversity in many cases. The fraction of reference frames eligible under the 48-shard and 20% budget bounds is not yet measured on this branch.

### Decision justified by the evidence

Implement this as the minimum useful time-diverse experiment. Do not add Reed-Solomon, a larger jitter buffer, wider RTX thresholds, bitrate adaptation, or router/Quest micro-attribution in the same slice.

## Gate status

- Rules 41–42: inherited from parent branch.
- Prototype success/failure criteria: frozen by this document.
- Runtime implementation: not yet committed.
- Audit A: required after the exact implementation exists.
- Audit B: required after Audit A and before any runtime/headset command.
- Build validation: not yet performed.
- Runtime validation: not yet performed.
