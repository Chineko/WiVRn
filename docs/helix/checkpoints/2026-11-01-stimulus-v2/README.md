# Repaired stimulus v2 — repeatable local checkpoint

Tested native source: `f87cbf84acea3e52370a7c15d4ed63a2d870ce87`. Later documentation commits are not native build
identity. The runnable checkout is deliberately pinned to this exact source after
publishing this snapshot, preserving runner commit/hash gates.

The old bit-mask ladder, per-level reseeding and tile flipping were replaced with
shared deterministic noise and fixed geometry, using monotonic linear amplitude
blending. Exhaustive pixel tests, controlled CPU/GPU Main10 sweeps, stimulus build,
seven reducer tests, private server/runtime/APK builds and full Audit A/B passed.
No seed, schedule, bitrate or acceptance threshold changed. Old results/artifacts
remain frozen. See the source's monotonic-stimulus audit for the complete rationale.

| Five-minute run | Mean bytes L/R | Peak bytes L/R | Exact recovery | Traffic | Source/peak |
|---|---|---|---|---|---|
| 08 | 28845 / 28661 | 58492 / 67620 | PASS | PASS | PASS |
| Identical repeat | 28842 / 28678 | 60910 / 59485 | PASS | PASS | PASS |

Both canaries bound exact frame/packet sequence through DROP → actual RTX_SENT →
received shard → assembly → exact MediaCodec output → AImage. Both runs had zero
probe overflow and no pending media/image probes at teardown. Artifact/input seals
are identical; independent postrun hashes and frozen baseline hashes PASS.

Rule40 direct evidence: corrected mapping properties, controlled encoded curves,
and two complete calibrated exact-recovery runs. Supported inference: v2 is a
better-controlled and usable local traffic/decoder characterization workload.
Remaining ambiguity: future-run variability and precise causes of historical v1
outliers. No claim that this single repair uniquely caused every improvement.
Pixel cleanliness remains NOT_ESTABLISHED; no actual VRChat rendering-cost claim.

## Executed consolidated launcher

`/usr/bin/fish /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/run-stimulus-v2.fish`

This exact launcher executed the passing repeat. It creates a unique output dir,
checks sealed source/artifacts through the canonical runner, captures/reduces the
run and returns its status. Quest must be awake with Guardian cleared; no conflicting
stream or ADB mappings are allowed. The runner installs only if APK bytes differ,
uses LAN video/RTX, and closes its gate on any failure. Do not bypass a closed gate.

Source root: `/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn` (pinned `f87cbf84acea3e52370a7c15d4ed63a2d870ce87`).
Bundle: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-stimulus-v2`. Full paths and SHA-256 values are in artifact-seal.json.
Frozen original paths/hashes are in frozen-hashes.json.
Raw captures: `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-run-08-stimulus-v2` and
`/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-v2-repeat-20261101T191203Z`.

Next: use this exact checkpoint to run repeatable stress and collect failures.
Further tuning requires a concrete measured reason. A source change requires a
new exact build/seal and full audits. A failure requires full failure-class audits.
