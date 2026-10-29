# Helix Quest driver attribution — full Rule 40–42 audit — 2026-10-29

## Purpose and governing question

This checkpoint re-audits the **entire** remaining blackout-attribution experiment after two failed preflight attempts. It does not treat those failures as isolated holes.

The already-established real-run result is preserved: during Helix gap events, packets visible at the host capture point are absent from the Quest `wlan0` capture point with clean paired-capture integrity. The next and only planned workload run asks one narrower question:

> For host-visible WiVRn UDP packets that are missing from Quest `wlan0` during a real lag/gap event, were those packets already visible at Qualcomm `wlan:dp_rx_udp_pkt`?

The observation chain under test is therefore:

`host PCAP -> AP / RF / Quest radio-firmware / earlier Quest driver -> Qualcomm dp_rx_udp_pkt -> later Quest lower receive path -> Quest wlan0 PCAP`

This slice does **not** reopen PC-to-router Ethernet, QoS, channel width, pacing sweeps, bitrate redesign, decoder attribution, frame-local FEC, or RTX tuning.

Audited tool head before this documentation-only checkpoint: `03907c417ef38aaaf5702545aa01bf02310dc80e`.

## Prior failures that forced the full re-audit

Two preflight failures occurred before `CAPTURE ARMED`:

1. the radio helper matched a generated detached-tcpdump command too literally and failed to patch the exact generated artifact;
2. host tcpdump was started after USB detach, allowing the host sudo credential to expire while the user moved into VR, so host capture readiness raced an interactive sudo prompt.

Neither failure consumed the intended reproduction run, but together they demonstrated that source-fragment review was insufficient. The current path therefore makes the **exact generated capture artifact** a first-class audited object.

## Final active tooling

Only the following radio-attribution tools remain active; obsolete draft patch/audit/reducer versions were removed:

- `tools/helix-blackout-radio-run.sh`
- `tools/helix-blackout-radio-patch-v4.py`
- `tools/helix-blackout-radio-audit-v4.py`
- `tools/helix-blackout-radio-reduce-v4.py`
- `tools/helix-blackout-radio-selftest.py`
- existing `tools/helix-blackout-usb-detached-run.sh`
- existing paired-PCAP capture/reducer tooling

## Audit A — local/function/generated-artifact audit

### Generation and identity

The radio runner first compiles all Python helpers, syntax-checks the USB wrapper, and runs a static reducer self-test. It then performs a **dry generation** of the exact final capture script without executing the runtime/device path.

The independent radio audit checks that exact generated capture script and computes its SHA-256. The real path regenerates the artifact and must match the dry-audited SHA-256 byte-for-byte before the generated runtime script may execute. A source-level review therefore cannot silently diverge from the actual generated artifact.

### Quest trace capability and fidelity

The rooted Quest inventory established writable tracefs and Qualcomm `wlan:dp_rx_udp_pkt`. The generated preflight:

- verifies the event format exposes `ip_id`, `srcport`, and `dstport`;
- creates a per-run trace instance;
- globally disables events, then enables only `wlan:dp_rx_udp_pkt`;
- requests a 32768 KiB per-CPU overwrite ring;
- reads `buffer_size_kb` back and requires the requested value;
- reads the overwrite option back and requires it enabled;
- verifies tracing and the selected event remain enabled.

The trace remains in RAM during the workload; it is not continuously streamed over ADB or written as a text trace file during active reproduction.

### Trace/PCAP synchronization

The Qualcomm trace uses a different clock domain from PCAP timestamps. The final design does not infer a multi-minute offset from cycling IPv4 IDs.

Two explicit three-packet marker sets are used:

- setup marker destination ports: `49171,49172,49173`;
- end marker destination ports: `49271,49272,49273`.

The setup marker is sent while USB is still attached, after Quest tcpdump is proven active, and each marker must appear in `dp_rx_udp_pkt` before detach.

The end marker is sent immediately **after** `capture_end_epoch_ns` is recorded and while Quest tcpdump and the driver trace are still active, but before USB reconnect. Therefore marker traffic is outside the declared workload interval and reconnect delay cannot determine the trace clock anchor.

