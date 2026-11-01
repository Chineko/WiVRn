# HEVC10 traffic peak — failure audit and diagnostic slice

This advances the measured-workload prerequisite for Helix decoder/retransmission
validation, not a new recovery mechanism. The saved baseline is
`d0a684429ef0ab661c04876fc9b9603a9323bb2f`; the last tested native implementation
was `dfaefc2f444ac6c9779a710d66623e2b453f5b20`. The original frozen baseline is
`392bb662ed20c6866af0942d219359518a885193`.

## Failure classification before repair

Run 02 is a traffic-calibration blocker, not evidence of failed canary recovery.
The right-eye maximum was 83,785 bytes versus the unchanged allowed maximum
75,898.75. All other measured calibration gates passed. Runtime and exact
two-eye MediaCodec recovery passed. Pixel cleanliness remains NOT_ESTABLISHED.

Rule 40 direct evidence: the retained run-02 result and pacing summaries agree;
the largest logged right-eye IDR is smaller than the pacing maximum. The logs
contain no frame identity for that maximum. Sender accounting counts the complete
encoded span before impairment and retransmission; the shared path does not
increase this statistic. NVENC uses CBR with a two-frame VBV, which is not a hard
per-picture byte cap. Frozen server/APK/metadata hashes were reverified unchanged.

Supported inference: global bitrate calibration corrected mean size, but does not
establish the peak distribution. Remaining ambiguity: exact outlier frame/type,
reference-invalidation association, encoder variability, and any sender accounting
disagreement. No cause or encoder/stimulus repair is established.

Decision: measure the exact peak before tuning. Retain one maximum per encoder
at NVENC bitstream lock, including submitted frame, returned presentation identity,
picture type, QP and cumulative applied invalidations. Independently retain sender
peak frame/bytes under the existing pacing-statistics lock. Emit summaries only
at normal teardown. Strict greater-than updates select the first tied maximum.
This uses constant space and adds no per-frame logging or new worker/queue.
The invalidation count is context, not evidence that invalidation caused a peak.

The reducer reports peak diagnostic integrity independently of recovery and
traffic calibration. Missing/duplicate/mismatched records cannot produce overall
PASS; they do not turn an otherwise proven recovery chain into decoder failure.
All existing traffic/canary/timing thresholds, content, bitrate and plans stay fixed.
Success for this diagnostic slice is reconciled exact peak identity and size on
both eyes; a traffic miss may still make the overall run NOT_ESTABLISHED.

## Isolation and audit status

Another tool/chat is editing `/home/chineko/WiVRn`. Its README rewrite, new test
scripts and success summary are preserved and are not evidence for this slice.
Work continues in an isolated managed worktree from the saved exact commit.
No runtime or source build may reuse the other checkout's mutable build tree.
The previous audit gate remains CLOSED. Full Audit A and B, exact source commit,
new isolated build provenance and final independent artifact checks are required
before a diagnostic device run. This document alone does not authorize runtime.

A sandbox-only ADB query could not access USB or its daemon socket. A host-side
query succeeded with the authorized Quest serial. This is an execution-environment
failure, not a headset/decoder failure; no stream was launched.
