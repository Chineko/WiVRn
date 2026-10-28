# Helix shared-path blackout attribution slice

## Purpose

The FEC viability run showed that the dominant observed forward-loss events were synchronized across both main video streams, fully mapped to server send attempts, and spanned 42–67 consecutive packets over roughly 11–23 ms and 2–3 frame generations. That closes the gate against naive frame-local FEC as the next mechanism, but does not identify which shared downstream hop loses the packets.

This slice exists to move the failure boundary inward from both ends without adding a recovery mechanism.

## Decision question

When a Quest-observed forward packet gap occurs, did the corresponding UDP datagrams spend abnormal time inside the Linux transmit path, disappear between the PC and the Quest network device, reach the Quest kernel but not the WiVRn socket, or reach userspace and fail later?

The slice must answer that question before Helix invests in interleaved FEC, more aggressive redundancy, or rate-control changes aimed at a specific hop.

## Evidence already established

- Both main streams can lose packets during the same event.
- The measured missing ranges can span multiple frame generations.
- WiVRn recorded no initial UDP send errors for those ranges.
- Existing fixed-50us pacing telemetry did not show persistent sender queue collapse.
- Decoder processing remained healthy enough that the dominant long output gaps were associated with missing complete frames rather than intrinsic MediaCodec slowdown.
- The Quest 3 used for validation is rooted, so kernel/device/socket-side receive diagnostics are available and should be preferred over inference when practical.

These facts narrow the boundary but do not yet distinguish Linux qdisc/NIC, AP buffering/drop, the wireless hop, Quest driver/kernel receive, socket delivery, or userspace processing.

## Two-ended attribution strategy

Use the cheapest available observations at both ends in the same representative run.

### PC transmit boundary

Use Linux `SO_TIMESTAMPING` on the existing UDP streaming socket, with a bounded sampled diagnostic path rather than timestamping every shard.

The useful software transmit points are:

- `SOF_TIMESTAMPING_TX_SCHED`: timestamp before entering the packet scheduler.
- `SOF_TIMESTAMPING_TX_SOFTWARE`: timestamp as the packet leaves the kernel toward the device driver / network interface.

The delta between these points measures kernel/qdisc residence for a sampled datagram. This is a stronger discriminator than another userspace send timestamp because both points are generated inside the Linux networking stack.

Transmit timestamps are returned through the socket error queue (`MSG_ERRQUEUE`), so any in-process implementation must drain that queue without blocking the fresh-video send path.

### Rooted Quest receive boundary

Use root access to observe the receive path below and around WiVRn rather than inferring it only from application logs.

Preferred first-run observations, in increasing invasiveness:

1. Interface-level packet capture on the active Quest Wi-Fi interface for the WiVRn UDP stream.
2. Socket/syscall-level receive timing for the WiVRn process, using a root-capable tracing method that does not materially perturb runtime.
3. Kernel/eBPF/tracepoint diagnostics only if the first two layers leave the boundary ambiguous and the active Quest kernel exposes the required facilities.

The WiVRn stream transport is encrypted, so a raw interface capture should not be expected to expose the Helix packet sequence directly. It is still useful for determining whether UDP datagrams reached the Quest network interface during a blackout. Exact Helix packet identity remains available from WiVRn userspace telemetry after decryption.

Do not begin with vendor-specific Wi-Fi driver instrumentation if generic interface and socket observations can answer the boundary question.

## Sampling strategy

Do not request PC transmit timestamps for every video shard and do not trace every Quest kernel event by default.

Initial bounded experiment:

1. Sample one original video UDP shard at a fixed low rate, initially approximately one sample per frame per active main stream.
2. Preserve a bounded correlation table from sampled packet identity to userspace send-attempt time and returned TX timestamps.
3. Never block the pacer waiting for a timestamp.
4. Drain timestamp/error-queue records from a separate bounded diagnostic path.
5. Capture the corresponding Quest UDP traffic at interface level for the full run or a bounded rolling window, whichever is operationally simpler and less perturbing.
6. If practical, record WiVRn process receive syscalls/timing during the same run. Prefer a bounded tracing filter rather than an unrestricted system-wide trace.
7. If PC timestamp support or a Quest tracing facility is unavailable, record that fact and continue with the remaining observation points; do not fail streaming.

The exact PC sampling rate is provisional. Do not tune it unless the first run shows that one sample per frame materially perturbs pacing or is too sparse to classify an event.

## Telemetry

For each usable sampled PC packet, retain enough information to correlate it with Helix packet identity:

- stream index
- packet sequence
- frame index
- userspace send-attempt timestamp
- TX_SCHED timestamp when available
- TX_SOFTWARE timestamp when available
- userspace -> TX_SCHED latency
- TX_SCHED -> TX_SOFTWARE latency

PC aggregate summary:

