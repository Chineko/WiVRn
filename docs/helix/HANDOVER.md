# WiVRn / Helix handover — 2026-11-01

## Current state

Goal: unattended, repeatable VRChat-data-derived traffic and real Quest decoder
stress, avoiding repeated manual PC/headset switching. This is a visual complexity
surrogate, not actual VRChat CPU/avatar/rendering-cost equivalence.

**Repaired stimulus v2 passed two five-minute identical-artifact runs**, including
traffic calibration, exact both-eye HEVC10 recovery, peak/input identity and zero
probe overflow/pending probes. Pixel cleanliness remains NOT_ESTABLISHED.

Remote git@github.com:Chineko/WiVRn.git, branch helix-vrchat-hevc10-repeatable.
This documentation snapshot follows tested native commit `f87cbf84acea3e52370a7c15d4ed63a2d870ce87`.
Runnable local checkout `/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn` is deliberately left pinned to that tested
commit. Do not pull documentation successors into it and bypass the runner's exact
commit guard. Develop successors separately or rebuild/reseal/audit them explicitly.

Read docs/helix/checkpoints/2026-11-01-stimulus-v2/README.md, results, full audits,
artifact seal and frozen hashes. Those are the authoritative latest checkpoint.
The same summary is local at `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/stimulus-v2-final-checkpoint.md`.

## Run locally

Executed and validated launcher:
`/usr/bin/fish /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/run-stimulus-v2.fish`

Bundle `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/encoded-workload-stimulus-v2`. Source `/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn`.
Launcher creates a unique output, canonical runner checks identity/preflight,
installs if needed, launches, captures, reduces, cleans up and closes its gate on
failure. No dashboard or prefix script. Quest must be awake and Guardian cleared;
check shared-resource conflicts. ADB only install/launch/evidence, no forward/reverse.
Quest serial2G0YC5ZH8D0006, IP192.168.0.54; host192.168.0.44 on enp14s0.
Package org.meumeu.wivrn.local, activity org.meumeu.wivrn.MainActivity.
LAN URI wivrn://192.168.0.44: TCP-only wivrn+tcp disables the needed UDP mechanism.
Both eyes require nvenc/h265/10-bit and resolved Main10.

## Rules

Read AGENTS.md, CONTRIBUTING.md, docs/HELIX_DEVELOPMENT_RULES.md,
docs/HELIX_DEVELOPMENT_RULE_41.md and docs/HELIX_ROADMAP.md before changes.
Full Audit A (implementation/final artifact) and B (whole experiment) before runtime.
Any failure closes both gates: audit the entire failure class before repair/retry.
Rule40 separates direct evidence, supported inference, ambiguity and justified action.
No PRs, issues or comments. Fish commands, absolute paths, explicit build dirs/targets;
no Bash snippets, naked ninja, ls-t, ambiguous wildcards or grep-q/pipefail traps.
Exact commits establish identity, not branch labels. Keep token/manual work low.

Never loosen frozen thresholds after results, pad/truncate payloads to pass, or
call decoder submission recovery. Each eye must bind exact frame X/packet S:
DROP(X,S) → actual RTX_SENT(X,S) → received shard0(X,S) → assembly(X) → exact
MediaCodec output(X) → image(recovered=X,image>=X), zero overflow and one epoch.

## Implementation and history

Canonical runner tools/helix-vrchat-encoded.py; Vulkan stimulus in the neighboring
.cpp; new shared-noise interpolation in tools/helix-stimulus-pattern.h with exhaustive
C++ test. Model tools/helix-vrchat-workload-model.py. Shared bounded post-fork FIFO
server/helix_encoded_path.h; pre-encode stall/IDR/bitrate controller in
server/helix_production_schedule.h. Android metadata/probe ordering is fixed.
Exact peak↔stimulus correlation uses runtime-converted host-monotonic timestamps.

V1 bit-mask entropy was not monotonic: per-level random bits, reseeding and tile
parity produced discontinuities. V2 fixes input amplitude; encoded size remains
empirical, not mathematically monotonic. QP32 NVENC level15→16 jump31.6%→3.9%;
QP40 jump56.3%→7.2%, with a small residual level0→1 codec dip. CPU/GPU controlled
tests and original rejected all-intra/Rext probe are preserved in the checkpoint.

Seed20261031, torture300s,26933 stereo submissions, six producer stalls, eight path
events, six IDR requests,45921000bps unchanged. Reference mean29731,max60719 bytes;
mean±4%,peak0.75–1.25x (upper75898.75), cadence±30us, max gap40000–212500us,
scheduler lateness<=3000us. Do not modify these to fit results.

Earlier run06 had exact recovery but failed right-eye peak78379. Run07 input
correlation passed. All earlier results stay preserved; v2 does not rewrite them.
Original frozen baseline392bb662ed20c6866af0942d219359518a885193 and frozen
server/APK/metadata remain unchanged; full paths/hashes in frozen-hashes.json.
CI repair0ff716ad used Ruff0.16.0 and clang-format22.1.8; last checked CI for
4de54574 was fully green. Check current CI once when a concrete decision needs it.
Pinned tools live in `/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/ci-tools`. Host execution is needed for USB/ADB
and writable Gradle cache. Android uses JDK17,ANDROID_HOME=/opt/android-sdk,
removes conflicting ANDROID_SDK_ROOT, invokes wrapper through Java, not Bash.
Loader target openxr_wivrn, ELF libopenxr_wivrn.so, manifest openxr_wivrn-dev.json;
libmonado_wivrn.so is ancillary. Verify ELF/export/manifest and independent hashes.

Another tool/chat was editing /home/chineko/WiVRn. Preserve that checkout and its
unrelated README/scripts; do not run its unverified claimed-success helpers.

## Next action

Use the validated launcher for characterization. No immediate extra tuning or
hardware run is required to complete this slice. On any failure, retain evidence
and perform full failure audits. Pixel oracle, broader rendering fidelity and later
Helix roadmap mechanisms remain separate work.