Post-run analysis identifies each end marker in the Quest PCAP first, extracts its exact `(IPv4 ID, UDP source port, UDP destination port)` tuple, and requires the same tuple in the driver trace. The median three-marker Quest-PCAP-to-trace offset is used only if marker MAD is within the gate. If the setup marker remains in the overwrite ring, start/end offset drift is also checked; if it has been overwritten, that is recorded as expected rather than promoted into evidence.

### Host observer and privilege lifecycle

The actual host tcpdump and host sampler are launched and verified **before** the USB-detach prompt. One explicit `sudo -v` occurs while the user is still at the terminal, followed by a local `sudo -n -v` keepalive.

The actual host capture and teardown path use noninteractive `sudo -n`. At workload end, before the declared end timestamp, the harness requires both the keepalive process and `sudo -n -v` to remain valid. This closes the previously observed interactive-sudo race.

### USB-detached workload boundary

The exact generated artifact is independently checked for this order:

`trace format/readback -> trace arm/watchdog -> Quest tcpdump ready -> setup sync -> sudo refresh -> host tcpdump ready -> USB detach prompt -> zero ADB -> capture start -> CAPTURE ARMED -> workload -> sudo health -> capture end -> end sync -> host shutdown -> USB reconnect -> same Quest -> end-sync retention -> trace freeze/pull -> base reduction`

No `adb shell`, `adb exec-out`, or `adb devices` command is allowed inside the declared active workload interval after the zero-ADB gate and before `capture_end_epoch_ns`.

The detach prompt is bounded to 180 seconds, the workload capture to 480 seconds, and reconnect prompt to 120 seconds.

### Abort and cleanup paths

A detached Quest watchdog bounds both Quest tcpdump and the driver trace if the host disappears while USB is disconnected. Normal reconnect kills the watchdog, freezes the trace, captures per-CPU trace stats, pulls the trace/format/stats, and removes the trace instance.

Host cleanup uses the existing capture lifecycle plus noninteractive sudo. The full raw trace remains in the raw capture directory after successful retrieval.

### Reducer local/function gates

The radio reducer reuses the existing paired-PCAP parser/correlation functions and adds only the driver-boundary decision.

It requires:

- runtime-source equivalence;
- USB-detached workload metadata;
- consistent 6 GHz/BSSID endpoint state from the existing harness;
- zero host and Quest tcpdump kernel drops;
- required trace files and event fields;
- trace `dropped events` counters available and zero;
- exact end-marker trace/PCAP alignment;
- a high-volume PC-to-Quest UDP port pair;
- at least one fully mapped Helix gap event covered by the retained driver trace;
- local host-to-Quest packet correlation for each covered event;
- local clock MAD and duplicate-ratio gates;
- at least 50 surrounding normal packets seen at `wlan0`;
- driver visibility for at least 90% of that local normal baseline;
- at least 10 host-visible packets missing from `wlan0` inside the reconstructed event send interval.

Only then is the missing-packet driver-visibility ratio interpreted.

A static self-test verifies Ethernet/IPv4/UDP key extraction, exact sync-key matching, resistance to an unrelated same-destination-port trace record, trace parsing, trace-stat parsing, and bounded timestamp lookup.

### Historical threshold sanity

The thresholds were checked against the already-captured real blackout PCAP rather than chosen from a toy workload. Across the ten previous mapped gap events, ±0.5 s local host-to-Quest match ratios were approximately 96–98%, with roughly 1,800–4,000 unique local matches and 57–106 host-visible packets absent from `wlan0` inside the reconstructed event windows.

Therefore the new minimums (90% local match, 50 unique matches, 50 normal baseline packets, 10 missing packets) are deliberately below the known real signal and are evidence-quality gates rather than marginal tuning targets.

### Reduced artifact handling

The existing base reducer may initially copy the full text driver trace into its post-run reduced directory. The radio runner removes only that **copied** trace from the reduced directory after confirming the full raw trace remains intact. It adds `radio-attribution-summary.txt` and atomically replaces the upload archive only after the bounded replacement archive is successfully created. The original archive remains available until replacement succeeds.

## Audit B — whole-system audit

### Actual success condition

A successful run is not merely one that produces a trace file. It must contain at least one real Helix gap event for which:

1. host and Quest PCAP correlation is locally healthy;
2. surrounding packets that reach `wlan0` are also visible in `dp_rx_udp_pkt` at >=90%;
3. at least 10 host-visible packets are absent from `wlan0` in the event interval;
4. the driver trace retained that event;
5. trace/PCAP clock synchronization and capture integrity gates pass.