- samples requested
- samples with TX_SCHED
- samples with TX_SOFTWARE
- samples with both
- missing/error-queue timestamp records
- userspace -> sched avg/max and histogram
- sched -> software avg/max and histogram
- diagnostic queue depth / drops if an internal queue is used

Quest-side evidence for each blackout window should include, where available:

- interface capture packets immediately before, during, and after the WiVRn-observed sequence gap
- active Wi-Fi interface name and UDP stream port
- whether UDP traffic continues at the interface while WiVRn reports a gap
- socket/syscall receive activity over the same window
- relevant kernel/socket drop counters before and after the run when available

For a Quest-reported forward gap, correlate the nearest sampled PC packets and the Quest receive observations around the same wall-clock/monotonic interval.

## Interpretation gate

### Sender-kernel/qdisc bottleneck

Quest sees a blackout and sampled PC packets near that interval show abnormally large `TX_SCHED -> TX_SOFTWARE` delay or timestamp backlog compared with normal delivery.

This justifies investigating qdisc/socket/NIC scheduling, pacing integration, or host-side congestion prevention before FEC.

### Loss after PC software TX but before Quest interface capture

PC TX timestamps remain normal through the blackout, while the corresponding UDP traffic disappears from the Quest interface capture over the same interval.

This moves the likely boundary toward the PC NIC / wired path / AP / wireless hop / Quest NIC receive boundary. Given the known wired PC-to-router link, AP or wireless-side behavior becomes a stronger target than host queue tuning.

### Quest kernel/socket delivery problem

Quest interface capture shows the UDP traffic arriving during the blackout, but socket/syscall receive activity does not deliver corresponding datagrams to WiVRn or kernel/socket drop counters rise.

This justifies investigating Quest receive buffering, scheduler pressure, socket receive capacity, kernel drops, or Android networking behavior before adding network redundancy.

### WiVRn userspace processing problem

Quest socket/syscall tracing shows the UDP datagrams delivered to the WiVRn process while Helix sequence telemetry still reports a gap.

This would move the bug boundary into decryption, deserialization, packet dispatch, or application receive processing and should be debugged there before FEC.

### Later pipeline problem

Helix sequence telemetry shows the packets were received but complete-frame or decoder output still disappears.

This moves the failure boundary beyond packet delivery and should be correlated with frame assembly / decoder health rather than treated as transport loss.

### Ambiguous result

If timestamp support is incomplete, captures miss every blackout boundary, clocks cannot be correlated adequately, or the diagnostic path perturbs pacing, do not infer a hop. Record the limitation and change the instrumentation method.

## Bottleneck and correctness review

Before runtime validation, verify:

- PC timestamping does not alter MTU or video payload format;
- timestamp error-queue handling cannot consume unrelated socket errors incorrectly;
- error-queue draining is nonblocking;
- timestamp correlation cannot grow without bound;
- sampled diagnostics do not hold the encoder mutex while waiting for kernel events;
- the shared 50 us pacer is not delayed by timestamp processing;
- Linux-only code is isolated from Android/other build paths;
- feature unavailability degrades to telemetry-off, not stream failure;
- identifiers cannot be confused by retransmission packets or control/fallback packets;
- Quest capture/tracing is read-only with respect to the Wi-Fi configuration and does not change radio policy during the test;
- Quest tracing buffers and capture files are bounded enough not to create storage or scheduler pressure that could manufacture the failure;
- root-only diagnostics are not added as a runtime dependency of Helix itself.

## Success condition

One representative runtime run produces at least one Quest-observed forward-gap event and enough adjacent observations to classify the failure boundary into at least one of these buckets:

- abnormal PC software TX/qdisc residence
- normal PC TX but missing before Quest interface capture
- present at Quest interface but missing before WiVRn socket/userspace delivery
- delivered to WiVRn userspace but lost in WiVRn processing
- packet delivery healthy, failure later in frame/decoder pipeline
- not measurable with the chosen method

No recovery algorithm is added in this slice.

## Stop conditions

Stop and redesign before runtime testing if:

- timestamping requires invasive changes to the packet format;
- the only PC implementation requires blocking the fresh send path;
- the error queue conflicts with existing network error handling in a way that cannot be cleanly separated;
- Quest tracing requires a vendor-specific invasive kernel modification when a simpler capture method remains available;
- the diagnostic code produces an unexpectedly large architectural diff;
- the diagnostics materially perturb pacing, CPU scheduling, Wi-Fi behavior, or packet reception.

## Deferred

Not part of this slice:

- frame-local FEC
- cross-frame/interleaved FEC
- adaptive parity amount
- RTX threshold tuning
- pacing parameter sweeps
- bitrate/rate-control redesign
- permanent vendor-specific Quest Wi-Fi driver hooks

Those decisions follow the attribution result rather than precede it.
