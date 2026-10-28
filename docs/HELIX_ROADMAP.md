# WiVRn Helix Roadmap

## Project goal

WiVRn Helix is a resilience-focused WiVRn fork intended to improve wireless PCVR reliability without sacrificing WiVRn's low-latency architecture.

Helix combines proven ideas from WiVRn, Virtual Desktop, Moonlight/GameStream, ALVR, WebRTC-style recovery, and modern congestion-control techniques.

The project focuses on four failure classes:

- packet reordering
- packet loss
- network congestion
- decoder corruption or stalls

Guiding principle:

> Recover at the cheapest possible layer while always prioritizing fresh frames over stale frames.

## Branching and upstream policy

Helix development starts from a clean upstream WiVRn commit, not from locally modified branches.

Initial Helix base:

`WiVRn/WiVRn master @ 5d69e391e43b65f172fdd91fb1b0e276ea191903`

Primary development branch:

`helix`

Suggested feature branches:

- `helix-decoder-recovery`
- `helix-pacing`
- `helix-retransmission`
- `helix-fec`

Upstream WiVRn should remain the canonical source for rebases/merges so unrelated local modifications do not enter Helix accidentally.

---

# Helix 0.1 — Decoder recovery

## Objective

Eliminate the failure mode where the network successfully delivers a frame but the hardware decoder becomes corrupted or stops producing valid output.

This stage should avoid major transport-protocol changes and reuse WiVRn's existing feedback timestamps wherever possible.

## Decoder health controller

Track:

- latest frame submitted to decoder
- latest frame successfully decoded
- decoder submission timestamp
- decoded-output timestamp
- consecutive recovery failures
- current recovery state

Suggested states:

`HEALTHY`

→ decoder output stalls

`NEED_IDR`

→ IDR generated and submitted

`WAITING_FOR_IDR_OUTPUT`

→ decoded IDR output appears

`HEALTHY`

Escalation on failure:

`WAITING_FOR_IDR_OUTPUT`

→ timeout

`FLUSH_DECODER`

→ still broken

`RECREATE_DECODER`

→ request another IDR

## Initial watchdog thresholds

At 90 Hz, initial experimental values:

- 2 missing decoded outputs: suspicious
- 3–4 missing outputs: request IDR
- IDR submitted but no output after about 3 additional frames: flush decoder
- repeated failed recovery: recreate MediaCodec

Thresholds should ultimately scale with refresh rate.

## Decoder error recovery

Feed the following into one recovery mechanism:

- MediaCodec async errors
- input-buffer submission failures
- decoder output stalls
- invalid output timestamps
- decoder buffer overflow
- hardware decoder failure

## Verified IDR recovery

An IDR is not considered successful simply because it reached MediaCodec.

Recovery is complete only after decoded output from the new prediction chain is observed.

## Telemetry is part of 0.1

Telemetry is not deferred to a later milestone. Add enough measurement before adding more recovery complexity so we can distinguish whether IDR and flush already solve most decoder failures.

Track at minimum:

- frames submitted to MediaCodec
- decoded outputs observed
- submit-to-output latency
- decoder stall detections
- IDRs requested
- output resumed after recovery
- decoder flush attempts and results
- decoder recreation attempts and results
- recovery duration
- recovery reason

## Decoder recreation is its own validation slice

Full MediaCodec recreation should be implemented only after IDR + flush behavior is build-validated and device-tested.

Recreation must explicitly handle vendor-sensitive Android decoder lifecycle concerns, including:

- output surface / AImageReader ownership
- stale codec callbacks
- stale input and output buffer indices
- hardware-buffer lifetime
- sampler / Vulkan resource lifetime
- cleanup ordering
- avoiding leaks, deadlocks, or repeated reset loops

Treat Qualcomm, MediaTek, and other vendor implementations as potentially different until measured on-device.

### Success criterion

Intentionally induced decoder corruption or decoder-output loss recovers automatically without restarting the WiVRn session.

---

# Helix 0.2 — Network pacing and adaptive bitrate

## Objective

Prevent packet loss caused by large encoded frames being transmitted as short microbursts.

## Packet pacer

Insert a pacing layer between encoded frame production and UDP transmission.

Instead of:

`encoder → immediate UDP burst`

use:

`encoder → Helix packet pacer → UDP`

At 90 Hz, an initial target is to spread a frame across roughly 2–4 ms rather than the whole 11.1 ms refresh interval.

A token-bucket or leaky-bucket sender is a suitable first implementation.

Inputs:

- configured bitrate
- estimated available bandwidth
- packet queue depth
- current frame size

Outputs:

- packet send timing
- maximum instantaneous transmission rate

## Adaptive bitrate

Monitor:

