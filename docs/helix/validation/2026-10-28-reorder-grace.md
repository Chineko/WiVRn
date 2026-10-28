# Helix 0.3 reorder-grace validation — 2026-10-28

## Scope

Validate whether a short, bounded receive-side reorder grace can rescue frames that upstream WiVRn would otherwise abandon as soon as the next frame becomes complete.

Test branch:

`helix-reorder-grace @ 972adf8439e98c00fd5ebfe2efa0c30b7222d1a8`

Mechanism under test:

- 2 ms receiver-local reorder grace
- non-blocking deadline integrated with the network poll timeout
- freshness override when traffic advances two frames ahead
- per-stream counters: `started`, `recovered`, `expired`, `superseded`

The experiment intentionally used one representative fixed grace value rather than a 1/2/3 ms sweep. Per the Helix development rules, additional threshold tuning is justified only if the first useful test demonstrates material recovery value.

## Runtime validation

The Quest client and desktop server were built from the matching `972adf84` revision. A long VRChat session included heavier world loading and normal interactive use.

Server-side pacing remained on the previously validated provisional 50 us fixed pacer.

Quest end-of-session reorder summaries:

- stream 0: `started=13 recovered=0 expired=8 superseded=5`
- stream 1: `started=14 recovered=0 expired=12 superseded=2`
- stream 2: `started=0 recovered=0 expired=0 superseded=0`

Aggregate main-stream result:

- grace opportunities started: 27
- frames recovered inside the 2 ms window: 0
- grace deadlines expired: 20
- freshness overrides / superseded: 7

Recovery rate for observed grace opportunities: `0 / 27`.

## Decoder and network context

Quest decoder summaries remained broadly healthy:

- stream 1: `submitted=165251 decoded=165219 watchdog_candidates=18 deferred=18 stalls=0 recovery_sent=0 recoveries=0 flush=0/0/0`
- stream 0: `submitted=165250 decoded=165219 watchdog_candidates=12 deferred=11 stalls=1 recovery_sent=1 recoveries=1 flush=0/0/0`
- no async/input/overflow/output/image MediaCodec errors were reported on either main stream

Network diagnostics showed real incomplete/missing-frame activity:

- stream 1: `incomplete=24 missing=21 jumps=25 skipped=323`
- stream 0: `incomplete=26 missing=75 jumps=31 skipped=331`

The matching server log also contained multiple paired IDR requests during the long session.

## Interpretation

The bounded reorder mechanism worked mechanically, but this test found no evidence that a 2 ms late-arrival window rescues a meaningful fraction of failures on this Quest 3 / Wi-Fi 6E setup.

Observed grace opportunities were dominated by packets that remained unavailable beyond the grace period or by traffic advancing far enough that freshness correctly overrode the old frame.

This moves the dominant problem boundary away from tiny packet reordering and toward actual packet/shard loss and frame discontinuity.

The test does **not** prove that no packet reordering exists. It does show that spending more headset-test cycles on nearby 1–3 ms grace tuning is not justified by the measured result.

## Decision

**Do not promote the experimental reorder-grace implementation into `helix` at this checkpoint.**

Keep `helix-reorder-grace` as an evidence branch and retain this validation record on the primary `helix` line.

Stop reorder-threshold tuning.

Next high-impact work:

1. packet identity / sequence information sufficient to identify missing video shards precisely
2. deadline-aware selective retransmission when the estimated round trip can still beat the local frame deadline
3. FEC after RTX evidence, per the roadmap, especially if measured loss is bursty or RTX often misses the useful deadline

No additional 1 ms / 2 ms / 3 ms micro-sweep is planned unless later telemetry provides a concrete reason to revisit the threshold.