Only such an event can answer the boundary question.

### Directly supported classifications

For a decision-capable event:

- if packets missing at `wlan0` are nevertheless present in `dp_rx_udp_pkt` at >=80%, evidence supports loss/drop/stall **after** the Qualcomm tracepoint and before normal `wlan0` visibility;
- if those missing packets are absent from `dp_rx_udp_pkt` at >=90% (driver-present ratio <=10%), evidence supports the loss occurring **before** this Qualcomm tracepoint;
- intermediate/mixed visibility is not promoted to either causal bucket.

If multiple decisive events are retained, they must agree on the same side of the threshold. Mixed event-level results remain non-decisive.

### Observer effects

The new workload observer is one Qualcomm RX-UDP tracepoint in an in-RAM overwrite buffer. It necessarily adds some receive-path tracing overhead and may change the frequency or timing of the phenomenon. The experiment therefore attributes only events that actually occur under observation; it does not claim the instrumentation leaves blackout frequency unchanged.

The previous paired PCAP and host sampler remain as already audited. There is no ADB session during the declared workload. Sync-marker packets are outside the workload interval.

### Resource pressure

The trace ring is requested at 32768 KiB per CPU and must be read back successfully before detach. Overwrite mode is intentional so the most recent events are retained. Events outside the retained trace tail are skipped rather than treated as missing driver evidence. At least one retained decisive event is required.

Quest storage remains protected by the existing capture free-space gate. The trace is materialized to a text file only after the workload on reconnect. The upload bundle excludes the copied full driver trace; the full raw trace remains local for forensic use.

### Provenance and runtime identity

The existing run wrapper still verifies the validated runtime source base, clean tracked tree, matching desktop/server build identity, rooted Quest, installed native artifact identity, and normal matching dashboard/server workflow. Radio changes are confined to docs/tools and do not modify WiVRn runtime traffic, pacing, bitrate, decoder, FEC, RTX, QoS, channel selection, or Wi-Fi configuration.

### Remaining ambiguity

Even a clean `host present / dp_rx absent / wlan0 absent` result does **not** distinguish:

- GE550/AP internal buffering/drop;
- 6 GHz RF delivery/retry failure;
- Quest radio/firmware behavior before this tracepoint;
- an earlier Quest driver stage before `dp_rx_udp_pkt`.

`dp_rx_udp_pkt` is a Qualcomm driver-datapath observation point, not RF/PHY telemetry.

A clean `host present / dp_rx present / wlan0 absent` result narrows the event into the Quest lower receive path after this tracepoint, but may still not uniquely identify a single internal driver/firmware subcomponent.

If the result is mixed, the local baseline fails, trace integrity fails, no mapped gap is retained, or no decisive event is covered, the run is explicitly **non-decisive**. That outcome does not justify another pacing/QoS/bitrate/load sweep.

## Rule 40 result format after the run

The post-run conclusion must be written in four sections:

1. **Direct evidence** — per-event host/driver/wlan visibility and all integrity gates.
2. **Supported inference** — which side of `dp_rx_udp_pkt` the observed event belongs to, if decision-capable.
3. **Remaining ambiguity** — exact components that the observation boundary still combines.
4. **Decision justified by the evidence** — component-specific investigation if the Quest side is isolated, or acceptance of the AP/RF/radio boundary and movement to mitigation/recovery architecture if it is not.

## Gate status

- Full repository-level Audit A: **complete for the current generated-artifact design after the fixes above**.
- Full whole-system Audit B: **complete for the explicit host-PCAP -> Qualcomm `dp_rx_udp_pkt` -> Quest-`wlan0` attribution question**.
- Runtime/WiVRn code changes: **none; docs/tools only relative to the validated runtime base**.
- Exact branch tool wiring: **verified at tool head `03907c417ef38aaaf5702545aa01bf02310dc80e` before this documentation-only commit**.
- User-machine dry generated-artifact audit: **not yet executed after the final changes**.
- User-machine reducer self-test: **not yet executed after the final changes**.
- Runtime/headset validation: **not yet executed**.

The next local action is allowed to proceed only if the runner's automatic compile, self-test, dry generated-artifact audit, SHA-256 regeneration check, and normal capture preflight all pass before the user enters the workload.
