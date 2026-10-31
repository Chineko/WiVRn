# Representative recovery evidence contract

Date: 2026-10-31

This document defines the separate representative-recovery lane. It does not change or reinterpret frozen workload parameters from the sustained live8/burst8 stability checkpoint.

## Purpose

The old sustained encoded-loss runner is retained as a server-side encoded-loss / NVENC invalidation stability regression. The representative lane exists to answer a different question: whether production-shaped packet timing and loss behavior exercise the real gap/RTX path and produce demonstrable recovery rather than merely continued submission to the decoder.

## Phase 1: transport recovery characterization

The first 300 s trace run is characterization, not promotion. No damaged-frame recovery percentage is frozen in advance.

Strict pre-runtime invariants:

- fixed seed: 20261031;
- fixed duration: 300 s;
- fixed profile: torture;
- exact whole-file trace SHA-256 sealed externally;
- generator self-test passes;
- standalone trace checker passes;
- payload clamping is forbidden;
- absolute trace timestamps drive replay;
- trace replay keeps RTX eligible;
- modeled dropped packets are cached and retransmitted only when the Quest requests the matching packet sequence;
- both stream indices are present in the trace and both must contain modeled path drops.

Strict runtime invariants for the characterization PASS:

- clean_failed=0;
- false_complete=0;
- rtx_requests>0;
- rtx_retransmissions>0;
- damaged_recovered>0;
- errors=none;
- runtime completes normally.

A damaged frame is counted `damaged_recovered` only when the frame reaches `sent_to_decoder != 0` and every modeled dropped packet for that frame was actually retransmitted through the RTX path. A damaged frame that completes without all modeled drops being retransmitted is `false_complete` and fails the characterization gate.

This phase proves transport-level recovery behavior only. `sent_to_decoder != 0` is not a Quest decoder-output verdict.

## Phase 2: decoder recovery evidence

Do not label a result `decoder recovery PASS` until Quest-side evidence records the first successful decoder output after a damaged/reference-loss event. The evidence must distinguish input submission from decoder output and must expose decoder errors.

Preferred evidence fields:

- injected/damaged frame index;
- invalidation application frame/time when applicable;
- first encoder frame submitted after invalidation;
- first Quest decoder output frame after the event;
- decoder error count;
- recovery distance in frames and time;
- optional deterministic decoded-content checksum or stimulus marker.

Until this exists, results remain `TRANSPORT_RECOVERY` or `SERVER_STABILITY`, never `DECODER_RECOVERY`.

## Codec and eye coverage

The representative lane must not generalize an H.264 8-bit result to the VRChat HEVC 10-bit configuration. HEVC 10-bit is a separate required run before claiming VRChat-codec recovery coverage.

Fault coverage must include both eyes/streams. Background traffic on the second stream is not fault coverage. The trace/audit must establish modeled dropped packets for stream 0 and stream 1.

## Real packet path

A representative transport run must exercise packet sequence numbers, video gap reports, RTX requests, and RTX retransmission. A run with zero gap/RTX activity is not representative recovery evidence even if the stream continues.

## Promotion rule

The first valid characterization run freezes observed distributions and recovery counts. Any later numeric promotion threshold must be chosen from an explicit policy before the promotion run; it must not be selected after seeing the candidate result.
