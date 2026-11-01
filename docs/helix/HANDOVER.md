# WiVRn / Helix handover — 2026-11-01

## Objective

Build a repeatable, automated, data-derived VRChat-like **traffic and decoder stress workload**, so the user does not have to repeatedly switch between PC and Quest or manually play VRChat. Drive real two-eye NVENC H.265 Main10 encoding, LAN transport, packet impairments and actual Quest MediaCodec output. This is a graphics complexity surrogate, not equivalent VRChat CPU/avatar/rendering cost.

The automation exists and completes five-minute runs. Exact HEVC10 canary recovery works. **Repeatable traffic calibration is still NOT_ESTABLISHED** because encoded peak sizes vary between runs. The next task is diagnosis, not another blind bitrate/threshold adjustment.

User preference: keep token use and manual interaction low; perform local work yourself. Do not give unexecuted commands as a ready solution. Preserve checkpoints before budget exhaustion.

## Repository and source identity

- Remote: `git@github.com:Chineko/WiVRn.git`
- Feature branch: `helix-vrchat-hevc10-repeatable`; default branch unchanged.
- Latest pushed commit: `0ff716ad2a7c7a03d4f07868468e0514568ecffc` — CI lint/format repair.
- Results snapshot: `5217eae3626497efad3d50a5a947c0153ae557b0`.
- **Actual tested native source:** `34f7b98b372d42c1c8f4b6bc17ecd0c0784a609a` — exact peak-frame instrumentation.
- Earlier saved checkpoint: `d0a684429ef0ab661c04876fc9b9603a9323bb2f`.
- Earlier tested implementation: `dfaefc2f444ac6c9779a710d66623e2b453f5b20`.
- Original frozen baseline: `392bb662ed20c6866af0942d219359518a885193`.

Current isolated worktree, clean at latest pushed commit:
`/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn`

**Another tool/chat was editing `/home/chineko/WiVRn`.** User confirmed concurrent work. Preserve its rewritten README, untracked HEVC10 guides/scripts and claimed success summary; do not stage, overwrite, reset, trust, or run them as part of this experiment. That checkout was still at d0a68442 when last checked. Do not reuse its mutable build tree. Coordinate shared Quest/GPU use before another run; previous reservations covered only the completed runs.

Later commits are not the source of the existing native artifacts. Runner enforces exact source commit and clean tree; do not bypass those checks. Rebuild/reseal a successor, or deliberately use an isolated exact tested checkout for unchanged artifacts.

## Required process

Read `AGENTS.md`, `CONTRIBUTING.md`, `docs/HELIX_DEVELOPMENT_RULES.md`, `docs/HELIX_DEVELOPMENT_RULE_41.md`, and `docs/HELIX_ROADMAP.md` before changes. Follow full Audit A (implementation/final artifact) and Audit B (whole experiment) before runtime. Any failure closes both gates; fully audit the failure class before repair/retry. Rule 40 requires direct evidence, supported inference, remaining ambiguity and justified decision. **Runtime gate is currently CLOSED following run 06 calibration failure.**

No PRs, issues or comments. No branch name as source identity. Fish-compatible commands only; absolute source/build/artifact paths; no Bash scripts/snippets, cwd-dependent commands, naked ninja, ambiguous wildcards, `ls -t`, or `grep -q`/pipefail traps. Do not spawn agents unless explicitly authorized. No frozen threshold changes after results. No aggregate-counter recovery shortcut. `sent_to_decoder` is not recovery. Pixel cleanliness remains NOT_ESTABLISHED without a real pixel-content oracle.

## What is implemented

- `tools/helix-vrchat-encoded.py`: canonical prepare/build/seal/run/reduce workflow; explicit paths, checks, bounded processes, APK identity/install, direct server and Quest launch, capture, cleanup, reduction and failure-gate invalidation.
- `tools/helix-vrchat-encoded-stimulus.cpp`: deterministic Vulkan/OpenXR stereo input, 32 independent noise/complexity images selected from modeled size levels.
- `tools/helix-vrchat-workload-model.py`: collected-data-derived frame/path model.
- `server/helix_encoded_path.h`: post-fork, copied-payload shared FIFO for fresh video/RTX; 4096-packet/8 MiB limits; actual send evidence; bounded shutdown/send timing.
- `server/helix_production_schedule.h`: real pre-encode stalls, scheduled IDRs and explicit calibrated bitrate.
- Android observer ordering fixes: register assembly probe before decoder queue; metadata before async MediaCodec submission; epoch/flush/overflow guards.
- Peak probe: retain one NVENC maximum with submitted frame, returned timestamp, picture type, QP and cumulative invalidations; independently retain sender max frame/bytes. Teardown-only logs; constant storage.
- Tests: six reducer/mutation tests plus C++ FIFO/lifetime and production-boundary/deferred-IDR tests.

