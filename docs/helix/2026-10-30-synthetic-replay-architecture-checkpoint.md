# Helix synthetic replay architecture checkpoint

Date: 2026-10-30
Branch: `helix-cross-frame-matrix-prototype`
Parent design commit: `2263a40702501c756163b8d786d0959121816c4b`
Simulator commit: `eec9a16ede7ed4b220cb2287f8f119517f3a3821`

## Why this checkpoint exists

The deterministic replay simulator changed the recovery design before protocol/C++ implementation. This checkpoint records the evidence and prevents the branch from continuing with an invalid assumption.

## Simulator artifact

`tools/helix-matrix-sim.py`

The tool is intentionally independent of XR/Vulkan. It contains:

- the 10 recorded mapped burst events;
- the measured current+next receiver usefulness window model;
- the recorded incomplete-frame / zero-shard counts;
- deterministic GF(256) arithmetic and Gaussian elimination;
- a randomized exact-reconstruction self-test;
- human-readable and JSON output.

Local execution before commit passed 1,000 deterministic GF(256) reconstruction cases.

## Recorded corpus encoded in the simulator

Mapped missing-shard counts:

`23, 38, 42, 48, 29, 31, 59, 47, 33, 46`

Mapped send spans:

approximately `10.254-23.420 ms`

Gap-report delays:

approximately `13.628-64.543 ms`

Receiver outcome summary from the decisive capture:

- incomplete frames: 36
- zero-shard incomplete frames: 31
- zero-shard fraction: 86.1%

## Timing result

The receiver currently owns only the current and next frame. Using approximately 11.1 ms/frame gives a useful window of about 22.2 ms.

For server-triggered repair, the age of the earliest missing symbol when the server learns about a mapped burst is approximately:

`mapped burst send span + gap-report delay`

For all 10 recorded events this exceeds the current+next usefulness window.

Result:

- existing gap reports before current+next deadline: `0 / 10`
- existing gap-report-triggered full repair is therefore rejected as the primary mechanism for this corpus.

## Information-bound result

At roughly 21 shards/frame and 11.1 ms/frame, one stream carries about 1.89 source shards/ms.

Even in the best case, parity emitted only after the burst and before the earliest affected frame ages out supplies very little information:

- 4% parity: less than 1 useful repair symbol for every recorded event
- 8% parity: less than 2 useful repair symbols
- 20% parity: at most about 4.5 useful repair symbols

The recorded events lost 23-59 shards.

Therefore a low-rate matrix cannot reconstruct these full mapped bursts inside the current receiver window. This is an information/timing bound, not an implementation defect.

## Dominant failure shape

31 of 36 recorded incomplete frames received zero shards.

A fully erased encoded frame cannot be reconstructed from single-digit-percent redundancy on VR timescales unless enough independent information was transmitted outside the outage. Cross-frame coding cannot evade that information bound.

Therefore matrix coding remains useful for:

- partial-frame edge loss;
- small erasures;
- surviving equations sent outside the burst;
- reducing selective retransmission volume when the missing set is small and still useful.

It is NOT the primary solution for the dominant zero-shard/full-frame erasure shape.

## Source-confirmed codec leverage

NVENC already enables:

- `enableNonRefP = 1`;
- codec intra refresh when supported;
- `intraRefreshPeriod = 100`;
- `intraRefreshCnt = 50`.

After encode, WiVRn observes `NV_ENC_PIC_TYPE_NONREF_P` and marks that frame non-reference in the IDR handler. The IDR handler already treats loss of a known non-reference frame differently from loss of a prediction-bearing frame.

This means Helix can target prediction continuity rather than protecting every encoded frame equally.

## Revised architecture

The next prototype is now a two-part recovery design:

### Primary: prediction-chain hardening

Goal: make complete loss of ordinary frames cheap, and make loss of prediction-bearing state recover quickly.

Investigate, synthetically first:

- observed/reference-frame frequency under current NVENC settings;
- whether most P frames can safely remain non-reference;
- the recovery-time / bitrate tradeoff of a much shorter intra-refresh cycle;
- whether strongly protecting only prediction-bearing frames fits a low single-digit average overhead budget;
- whether IDR fallback remains bounded when continuity cannot be recovered cheaply.

Do not assume a particular intra-refresh setting before measuring encoded size and reference behavior.

### Secondary: bounded GF(256) matrix repair

Use matrix repair only where the simulator says information can arrive in time:

- small/partial erasures;
- current/next frames only;
- no added receiver frame queue;
- <=4% steady-state seed budget unless later evidence justifies otherwise;
- no repair traffic ahead of fresh video, control, or IDR;
- late/rank-deficient repair is abandoned rather than allowed to create queue pressure.

## Synthetic validation order

Before another headset session:

1. keep `tools/helix-matrix-sim.py` as the fixed corpus/oracle;
2. add reference/non-reference and recovery-chain parameters to the simulator;
3. sweep candidate protection schedules against all recorded events;
4. reject schedules that cannot materially improve the corpus under the latency budget;
5. only then implement the smallest C++ sender/receiver change that matches the selected schedule;
6. unit/offline test GF(256), bounds, and fallback;
7. build matching desktop + Quest artifacts;
8. complete Rule 42 Audit A and Audit B;
9. use synthetic Quest transport replay before full VR gameplay;
10. require a real mapped loss event only for the final real-world effectiveness claim.

## Rule 40 evidence classification

### Direct evidence

- the recorded corpus contains 10 mapped bursts with 23-59 missing shards;
- 31/36 recorded incomplete frames were zero-shard frames;
- source inspection confirms current+next receiver ownership;
- source inspection confirms NVENC non-reference P support is enabled and observed NONREF_P frames are reported to the IDR state machine;
- source inspection confirms NVENC intra refresh is already enabled with period 100 / count 50;
- local simulator execution passed 1,000 GF(256) reconstruction self-tests;
- the timing model places 0/10 existing gap reports before the current+next deadline.

### Supported inference

- full-frame matrix reconstruction at low steady overhead cannot be the dominant recovery mechanism under the current latency window;
- prediction-chain hardening is a higher-value next slice because complete non-reference-frame loss can be tolerated more cheaply than complete reference-state loss;
- matrix repair remains useful as a secondary mechanism for partial/small erasures.

### Remaining ambiguity

- actual reference/non-reference frame frequency and byte share under representative NVENC/VRChat workload has not yet been measured from a matching runtime;
- the bitrate/quality effect of shortening intra refresh has not yet been measured;
- no C++ matrix transport has been implemented on this branch;
- no synthetic Quest transport replay exists yet;
- no perceptual improvement claim is justified yet.

### Decision

Do not implement gap-report-triggered rateless full repair as the primary path.

Continue with deterministic simulation of prediction-chain hardening plus bounded matrix edge repair, then implement only the smallest schedule that survives that gate.