- packet loss
- send queue delay
- delivery time
- RTT
- IDR frequency
- decoder lateness

Initial policy:

- congestion: bitrate × 0.7–0.8
- stable connection: bitrate × about 1.05
- user configured bitrate remains the upper limit

Decrease quickly and increase cautiously.

## Freshness policy

If network queues become too old:

- drop stale video
- do not allow latency to grow without bound
- force prediction recovery if continuity was broken

---

# Helix 0.3 — Reordering and deadline-aware retransmission

## Objective

Recover small amounts of packet loss without generating a full IDR.

## Rolling receive window

Extend the current accumulator into a small rolling frame window such as:

- N−1
- N
- N+1

Each frame tracks:

- shard reception
- first packet arrival
- expected shard count
- local decode deadline
- completeness

## Adaptive short reorder grace period

Do not hard-code a fixed 1 ms reorder window as the final behavior.

Initial experimental range:

`1–3 ms`

The receiver should measure actual packet reordering/jitter and choose the shortest grace period that avoids discarding packets that are merely slightly out of order.

This must remain much smaller than a conventional video jitter buffer.

## Packet sequence numbers

Add monotonic UDP video-packet sequence numbers per stream so the receiver can identify exact transport discontinuities without imposing cross-stream serialization. Use `(stream_item_idx, packet_sequence)` as the UDP transport identity; reliable control-path video packets remain outside this sequence space.

## Local monotonic timing

Timeouts, reorder grace periods, queue age, and retransmission deadlines should use receiver-local monotonic time wherever possible.

Do not assume host and headset clocks are directly comparable. Cross-device absolute deadlines should only be introduced if Helix later adds an explicit clock-synchronization model.

## Deadline-aware retransmission

If:

`estimated RTT + safety margin < remaining local frame deadline`

request the missing shard.

Otherwise abandon the frame and recover at a higher layer.

This preserves UDP's bounded-latency behavior while gaining selective reliability when retransmission can still arrive on time.

---

# Helix 0.4 — Adaptive forward error correction

## Objective

Repair packet loss locally without waiting for a round trip.

## FEC design

Use Reed-Solomon or equivalent erasure coding over encoded video shards.

Each frame should expose enough metadata for:

- data shard count
- parity shard count
- shard index
- packet sequence number
- frame dependency type

Suggested dependency classes:

- IDR
- reference frame
- non-reference frame

## Unequal protection

Initial experimental ranges:

- IDR: 15–20% FEC
- reference P frame: 5–10%
- non-reference P frame: 0–3%

These are tuning starting points, not fixed targets.

## Adaptive FEC

Increase parity for random loss.

Do not increase parity when telemetry indicates congestion; reduce bitrate first.

RTX remains earlier in the roadmap because very low-RTT clean LANs may recover isolated losses more cheaply with selective retransmission, while FEC becomes increasingly valuable when measured loss is bursty or retransmission frequently misses deadlines.

---

# Helix 0.5 — Recovery-frame protection

## Objective

Make recovery itself highly reliable and prevent keyframe recovery loops.

Possible mechanisms:

- higher FEC ratio for IDRs
- higher scheduling priority
- limited duplication of critical shards
- temporarily reduced IDR size / recovery quality
- dedicated pacing behavior
- selective retransmission for missing IDR shards

A temporarily softer recovery frame is preferable to a very large IDR that creates a new microburst and immediately loses packets again.

Helix must explicitly avoid this failure loop:

`packet loss → request IDR → oversized IDR burst → more packet loss → request another IDR`

---

# Helix 0.6 — Integrated congestion intelligence

## Objective

Combine network and decoder telemetry into one adaptive controller.

Possible inputs:

- RTT
- packet loss
- reordered packet rate
- retransmission success
- FEC repair rate
- FEC failure rate
- send queue delay
- frame delivery latency
- decoder latency
- decoder stalls
- IDR frequency

The controller should distinguish:

### Random packet loss

Prefer:

- FEC
- selective retransmission

### Congestion

Prefer:

- bitrate reduction
- pacing adjustment

### Decoder overload

Prefer:

- bitrate/resolution adjustment
- decoder recovery

### Decoder corruption

Prefer:

- IDR
- decoder flush/reset

---

# Helix telemetry

Telemetry starts in 0.1 and expands throughout development.

## Network metrics

- packets sent
- packets received
- packets lost
- packets reordered
- retransmissions requested
- retransmissions successful
- FEC recoveries
- unrecoverable FEC frames
- RTT
- send queue delay
- pacing delay

## Video metrics

- frames encoded
- frames transmitted
- frames dropped before transmission
- incomplete frames
- IDRs requested
- IDRs transmitted
- IDRs successfully decoded

## Decoder metrics