## Exact runtime environment and oracle

CachyOS Linux, RTX 3090. Fish is the user's interactive shell.
Quest serial `2G0YC5ZH8D0006`, Quest LAN `192.168.0.54`, host LAN `192.168.0.44` via `enp14s0`.
Package `org.meumeu.wivrn.local`, activity `org.meumeu.wivrn.MainActivity`.
ADB only for install/launch/evidence; no forward/reverse. Direct server; no dashboard/prefix assumption.
Both eyes must resolve `encoder=nvenc`, `codec=h265`, `bit-depth=10`, Main10.

Initial request specified `wivrn+tcp://192.168.0.44`. Investigation established TCP-only bypasses the baseline UDP drop/cache/RTX mechanism. The tested successor uses explicit **`wivrn://192.168.0.44`** with LAN UDP video/RTX and normal reliable LAN TCP control/IDRs. Do not silently revert to TCP-only and claim the same recovery experiment.

For each eye bind exact frame X and packet sequence S:
DROP(X,S) → actual RTX_SENT(X,S) → accepted RTX_RECEIVED(X,S,shard=0) → RTX_ASSEMBLED(X) → exact RTX_MEDIA_OUTPUT(X) → IMAGE_AFTER_RTX(recovered=X,image>=X).
Require zero probe overflow, no pending probes at teardown and one decoder epoch. Pixel availability is not pixel cleanliness.

Loader-facing target is **openxr_wivrn**, ELF **libopenxr_wivrn.so**, manifest **openxr_wivrn-dev.json**. `libmonado_wivrn.so` is ancillary. Query/build with explicit build directory; verify x86-64, defined `xrNegotiateLoaderRuntimeInterface`, exact manifest resolution, dependencies and independent hashes.

## Workload and frozen gates

Seed 20261031; torture profile; 300 seconds; 26,933 stereo app submissions; six producer stalls, eight shared path events, six scheduled IDR requests. Total bitrate 45,921,000 bps. Input plans remained byte-identical across latest runs.

Reference mean 29,731 bytes, max 60,719 bytes, FPS 89.86744551786116. Existing mean tolerance ±4%; peak 0.75–1.25 × reference (upper **75,898.75 bytes**); cadence mean within 30 us; producer max gap 40,000–212,500 us; scheduler max lateness 3,000 us. Do not loosen these to fit outcomes.

## Latest device results

Both runs used identical sealed artifacts from 34f7b98b and completed unattended after launch.

| Run | Exact recovery | Traffic | Peak diagnostic | Left/right max bytes |
|---|---|---|---|---|
| 05 | PASS | PASS | PASS | 60,310 / 64,092 |
| 06 identical repeat | PASS | NOT_ESTABLISHED | PASS | 65,994 / 78,379 |

Run 06 right-eye peak: exact **P-frame 24678**, NVENC timestamp 24678, QP 39, invalidations-applied count 16; sender agrees exactly. Both eyes have overflow=0 and pending_media/image=0. Runtime errors empty. Only right-eye peak calibration failed. Older run 02 peak was 83,785 bytes without frame attribution; its cause remains unknown.

Rule 40: these measurements rule out an accounting-only or IDR-only explanation for the run-06 peak. They do not establish what caused it. Noise-level transitions, compositor sampling/head pose, reference handling and rate control remain candidates. CBR/two-frame VBV is not a hard per-picture cap. An applied-invalidation count does not prove causation.

**Next step:** correlate the exact encoded frame with the submitted stimulus level and actual compositor input, using existing evidence first. Add only necessary bounded instrumentation if required. Do not blind-tune bitrate/content, pad/truncate output, or repeatedly run until a favorable peak appears. Full failure audits are recorded; calibration release remains blocked.

