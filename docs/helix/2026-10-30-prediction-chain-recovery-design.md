# Helix prediction-chain recovery design checkpoint

Date: 2026-10-30
Branch: `helix-cross-frame-matrix-prototype`
Parent simulator commit: `7967082d2e8faa6b201a0ece95f5c3c75109a5e2`

## Decision question

Can the dominant whole-frame loss mode be contained without recreating the ~20% steady-state replay tax, while keeping the Quest receiver current+next-frame latency boundary unchanged?

## Direct evidence

Recorded Helix evidence:

- 10 mapped burst events
- 23-59 missing stream-local shard positions per event
- burst send spans approximately 10.3-23.4 ms
- existing gap-report age from earliest missing source to server receipt approximately 26.0-80.3 ms
- 36 incomplete receiver frames, 31 with zero shards (86.1%)

The deterministic simulator confirms:

- 1000 GF(256) reconstruction self-tests pass when enough independent equations are available
- 0/10 existing gap reports arrive early enough for full repair within the current+next receiver window
- low-rate matrix parity is therefore secondary for partial/edge loss, not the primary answer for zero-shard whole-frame loss

## NVENC source facts

Current WiVRn NVENC configuration already enables:

- CBR / ultra-low-latency encoding
- automatic non-reference P insertion (`enableNonRefP = 1`)
- infinite GOP
- periodic intra refresh

Current intra-refresh values are:

- `intraRefreshPeriod = 100`
- `intraRefreshCnt = 50`

Current encoded output is inspected after `nvEncLockBitstream`; if NVENC reports `NV_ENC_PIC_TYPE_NONREF_P`, WiVRn records that frame in `default_idr_handler::set_non_ref(frame_index)`. The IDR feedback path then avoids escalating a missing non-reference frame as a prediction-continuity failure.

Current `NV_ENC_PIC_PARAMS::inputTimeStamp` is always zero.

NVIDIA documents `NvEncInvalidateRefFrames` as the API for preventing future frames from using a client-reported corrupt/lost reference. The frame is identified by the unique `inputTimeStamp` supplied when it was encoded. NVIDIA also documents long-term references (LTR) as an error-concealment mechanism for frame losses.

## Simulator comparison

The simulator now includes conservative periodic intra-refresh cleanup bounds. These are design bounds, not runtime measurements.

At the observed approximately 11.1 ms/frame cadence:

| period/count | equivalent intra-area rate | average full-clean bound | worst full-clean bound |
| --- | ---: | ---: | ---: |
| 100/50 (current) | 1.0% | 1110.0 ms | 1665.0 ms |
| 30/5 | 3.3% | 222.0 ms | 388.5 ms |
| 20/4 | 5.0% | 155.4 ms | 266.4 ms |
| 15/3 | 6.7% | 116.5 ms | 199.8 ms |
| 10/2 | 10.0% | 77.7 ms | 133.2 ms |

The same model gives a first-order future-containment bound for reference invalidation of roughly 37.1-91.4 ms across the recorded events: observed report age plus one frame. This does **not** reconstruct already damaged frames and is not a runtime measurement. It only expresses when future encoding could stop depending on a reported-bad reference if an older usable short/long-term reference is available.

## Selected first compiled slice

Do not implement matrix transport yet.

Implement only the minimum NVENC prediction-chain plumbing needed to test the stronger zero-steady-bandwidth mechanism:

1. assign `frame_index` to `NV_ENC_PIC_PARAMS::inputTimeStamp` for every NVENC frame;
2. on failed feedback, ignore frames already known to be `NONREF_P`;
3. queue failed reference-frame timestamps in a small bounded invalidation queue;
4. consume that queue on the NVENC encode thread before the next encode submission;
5. call `NvEncInvalidateRefFrames` only there, avoiding concurrent session API calls from the feedback thread;
6. expose counters/logs for queued, applied, duplicate, expired/not-found, and API-error invalidations;
7. do not change the Quest protocol, receiver buffering, matrix transport, pacing, bitrate, or IDR state semantics in this slice;
8. do not enable LTR until capability handling and exact mark/use semantics are compiled and audited as a separate bounded step.

## Why LTR is deferred one slice

Reference invalidation itself requires only unique timestamps and the existing failed-frame feedback path. LTR adds codec-specific initialization and per-frame mark/use policy. Combining both in one patch would make it harder to attribute build/runtime failures and violate the smallest-useful-experiment rule.

The first slice therefore proves that failed reference frames can be identified and invalidated safely. A following slice can enable one or more LTR slots if the GPU capability query supports them.

## Concurrency and lifetime boundary

The NVENC encoder session is used synchronously on Linux. Feedback can arrive independently of the encode call. The first slice must not invoke `NvEncInvalidateRefFrames` directly from the feedback callback.

Use a bounded queue protected by a small mutex (or equivalent bounded synchronization). The encode thread drains the queue immediately before the next `NvEncEncodePicture`. This keeps all session mutation on the encode path and bounds queue ownership/lifetime.

Queue requirements:

- fixed maximum capacity
- deduplicate frame indices
- discard indices older than a bounded recent-frame horizon
- clear on encoder reset/reconfigure/destruction
- never block fresh video waiting for feedback

## Success condition for the first compiled slice

Before any headset test:

- exact branch/artifact verified
- source compiles for the current NVENC H.265 10-bit path
- no protocol change
- invalidation queue unit/static checks cover duplicate, overflow, stale, and reset behavior
- full Rule 42 Audit A and Audit B completed

Runtime success later requires direct evidence that:

- failed non-reference frames do not queue invalidation
- failed reference-bearing frames queue exactly once
- queued invalidations are applied before a subsequent encode
- no NVENC API errors, encoder timeouts, or IDR-state regressions occur
- existing replay prototype traffic is removed/disabled for this comparison

Recovery-effectiveness claims still require a real mapped loss event. Perceptual improvement remains a separate comparison claim.