- frames submitted
- decoded frames produced
- decoder submission latency
- submit-to-output latency
- output stalls
- decoder errors
- decoder flush count
- decoder flush success/failure
- decoder recreation count
- decoder recreation success/failure
- recovery duration
- recovery reason

## Congestion metrics

- requested bitrate
- active bitrate
- estimated available bandwidth
- bitrate reductions
- bitrate recovery events

---

# Proposed architecture

Server:

`Video Encoder`

↓

`Frame Dependency Classification`

↓

`Adaptive Bitrate Controller`

↓

`FEC Encoder`

↓

`Helix Packet Pacer`

↓

`UDP Transport`

Client:

`UDP Receive`

↓

`Adaptive Short Reorder Window`

↓

`FEC Reconstruction`

↓

`Deadline-Aware Retransmission`

↓

`Frame Validation`

↓

`MediaCodec`

↓

`Decoder Health Monitor`

↓

`Decoded Frame ACK`

↓

`Compositor`

Parallel decoder recovery path:

`Decoder stall/error`

↓

`Request IDR`

↓

`Verify decoded output resumed`

↓ failure

`Flush Decoder`

↓ failure

`Vendor-safe Recreate Decoder`

↓

`Request New IDR`

---

# Source-layout policy

Helix should remain logically modular, but physical directories should follow WiVRn's existing build system and source conventions until a separate layout clearly reduces complexity.

Do not create `common/helix`, `server/helix`, or `client/helix` merely for architectural neatness if doing so creates unnecessary CMake/build-system work.

Preferred approach:

- keep each mechanism conceptually isolated
- place code beside the WiVRn subsystem it extends
- extract dedicated Helix modules only once the interface is stable and the extraction provides measurable maintenance value

A clean diff and easy upstream synchronization matter more than an idealized directory tree.

---

# Version targets

## Helix 0.1

Decoder reliability:

- decoder watchdog
- decoder error recovery
- frame-aware IDR recovery signal
- decoded-output recovery verification
- recovery telemetry
- decoder flush escalation
- vendor-safe decoder recreation as a separate validated slice

## Helix 0.2

Congestion prevention:

- packet pacing
- adaptive bitrate
- send queue telemetry
- stale-frame dropping

## Helix 0.3

Fast packet recovery:

- packet sequence numbers
- adaptive 1–3 ms reorder window
- receiver-local monotonic deadlines
- deadline-aware retransmission

## Helix 0.4

Packet-loss resilience:

- Reed-Solomon FEC
- unequal frame protection
- adaptive FEC informed by measured loss patterns

## Helix 0.5

Recovery hardening:

- protected IDRs
- optimized recovery pacing
- smaller recovery IDRs when useful
- IDR retransmission policy
- recovery-loop prevention

## Helix 0.6

Integrated adaptation:

- unified congestion classifier
- automatic tuning between bitrate, pacing, FEC, and retransmission
- richer diagnostics

---

# Core design principles

1. **Freshness beats completeness.** A late perfect frame is often worse in VR than dropping it and continuing with a fresh frame.

2. **Use the cheapest recovery mechanism first.** Preferred order: reordering correction → FEC/RTX according to deadline and measured loss → frame drop → IDR → decoder flush → decoder recreation.

3. **Never allow recovery traffic to worsen congestion.**

4. **Do not treat packet loss and decoder corruption as the same failure.**

5. **Verify recovery at decoded output, not network input.**

6. **Reduce bitrate rapidly; increase it cautiously.**

7. **Keep latency bounded at every queue.**

8. **Use local monotonic clocks for local deadlines unless explicit clock synchronization exists.**

9. **Measure before optimizing.** Helix should expose enough telemetry to explain why a frame failed and which recovery mechanism repaired it.

10. **Follow WiVRn's existing source/build structure until a Helix-specific extraction is justified by evidence.**

---

# First engineering milestone

The first working Helix build should remain protocol-compatible with upstream WiVRn wherever practical.

Primary systems to modify or inspect:

- Android MediaCodec decoder callbacks
- existing decoder feedback path
- `from_headset::feedback`
- `default_idr_handler`
- stream feedback transport
- decoder flush and recreation lifecycle
- basic recovery telemetry

First milestone:

**WiVRn Helix 0.1 — Decoder Recovery**

Validation order:

1. build Android variants successfully
2. verify normal streaming is unaffected
3. induce or simulate decoder-output failure
4. confirm IDR recovery request
5. confirm flush occurs only after failed recovery
6. confirm decoded output resumes after flush
7. only then implement and validate full MediaCodec recreation

Success criterion:

> Intentionally induced decoder corruption or decoder-output loss automatically recovers without restarting the WiVRn session.

Only after this milestone is stable should Helix begin making significant transport-protocol changes.