Earlier launches failed because Quest was asleep, then Guardian held focus. ADB wake alone did not clear Guardian. User cleared the system dialog; subsequent runs worked. Do not bypass/change Guardian settings. Check readiness before spending a run.

## Local evidence and artifacts

All paths below are under:
`/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs`

- `peak-diagnostic-final-checkpoint.md`: authoritative comparison, full failure audits, exact artifact/frozen paths and hashes.
- `peak-diagnostic-audits.md`: full audit history, environment/readiness failures and gate decisions.
- `encoded-workload-peak-diagnostic/seal.json`: executable/plan hashes and tested source.
- `encoded-run-05-peak-diagnostic/`: complete passing capture/result/evidence seal.
- `encoded-run-06-identical-repeat/`: repeat calibration failure capture/result/evidence seal.
- `encoded-run-03-peak-diagnostic/`, `encoded-run-04-peak-awake/`: retained readiness failures.
- Isolated build: `/home/chineko/.codex/worktrees/hevc10-peak-diagnosis/WiVRn/build-server`.

Primary artifact SHA-256 values (paths relative to `encoded-workload-peak-diagnostic`):

- `server/wivrn-server`: `eaa0a4c56aa6a67d4e5688c4c604950e947a6c8c8231c9a5a71bf442a9531d85`
- `client.apk`: `5d056347651a4402b8edd812ef0575a0a4cc81876be6196e70a3aa0a918f2bf3`
- `runtime/libopenxr_wivrn.so`: `3df8fd18f22eae33e4eedd4be6c06826e395d550e648bf2ee28d00ed360320f8`
- `openxr_wivrn-dev.json`: `f6b7b05846a7f80e053e6c984604a7dd5f6cce2a79971f16ec647a1788d14595`
- `stimulus`: `96fc7d461d4d5dd2c952f31feaeb1c587e1a4db4d8d4b043deba9c56d36e8680`

Original frozen artifacts under `/home/chineko/helix-hevc10-decoder-recovery-v1-runtime` were reverified unchanged:

- `wivrn-server-hevc10-recovery-v1`: `98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d`
- `helix-hevc10-recovery-392bb662ed20.apk`: `cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087`
- `runtime-v1-metadata.txt`: `88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1`

On GitHub, `docs/helix/checkpoints/2026-11-01-peak-diagnostic/` contains summary, audits, selected exact evidence, original run results and artifact seal; binaries/raw captures stay local. Also read `docs/helix/2026-10-31-repeatable-hevc10-workload.md` and `docs/helix/2026-11-01-peak-diagnosis.md`.

## CI repair / latest validation

After pushing results, GitHub Format failed on Ruff and client/server formatting, including older Helix violations. Fixed at latest 0ff716ad using Ruff **0.16.0** and clang-format **22.1.8**, preserving workflow rules. All five C++ scopes pass; C++ changes are exactly formatter output. Python corrections include executable bits, imports, unused locals, bound loop captures, closed files and named exception logging at broad CLI/cleanup boundaries.

Verified generated model/trace/plans/seals byte-identical before/after; both saved run reductions unchanged; six reducer tests pass. No new native rebuild/device run for this successor. See `docs/helix/2026-11-01-ci-style-repair.md`.

Latest observed GitHub CI for 0ff716ad: **Format PASS**, **Locales PASS**, **Build queued**. Recheck current Build outcome once when deciding next action; do not report queued as green or poll continuously. Format run: https://github.com/Chineko/WiVRn/actions/runs/41308902373 . Build run: https://github.com/Chineko/WiVRn/actions/runs/41308902412 .

Tooling note: sandbox ADB cannot access USB/daemon socket and sandbox Gradle cache is read-only. Authorized host execution succeeded. Android build uses JDK17, ANDROID_HOME=/opt/android-sdk, removes conflicting ANDROID_SDK_ROOT, invokes Gradle wrapper via Java (not Bash). Server builds used explicit named targets, -j2. Temporary pinned format tools: `/tmp/helix-ci-format-tools` (may disappear; do not assume available on another setup).

Start by verifying checkout/remote identities and current CI, then continue the bounded peak-to-input diagnosis. Do not redo completed captures/builds without a decision-relevant reason.
