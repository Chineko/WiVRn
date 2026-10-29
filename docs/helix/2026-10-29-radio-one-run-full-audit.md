# Helix one-run Quest WLAN attribution — full Rule 40–42 audit

Date: 2026-10-29

## Scope and success condition

This audit covers the complete experiment used by `tools/helix-blackout-radio-run.sh` on branch `helix-blackout-attribution`.

The engineering question is deliberately narrow:

> During a real Helix gap/lag event where a PC->Quest UDP packet is present at the host capture point but absent from the Quest `wlan0` capture, was that packet observable at the Quest Qualcomm `wlan:dp_rx_udp_pkt` driver datapath tracepoint?

Success requires both the existing paired-PCAP integrity gate and the new Quest driver-trace gate to pass. A deeper radio result is not allowed to override a non-decisive paired-PCAP run.

This experiment does **not** claim to distinguish GE550 internal AP behavior from RF delivery failure from Quest radio/firmware behavior before `dp_rx_udp_pkt`.

## Prior evidence preserved

The previous decision-capable real WiVRn run already established that, during the characteristic Helix loss events, packets visible at the host capture point can be absent from the Quest `wlan0` capture with zero tcpdump kernel drops and consistent 6 GHz/BSSID endpoint state. This closes Quest WiVRn userspace/parser/decoder as the primary location of those packet disappearances and leaves the AP/RF/Quest-lower-radio region unresolved.

The current run does not reopen QoS, channel width, pacing, packet-load, bitrate, retransmission tuning, or frame-local FEC experiments.

## Audit A — local/function/generated-artifact audit

Reviewed the active path:

- `tools/helix-blackout-radio-run.sh`
- `tools/helix-blackout-usb-detached-run.sh`
- `tools/helix-blackout-radio-patch-v4.py`
- `tools/helix-blackout-radio-audit-v4.py`
- `tools/helix-blackout-radio-selftest.py`
- `tools/helix-blackout-radio-reduce-v4.py`
- `tools/helix-blackout-run.sh`
- `tools/helix-blackout-capture.sh`
- `tools/helix-blackout-reduce.py`

### Generated artifact integrity

The top-level radio runner first runs Python compilation, Bash syntax checks, and the radio reducer synthetic self-test. It then generates the exact final USB-detached/radio capture artifact without executing the runtime path, runs the dedicated generated-artifact audit on that exact file, copies it out, and records its SHA-256.

The runtime generation must produce an identical SHA-256 before `TMP_RUN` is allowed to touch runtime state. This closes the earlier failure mode where source fragments were reviewed but the actual generated capture artifact differed.

### Device trace-parser compatibility

Before the headset workload, the top-level runner creates a temporary tracefs instance, enables only `wlan:dp_rx_udp_pkt`, sends one setup-only UDP packet to the Quest, retrieves the actual rendered trace line, and runs that sample through the exact active radio reducer parser. The temporary instance is disabled and removed before the real capture path.

This closes the gap between a synthetic parser self-test and the actual Quest kernel trace text format.

### Observer lifecycle and ordering

The generated-artifact audit fails closed unless the final capture artifact has this order:

1. trace format/capability gate;
2. bounded driver trace arm and buffer/overwrite readback;
3. local Quest watchdog;
4. detached Quest tcpdump readiness;
5. trace synchronization marker gate;
6. explicit sudo refresh and keepalive;
7. noninteractive host tcpdump launch and readiness;
8. USB detach prompt;
9. zero-ADB gate;
10. capture start boundary;
11. `CAPTURE ARMED`;
12. workload;
13. sudo health check;
14. capture end boundary and end synchronization markers;
15. host observers stopped before reconnect;
16. USB reconnect and same-Quest gate;
17. end-marker retention check;
18. trace stop/preservation and retrieval;
19. paired-PCAP reduction.

The audit also rejects ADB commands inside the active detached workload window, interactive sudo after detach, all-events tracing, runtime/network mutation, and unbounded manual detach/reconnect prompts.

### Bounds and cleanup

- runtime capture remains bounded to 480 seconds;
- detach prompt is bounded to 180 seconds;
- reconnect prompt is bounded to 120 seconds;
- Quest trace/capture watchdog is bounded to 960 seconds;
- trace buffer is bounded to 32768 KiB per CPU with overwrite enabled and read back;
- only `wlan:dp_rx_udp_pkt` is selectively enabled;
- host privileged capture/teardown uses noninteractive sudo after one explicit credential refresh;
- exact output path reuse is rejected;
- temporary parser trace instance and dry generated artifact have cleanup paths.

