# Run 01 — full failure-class audit before repair

Source `27e9166e568f248847def746467fc5e696dd3971`. The five-minute workload completed 26,933 requested stereo submissions in 300.008 seconds. No user-side runtime interaction was required after the Quest was connected.

## Rule 40

Direct evidence: both isolated canaries bind exact stream/frame/packet sequences through actual UDP RTX send, accepted receiver shard, completed assembly, exact MediaCodec output and matching AImage. Eye 0: frame 602, packet 14382. Eye 1: frame 903, packet 21543. Both probe summaries show overflow=0, pending_media=0, pending_image=0. Path summary: 1,285,943 packets sent, drops 212/205 by eye, zero failure/cancellation, peak 268 packets/364,579 bytes, maximum scheduler lateness 1,542 us. Both eye Main10 gates passed. Pixel cleanliness remains NOT_ESTABLISHED.

Direct evidence: the reducer rejected the experiment because stream 0 had two fault summaries. The early summary has injected=0; the actual streaming summary has injected=1 and exact_rtx_sent=1. Source inspection identifies `prober::check_nvenc()` directly constructing a temporary 8-bit stream-0 encoder to check capability. The base constructor enabled the HEVC10 fault observer on that unrelated temporary instance. This is an observer-scope defect, not a second runtime canary injection.

Direct evidence: actual encoder output remained at 26,999/27,000 frames, about 90 Hz, despite 26,933 app submissions and six modeled stalls. Maximum measured encoder gaps were 18,456/15,515 us, below the unchanged required 40 ms minimum. App sleeps do not establish producer stalls; source inspection confirms the native compositor can submit repeated layers. The model must inhibit production before present/encode, not relabel dropped UDP packets as producer stalls.

Direct evidence: encoded means were 32,382/32,363 bytes, versus measured calibration mean 29,731 bytes. The server logs show a 50 Mbps headset setting split to about 24.69 Mbps per eye. The experiment inherited this uncontrolled setting. The existing NVENC CBR setup has a two-frame VBV, with low-delay key-frame scale 1. The observed first calibration point allows an explicit bitrate input to target the same measured mean: 50,000,000 × 29,731 / 32,372.5 ≈ 45,920,765 bps. This changes a workload input, not the acceptance threshold; subsequent agreement must still be measured independently.

Supported inference: the exact canary chain succeeded in this run, while the aggregate reducer verdict was conservatively withheld by the extra capability-probe summary. The visual surrogate plus inherited bitrate did not reproduce the calibrated encoded mean. Compositor repetition explains why the scheduled application stalls failed to become production gaps.

Remaining ambiguity: no pixel-content oracle exists; later damaged frames are not proven clean. A single CBR calibration point does not guarantee the next encoded mean/peak. Actual production gap/IDR timing must be observed after the repair. The path-model priors remain approximations rather than packet-exact replay of every capture.

Decision: preserve this run and its original FAIL/NOT_ESTABLISHED result. Restrict fault instrumentation to actual H.265 10-bit encoders; add an explicit bounded pre-encode production schedule using the existing same-seed stall/IDR model; bind path and production to one monotonic epoch; control bitrate as a sealed workload input; keep every acceptance threshold unchanged. Rebuild/seal and repeat full audits before another device run.

## Full Audit A reset — FAIL for current experiment, repair required

Rechecked final inputs/generated plans, ownership, buffer/packet lifetimes, socket serialization, worker fork/init/close/error paths, client probe/metadata/epoch paths, command/dependency/build/manifest assumptions, cleanup, summary capture and the entire reducer. Queue bounds, copied payloads, send completion events, final artifact identity and captured summaries passed their checks. The three material defects are observer scope, insufficient production control and uncontrolled bitrate. A repaired production hook must run before image acquisition/present-slot state transitions, so suppressing a frame cannot leak a busy slot or strand an encoder wait. It must not block the encoder thread or pretend that a network omission is a producer stall. IDR resets must use the existing synchronized handler. Generated schedule input must be parsed/bounded and sealed before runtime.

## Full Audit B reset — FAIL for traffic fidelity, repair required

Rechecked the exact question, per-eye output oracle, source/artifact/runtime provenance, frame/clock domains, capture/reduction integrity, resource/observer effects and competing failure classes. The event-level canary chain is direct evidence; aggregate summary mismatch is a separate harness failure. Actual output summaries, rather than app scheduling intent, control the traffic verdict. Failure to meet size/cadence fidelity prevents calling this a calibrated VRChat-like workload. A successful process completion cannot override that gate. New bitrate and pre-encode production controls remain provisional until another full bounded run measures them. No thresholds may be changed in response to this result.

The prior runtime gate is invalidated. No second device attempt is authorized by this report alone.
