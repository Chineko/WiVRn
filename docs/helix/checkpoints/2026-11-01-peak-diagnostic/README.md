# HEVC10 repeatability checkpoint — 2026-11-01

Tested source: `34f7b98b372d42c1c8f4b6bc17ecd0c0784a609a`.
Saved source predecessor: `d0a684429ef0ab661c04876fc9b9603a9323bb2f`.
Frozen original source: `392bb662ed20c6866af0942d219359518a885193`.
Worktree: `/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn`.
The concurrently edited original checkout was preserved.

## Results

| Run | Recovery | Traffic calibration | Peak identity | Left/right maxima |
|---|---|---|---|---|
| 5 | PASS | PASS | PASS | 60310 / 64092 bytes |
| 6 | PASS | NOT_ESTABLISHED | PASS | 65994 / 78379 bytes |

Both runs completed five minutes with identical binaries, plans and thresholds. Both exact eye canaries reached MediaCodec output and matching AImage. Probe overflow and pending media/image were zero. Run 06 failed only the right-eye peak gate: 78,379 > 75,898.75 bytes. The peak is exact NVENC P-frame 24678, output timestamp 24678, QP 39, agreeing with sender accounting. Run 05 right-eye peak was P-frame 26200, 64,092 bytes.

## Full failure Audit A

PASS for diagnostic implementation integrity after reviewing the entire prepare/build/seal/LAN launch/capture/producer/encoder/FIFO/receiver/codec/image/reduction/cleanup path, all ownership/lifetimes/bounds/concurrency/errors and final artifacts again. Independent postrun hashes match. No packet truncation/padding or threshold changes occurred. Native peak identity and complete sender accounting agree, excluding sender-only size inflation for this observed outlier. Capture, graceful teardown, source provenance, exact canary chains and component/mutation checks passed. Earlier sleep/Guardian failures and logs are preserved; neither ran a stream.

## Full failure Audit B and Rule 40

BLOCKED for a repeatably calibrated workload; runtime gate CLOSED. Direct evidence: identical-artifact runs disagree on the frozen peak acceptance gate; the repeat outlier is real encoded P-frame output. Supported inference: observed mean/cadence agreement does not ensure tail-size stability, and accounting-only or IDR-only explanations cannot explain this repeat outlier. Remaining ambiguity: precise content/compositor/rate-control trigger, influence of head pose, and old 83,785-byte frame identity. Applied-invalidation count is context, not causal evidence. No contemporaneous invalidation at frame 24678 is established. The stimulus maps size classes to independent noise images; level transitions and compositor sampling are plausible contributors, not proven causes. NVENC CBR/two-frame VBV is not a strict per-picture size guarantee.

Decision: retain the recovery PASS and diagnostic success, preserve all failures, do not claim repeatable traffic calibration, and do not loosen thresholds or blindly reduce bitrate. The next useful experiment must correlate exact encoded frame with submitted stimulus level/compositor input before choosing a content or encoder intervention. No further runtime is authorized by this checkpoint. Pixel cleanliness remains NOT_ESTABLISHED; no pixel-content oracle or VRChat rendering-cost equivalence exists.

## Artifacts and SHA-256

server: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-peak-diagnostic/server/wivrn-server`
SHA-256: `eaa0a4c56aa6a67d4e5688c4c604950e947a6c8c8231c9a5a71bf442a9531d85`

apk: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-peak-diagnostic/client.apk`
SHA-256: `5d056347651a4402b8edd812ef0575a0a4cc81876be6196e70a3aa0a918f2bf3`

runtime_elf: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-peak-diagnostic/runtime/libopenxr_wivrn.so`
SHA-256: `3df8fd18f22eae33e4eedd4be6c06826e395d550e648bf2ee28d00ed360320f8`

manifest: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-peak-diagnostic/openxr_wivrn-dev.json`
SHA-256: `f6b7b05846a7f80e053e6c984604a7dd5f6cce2a79971f16ec647a1788d14595`

stimulus: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-peak-diagnostic/stimulus`
SHA-256: `96fc7d461d4d5dd2c952f31feaeb1c587e1a4db4d8d4b043deba9c56d36e8680`

## Frozen original artifacts: unchanged

`/home/chineko/helix-hevc10-decoder-recovery-v1-runtime/wivrn-server-hevc10-recovery-v1`
SHA-256: `98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d`

`/home/chineko/helix-hevc10-decoder-recovery-v1-runtime/helix-hevc10-recovery-392bb662ed20.apk`
SHA-256: `cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087`

`/home/chineko/helix-hevc10-decoder-recovery-v1-runtime/runtime-v1-metadata.txt`
SHA-256: `88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1`


## Git snapshot identity

This documentation/results commit follows the tested source above. Native artifacts remain built from exact commit 34f7b98b372d42c1c8f4b6bc17ecd0c0784a609a; this documentation successor was not rebuilt or device-tested. Do not bypass exact-commit or audit gates. Raw captures and binaries remain local.