Host command dependencies used directly by the top-level runner are explicitly preflighted, including `git` and `cut`.

## Audit B — whole-system audit

Experiment chain:

`real avatar workload -> validated WiVRn runtime -> host capture -> Ethernet/router/AP/RF/Quest radio region -> Quest dp_rx_udp_pkt trace -> Quest wlan0 capture -> Helix gap telemetry -> paired-PCAP reducer -> radio reducer -> overall decision gate`

### Runtime/build identity

The existing runtime preflight still requires runtime-source equivalence to validated base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a`, a clean tracked tree, matching built dashboard/server, the server runtime hash, exactly one rooted Quest over ADB setup, and the installed Quest native runtime hash. Existing dashboard/server processes are stopped before the verified dashboard path is launched.

### Measurement fidelity

The existing paired-PCAP reducer retains its local per-event clock alignment, nearby normal-traffic match ratio, fingerprint duplicate gating, PCAP coverage checks, zero tcpdump kernel-drop requirement, and endpoint-state gate.

The radio reducer adds:

- trace format field verification;
- parseable `dp_rx_udp_pkt` record requirement;
- trace dropped-event counter gate;
- Quest-PCAP <-> trace synchronization using explicit UDP marker tuples;
- optional start/end trace-clock drift check when the start marker is retained;
- high-volume PC->Quest stream-port discovery from the actual Quest PCAP;
- per-event local host/Quest alignment;
- nearby normal packets as a driver-trace visibility baseline;
- minimum baseline coverage and minimum missing-packet count;
- bounded time lookup around each packet key `(IPv4 ID, source port, destination port)`;
- retained-trace coverage check for each candidate gap event.

A gap event is only considered decisive when normal packets in the same local context are observed in the driver trace at high rate and at least ten host-visible packets are absent at `wlan0`.

### Combined decision gate

The top-level runner records:

- `base_paired_pcap_decision_capable`;
- `radio_decision_capable`;
- `overall_decision_capable`.

`overall_decision_capable=true` requires **both** lower-level gates to pass. A failed or ambiguous driver trace cannot be promoted to a root-cause result, and a failed paired-PCAP integrity gate cannot be overridden by the radio reducer.

### Observer effects

The new observer is an in-memory kernel trace of a single WLAN datapath event plus six explicit synchronization UDP packets around the run. There is no additional ADB traffic during the active workload and no new Quest storage writer during the workload. The trace itself has CPU and memory overhead and therefore remains a possible observer effect.

That observer effect is bounded but not mathematically eliminated. Interpretation must compare any captured event morphology with the already-observed untraced Helix loss events and must not claim that tracing proves the underlying failure frequency is unchanged.

### Remaining ambiguity

If host-visible/wlan0-missing packets are also absent from `dp_rx_udp_pkt`, the experiment can only place the disappearance **before that tracepoint**. With no router shell and no over-the-air sniffer, the remaining bucket still includes GE550/AP behavior, RF delivery, Quest radio/firmware, and earlier lower-driver handling.

If host-visible/wlan0-missing packets are present at `dp_rx_udp_pkt` while nearby normal Quest packets establish high driver-trace fidelity, the evidence supports a disappearance after the measured driver datapath observation point and before the `wlan0` capture point. It does not by itself identify a specific vendor function or firmware defect.

Mixed driver visibility remains non-decisive rather than being forced into either bucket.

## Rule 40 conclusion format for the eventual run

### Direct evidence

Report only packet visibility, capture/trace integrity gates, synchronization quality, local baseline fidelity, and measured event ratios.

### Supported inference

Use only the boundary classification justified by the observation points.

### Remaining ambiguity

Preserve AP/RF/radio/firmware ambiguity whenever packets are absent before the driver tracepoint, and preserve observer-effect ambiguity.

### Decision justified by the evidence

If the run is overall-decision-capable, stop repeating transport/router micro-tuning and act on the measured boundary. If it is non-decisive, preserve the run and stop rather than starting another tuning sweep.

## Gate status before user-machine execution

Repository/static full audit: **complete** for the current tooling design.

Exact generated artifact audit: **implemented as a mandatory dry gate and SHA identity check in the runner; it must pass on the user's checkout before runtime state is touched.**

Actual Quest trace-text parser compatibility: **implemented as a mandatory setup-only device preflight; it must pass before the generated capture artifact is executed.**

Runtime/headset validation of this final audited revision: **not yet performed.**
