# Helix shared-path blackout attribution slice

## Purpose

The FEC viability run showed that the dominant observed forward-loss events were synchronized across both main video streams, fully mapped to server send attempts, and spanned 42–67 consecutive packets over roughly 11–23 ms and 2–3 frame generations. That closes the gate against naive frame-local FEC as the next mechanism, but does not identify which shared downstream hop loses the packets.

This slice exists to move the failure boundary inward from both ends without adding a recovery mechanism.

## Decision question

When a Quest-observed forward packet gap occurs, did the corresponding UDP datagrams spend abnormal time inside the Linux transmit path before reaching the NIC/driver boundary, or did they leave the kernel promptly and disappear later in the AP / wireless / Quest receive path?

The slice must answer that question before Helix invests in interleaved FEC, more aggressive redundancy, or rate-control changes aimed at a specific hop.

## Evidence already established

- Both main streams can lose packets during the same event.
- The measured missing ranges can span multiple frame generations.
- WiVRn recorded no initial UDP send errors for those ranges.
- Existing fixed-50us pacing telemetry did not show persistent sender queue collapse.
- Decoder processing remained healthy enough that the dominant long output gaps were associated with missing complete frames rather than intrinsic MediaCodec slowdown.

These facts narrow the boundary but do not distinguish Linux qdisc/NIC, AP buffering/drop, the wireless hop, or Quest receive scheduling.

## First instrumentation target: Linux TX timestamping

Use Linux `SO_TIMESTAMPING` on the existing UDP streaming socket, with a bounded sampled diagnostic path rather than timestamping every shard.

The useful software transmit points are:

- `SOF_TIMESTAMPING_TX_SCHED`: timestamp before entering the packet scheduler.
- `SOF_TIMESTAMPING_TX_SOFTWARE`: timestamp as the packet leaves the kernel toward the device driver / network interface.

The delta between these points measures kernel/qdisc residence for a sampled datagram. This is a stronger discriminator than another userspace send timestamp because both points are generated inside the Linux networking stack.

Transmit timestamps are returned through the socket error queue (`MSG_ERRQUEUE`), so the implementation must drain that queue without blocking the fresh-video send path.

## Sampling strategy

Do not request timestamps for every video shard.

Initial bounded experiment:

1. Sample one original video UDP shard at a fixed low rate, initially approximately one sample per frame per active main stream.
2. Additionally sample packets around an observed loss window only if that can be done without adding receiver-driven feedback to the fresh send critical path.
3. Preserve a bounded correlation table from sampled packet identity to userspace send-attempt time and returned TX timestamps.
4. Never block the pacer waiting for a timestamp.
5. Drain timestamp/error-queue records from a separate bounded diagnostic path.
6. If timestamp support is unavailable on the active interface/driver, record that fact and fall back cleanly; do not fail streaming.

The exact sampling rate is provisional. Do not tune it unless the first run shows that one sample per frame materially perturbs pacing or is too sparse to classify an event.

## Telemetry

For each usable sampled packet, retain enough information to correlate it with Helix packet identity:

- stream index
- packet sequence
- frame index
- userspace send-attempt timestamp
- TX_SCHED timestamp when available
- TX_SOFTWARE timestamp when available
- userspace -> TX_SCHED latency
- TX_SCHED -> TX_SOFTWARE latency

Aggregate summary:

- samples requested
- samples with TX_SCHED
- samples with TX_SOFTWARE
- samples with both
- missing/error-queue timestamp records
- userspace -> sched avg/max and histogram
- sched -> software avg/max and histogram
- diagnostic queue depth / drops if an internal queue is used

For a Quest-reported forward gap, log the nearest sampled packets before and after the missing sequence range and whether either shows abnormal kernel/qdisc residence.

## Interpretation gate

### Evidence supporting a sender-kernel/qdisc bottleneck

During a Quest-observed blackout, sampled packets immediately before/after the missing range show large `TX_SCHED -> TX_SOFTWARE` delays or a clear timestamp backlog that is not present during normal delivery.

This would justify investigating qdisc/socket/NIC scheduling, pacing integration, or host-side congestion prevention before FEC.

### Evidence supporting a later shared-path failure

Sampled packets around the blackout receive normal TX_SCHED and TX_SOFTWARE timing, while Quest still observes the multi-stream sequence gap.

That would move the likely failure boundary beyond the Linux software TX path, toward NIC/AP/wireless/Quest receive. It would justify the next receiver/link-side attribution step and make temporal/interleaved redundancy more plausible than host-queue tuning.

### Ambiguous result

If timestamp support is incomplete, sampling misses every blackout boundary, or the diagnostic path perturbs pacing, do not infer a hop. Record the limitation and change the instrumentation method.

## Bottleneck and correctness review

Before runtime validation, verify:

- timestamping does not alter MTU or video payload format;
- timestamp error-queue handling cannot consume ordinary control/data errors incorrectly;
- error-queue draining is nonblocking;
- timestamp correlation cannot grow without bound;
- sampled diagnostics do not hold the encoder mutex while waiting for kernel events;
- the shared 50 us pacer is not delayed by timestamp processing;
- Linux-only code is isolated from Android/other build paths;
- feature unavailability degrades to telemetry-off, not stream failure;
- identifiers cannot be confused by retransmission packets or control/fallback packets.

## Success condition

One representative runtime run produces at least one Quest-observed forward-gap event and enough adjacent TX timestamp samples to classify the Linux software TX path as either:

- abnormal during the event,
- normal during the event,
- or not measurable with this method.

No recovery algorithm is added in this slice.

## Stop conditions

Stop and redesign before runtime testing if:

- timestamping requires invasive changes to the packet format;
- the only implementation requires blocking the fresh send path;
- the error queue conflicts with existing network error handling in a way that cannot be cleanly separated;
- the diagnostic code produces an unexpectedly large architectural diff;
- the active wired NIC/driver cannot provide the required software TX points and a cheaper host-side discriminator is available.

## Deferred

Not part of this slice:

- frame-local FEC
- cross-frame/interleaved FEC
- adaptive parity amount
- RTX threshold tuning
- pacing parameter sweeps
- AP-specific telemetry integration
- Quest kernel/driver instrumentation
- bitrate/rate-control redesign

Those decisions follow the attribution result rather than precede it.
