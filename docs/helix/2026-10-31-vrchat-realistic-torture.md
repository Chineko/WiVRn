# Helix realistic VRChat torture test + audit of `helix-quest-transport-swapchain-fix-tooling`

Date: 2026-10-31
Base: `helix-quest-transport-swapchain-fix-tooling @ a4165a3c`

## Part 1 - Audit of the base branch

Read-only audit: nothing here was built against the NVENC/Quest toolchain, and the Vulkan
stimulus builders were read, not run. Findings are ordered by how much they affect the
test results.

### Realism gaps (why the existing torture tests are not VRChat-like)

1. **The transport battery is a unit-test list, not a stream.** `helix_synthetic_transport.cpp`
   runs ~330 serial cases, each a damaged frame plus an exposing frame, then waits 300 ms.
   It never produces sustained 90 Hz traffic on two eyes at once.
2. **Fixed 64-shard frames.** Real VRChat (server log 2026-10-28 17:40): mean 28.3 KB/frame,
   max 60.1 KB, ~21 shards/frame (max 44). The battery sends 64 x 960 B every frame.
3. **Send spacing is wrong by ~7x.** `sleep_for(60us)` measured 121 us mean (p99 137 us) on a
   stock Linux timer slack, so a 64-shard frame spans ~7.7 ms. Production sends a frame in
   ~1.05 ms (fixed 50 us pacer).
4. **Loss is a clean omission.** Measured failures are a contiguous run of 43-90 packets
   followed by survivors arriving 15-43 ms late, and (separately) an 89 ms hold with no
   loss. Omission has no delay component, so late-arrival behaviour is never exercised.
5. **No producer stalls or IDR bursts.** Real runs show 43-165 ms frame gaps and IDR
   requests around them.
6. **The Vulkan stimulus is cyclic noise.** The sustained/variable builders upload 8
   deterministic noise patterns and select `produced % 8`; there is no scene motion and no
   relation to VRChat's size distribution. I did not measure the encoded sizes it produces.
7. **RTX is effectively untested** in sustained traffic: shard `view_info.display_time` is 0
   (expired on purpose), so no retransmission request is ever eligible.

### Reproducibility / process

8. `tools/` holds 95 files / 12.5k lines; 56 have `v2/fix/strict/audited/repair` style
   names. Superseded versions are kept next to current ones.
9. Builders pin sha256 of binaries under `$HOME/helix-encoded-nvenc-build-20261030-160211`.
   Those artifacts exist only on one machine, so nobody else can rebuild the stimulus. The
   hashes prove identity, not realism. 38 tool files reference `$HOME`.
10. Several scripts patch source with exact-count string anchors
    (`tools/helix-apply-*.py`). After the patch is committed these are dead weight.

### Production-path risk inside a tooling branch

11. `idr_handler.cpp` (IDR retargeting in `wait_idr_feedback`) and `video_encoder_nvenc.cpp`
    (reference invalidation queue, `inputTimeStamp = frame_index`, drain before encode) change
    normal runs. They are not behind the synthetic flag, and the synthetic transport cannot
    validate NVENC invalidation (the branch's own doc says so). I found consistent lock
    ordering (invalidation mutex before IDR mutex) and no deadlock; this is a review of
    the diff only. Recommend splitting production changes from harness/tooling.
12. `server/main.cpp` moves `delay_next_try = default_delay_next_try` before `start_server()`.
    That changes reconnect timing on the normal path, contradicting "normal server path
    unchanged when the flag is absent".
13. `raw_decoder::push_data` does an unchecked `memcpy` into a fixed buffer. A trace with an
    oversized frame would overflow the Quest heap. This branch adds a loader gate
    (below); the receiver should also bounds-check.
14. Five scripts run `pkill -x wivrn-server`, which kills a real running server. The
    `git reset --hard` rollback in `helix-apply-build-prediction-chain.sh` is guarded by a
    clean-tree and expected-branch check, which is acceptable.

### Good practice worth keeping

Explicit `--helix-synthetic-transport` debug flag, bounded runs, oracle self-test, named
regression subset for the recorded burst corpus, clean-tree gates.

## Part 2 - What this branch adds

| File | Purpose |
|---|---|
| `tools/helix-vrchat-workload-model.py` | Deterministic trace generator + calibration gate + self-test |
| `server/helix_vrchat_trace.h` | Header-only loader/validator (std only) |
| `tools/helix-vrchat-trace-check.cpp` | Standalone preflight using the same validator |
| `server/helix_synthetic_transport.cpp` | `run_trace()`; selected by `HELIX_SYNTHETIC_TRACE=<file>` |

### Model

Two eyes at 90 Hz; AR(1) log-normal frame sizes pinned to mean 28.4 KB / max 60.1 KB; IDR
spikes after stalls and path events; producer stalls (40-170 ms); 50 us pacing with rare
slow sends; ~1385 B shards. A shared FIFO path model applies three measured signatures to
both eyes at once: `erasure_hold` (10-19 ms loss, then 15-60 ms hold and drain), `hold`
(30-90 ms, no loss) and `short_erasure`. Events cluster, with follow-ups mostly short.
Because both effects come from one path, a given stall loses packets when load is high and
only delays them when load is low.

Profiles: `measured` (~1.0 incomplete frames/min) and `torture` (~5.0/min, matching the
4.5/min of the 2026-10-29 blackout session).

Every constant carries its source in the script. **ASSUMED** values (size shape, drain rate,
event mix) are only pinned by aggregates and should be refit. `--calibrate-from <server log>`
re-pins size and cadence from `Helix pacing baseline` lines.

### Run

```
python3 tools/helix-vrchat-workload-model.py --self-test
python3 tools/helix-vrchat-workload-model.py --profile torture --duration 300 --out /tmp/vrchat.trace
c++ -std=c++20 -O2 -I server tools/helix-vrchat-trace-check.cpp -o /tmp/trace-check && /tmp/trace-check /tmp/vrchat.trace
HELIX_SYNTHETIC_TRACE=/tmp/vrchat.trace HELIX_SYNTHETIC_TRACE_SEND_LOG=/tmp/send.csv \
    wivrn-server --helix-synthetic-transport
```

Result line: `HELIX_VRCHAT_TRACE_RESULT`. This first lane is characterization, not a
post-hoc percentage promotion gate. Clean frames must remain complete, a damaged frame may only
complete after all modeled omitted sequences were retransmitted, and two deterministic single-
shard-0 RTX canaries (one per eye) must both recover. Representative damaged-frame recovery is
reported, not thresholded.

### What was verified here, and what was not

Verified: generator determinism, calibration gate with three mutation checks, loader
accepts a 300 s trace (1.12 M rows) and rejects 8 mutated traces, including an exact
61,440-byte frame-size boundary; `run_trace()` passes `g++ -fsyntax-only -Wall -Wextra
-Wformat` against the repo headers (stubbed Monado logging); the pacing loop was measured
at p50 0.1 us, p99 35 us, p99.9 ~1 ms, max 3.1 ms lateness on a shared cloud VM.

Not verified: linking or running the server, any Quest run, whether the receiver completes
frames delivered late in order, and the representative damaged-frame recovery distribution before any promotion threshold is frozen. The raw 256x160
decoder does not exercise HEVC decode, Quest thermals or VRChat CPU/GPU load.
