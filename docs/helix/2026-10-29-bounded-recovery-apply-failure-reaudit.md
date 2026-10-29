# Helix bounded recovery — full re-audit after malformed apply artifact

Date: 2026-10-29
Branch: `helix-bounded-time-diverse-recovery`
Audited IDR-overlap base: `20616b623698e0d761450ad0e906fb35daf17877`

## Failure classification

The first local compile-gate attempt stopped at `git apply --check` with:

`error: corrupt patch at tools/helix-bounded-time-diverse-recovery.patch:15`

No prototype source file was modified and no configure, build, headset, or runtime step was reached.

The failure class is a generated-artifact correctness failure: the first unified-diff hunk declared seven old lines but contained only six before the next hunk header. This is not a source-design failure and not a local dependency failure.

Per Rule 42 the prior apply/build audit status is invalidated. The workflow has been redesigned to remove the patch parser from the executable path rather than repairing individual hunk counts.

## Replacement executable path

`tools/helix-apply-build-bounded-recovery.sh` now:

1. verifies it is running inside a Git checkout;
2. requires branch `helix-bounded-time-diverse-recovery`;
3. verifies ancestry from `20616b623698e0d761450ad0e906fb35daf17877`;
4. refuses to overlap local or staged changes in the three prototype source paths;
5. verifies the exact Git blob identity of all three source files;
6. uses Python exact-text transforms, each required to match exactly once;
7. runs `git diff --check`;
8. runs `clang-format --dry-run --Werror` when available;
9. uses the repository-defined `server` configure preset if `build-server/build.ninja` is absent;
10. builds only target `wivrn-server`;
11. stops on the first error because the wrapper uses `set -euo pipefail`.

There is no fuzzy patch application, offset retry, automatic source reset, runtime launch, or headset action.

## Audit A — local/function/final-artifact

### Source identity and transform bounds

Expected source blobs are fixed to:

- `server/encoder/idr_handler.cpp`: `5b72870fd6b97a13e20dfdd65dd1f74cbf20b2c7`
- `server/encoder/video_encoder.h`: `eceb0a5a4a76d08ce223d7a0d7e81708f90df3c5`
- `server/encoder/video_encoder.cpp`: `a7d3fa4acd26797ca87ab5f50252e67875ef8375`

Every transform anchor is required to occur exactly once. Any source drift or duplicate anchor aborts before the build gate.

### IDR-handler locking

`default_idr_handler::on_feedback()` already holds the handler mutex. The prototype needs a lock-safe public `is_non_ref_frame()` accessor for the sender path. To avoid recursive locking, the `running` feedback branch reads `non_ref_frames` directly while it already owns the mutex, while `is_non_ref_frame()` itself acquires the mutex for external callers.

NVENC calls `set_non_ref(frame_index)` after `nvEncLockBitstream()` identifies `NV_ENC_PIC_TYPE_NONREF_P` and before the encoded `data` object is returned to the shared sender. Therefore reference/non-reference classification is available before `SendData()` decides whether to schedule the frame.

### Recovery bounds

The prototype remains constrained to:

- NVENC only;
- non-control, reference-bearing frames only;
- complete frames of at most 48 shards;
- one-frame-delayed replay only;
- token credit of one byte per five fresh payload bytes;
- finite credit cap of two maximum protected frames;
- no partial-frame scheduling;
- no client retention-policy change;
- no protocol-field addition.

The existing `retransmission` flag and original packet sequence/shard identity are reused. Replay is attempted before fresh shards for the following frame. IDR/control traffic cancels a pending replay instead of being delayed by it.

At the existing 50 us shard spacing the maximum scheduled replay pacing interval for 48 shards is bounded to approximately 2.4 ms. Send errors do not create retry loops.

### Ownership/lifetime/concurrency

Replay payloads are copied from the existing bounded RTX cache while `video_encoder::mutex` is held by `SendData()`. The cache is not concurrently mutated through another `SendData()` on the same encoder. No new thread, callback, pointer lifetime, or unbounded queue is introduced.

The pending recovery state contains only a frame index. It is consumed/reset before replay. A frame mismatch, missing stream connection, control frame, or absent cache data expires the pending replay rather than extending its lifetime.

### Build assumptions

`CMakePresets.json` defines configure preset `server` with binary directory `${sourceDir}/build-server`. The server CMake target is `wivrn-server`. The helper configures only when `build-server/build.ninja` is absent, then builds that exact target.

The helper is Bash by design and is invoked explicitly through `bash`, so the user's interactive fish shell does not parse Bash syntax.

## Audit B — whole-system

### Question and success condition

This slice tests whether proactive one-frame-delayed redundancy for bounded NVENC reference frames can reduce visible corruption or major recovery stalls for the shorter/recoverable part of the measured correlated burst class without creating a healthy-path queue or latency problem.

It does not claim to recover every measured 10–23 ms / 40–60 packet outage. Bursts that erase both copies or exceed the current two-frame usefulness window remain the responsibility of clean drop/IDR convergence.

### Observation boundaries

A successful compile only validates source compatibility. Runtime success still requires a matching server/dashboard/Quest build and must demonstrate actual replay exercise plus recovery benefit without persistent queue growth, encoder instability, or a new latency spike.

The lower-path AP/RF/Quest-radio initiating loss remains separate from recovery behavior.

### Feedback-loop and latency risk

Replay traffic is capped by byte credit and frame-size limits. It is paced and finite. It runs only on selected frames, and control/IDR traffic preempts it. The mechanism creates no automatic retry loop and no receiver-side wait extension.

The principal prototype cost is that replay runs immediately before the next fresh frame, so a protected event may delay the next frame's send by up to the bounded replay pacing interval. Runtime validation must measure this rather than assuming it is harmless.

### Failure handling

Any transform, formatting, configure, or compile failure stops the workflow. Such a failure invalidates readiness for headset validation and requires classification plus another full applicable audit before a device run.

## Gate status after re-audit

- Original malformed patch path: rejected and no longer used by the active helper.
- Replacement source-transform workflow: source/final-artifact audited.
- Audit A: complete for the replacement apply/build path.
- Audit B: complete for the replacement compile gate and planned runtime question.
- Local source transform: not yet executed after this re-audit.
- Compile validation: not yet executed after this re-audit.
- Headset/runtime validation: blocked until compile succeeds.
- Measured improvement: not established.
