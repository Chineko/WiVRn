# Helix Quest radio one-run full re-audit after generated watchdog syntax failure

Date: 2026-10-29
Branch: `helix-blackout-attribution`

## Trigger

The previous one-run preflight failed before runtime because the exact generated capture script contained a Bash syntax error in the Quest trace watchdog command. The nested `sh -c` quoting produced an unexpected `(` in the generated artifact. No VR reproduction workload was started.

Per Rules 40-42, this failure triggered a full audit of the complete experiment rather than an affected-line-only patch review.

## Audit A — implementation / final artifact

Re-audited chain:

`top-level runner -> USB-detached generator -> radio patch -> exact generated capture artifact -> Bash syntax -> artifact audit -> runtime preflight -> observer startup -> detached workload -> teardown -> retrieval -> reducers -> archive`

Material checks:

- The watchdog no longer nests another `sh -c`; the rooted remote shell runs the watchdog subshell directly.
- The watchdog command's Bash syntax was independently checked in isolation.
- The exact generated artifact gate remains fail-closed and still runs `bash -n` after the radio patch is applied.
- The top-level runner now performs the exact generated-artifact dry audit before any Quest/ADB parser preflight.
- The dry-audited artifact SHA-256 remains the identity gate for the regenerated artifact that is allowed to execute.
- The actual-device `dp_rx_udp_pkt` parser compatibility gate remains required after static artifact validation.
- Host privileged capture/teardown remains noninteractive after the explicit pre-detach sudo refresh.
- Quest trace buffer readback, overwrite readback, selective event enable, watchdog, bounded detach/reconnect prompts, trace retrieval, per-CPU stats, and cleanup remain present.
- No ADB control remains inside the active USB-detached workload window.
- The workload itself is unchanged WiVRn/avatar reproduction; no pacing, bitrate, QoS, FEC, RTX, channel-width, or decoder changes are introduced.

## Audit B — whole-system question / evidence path

Question remains:

For a real WiVRn short-lag event where a packet is visible in the host PCAP but absent from the Quest `wlan0` PCAP, was that packet nevertheless observed at Qualcomm `wlan:dp_rx_udp_pkt`?

Evidence chain:

`host PCAP -> Quest Qualcomm dp_rx_udp_pkt trace -> Quest wlan0 PCAP`

System gates retained:

- matching validated desktop/server and Quest runtime identity
- USB-only setup/retrieval and zero ADB during workload
- same BSSID / 6 GHz endpoint consistency
- zero tcpdump kernel drops required by the base paired-PCAP reducer
- trace parser compatibility proven on the actual Quest before runtime
- start/end trace synchronization markers
- trace format saved
- trace buffer stats saved
- local packet-clock/capture correlation required
- baseline driver visibility required before classifying missing-event packets
- enough missing-at-wlan packets required for an event to be decisive
- base paired-PCAP decision gate AND radio driver-trace gate must both pass for overall decision capability

The new radio layer is not permitted to override a failed base paired-PCAP integrity gate.

## Rule 40 status

### Direct evidence

- The previous attempt failed during dry generated-artifact syntax validation before the runtime workload.
- The failure was in watchdog command generation, not in the Quest radio tracepoint itself.
- The actual Quest `dp_rx_udp_pkt` parser preflight had passed before that dry-artifact failure.

### Supported inference

- The remaining experiment design is still capable of narrowing the downstream boundary if the final runtime produces a real mapped gap event and both integrity gates pass.

### Remaining ambiguity

- Runtime behavior of the corrected exact generated artifact is not yet validated on the user's machine.
- Trace observer overhead can perturb scheduling; trace stats and baseline driver visibility are therefore required before attribution.
- Absence at both `dp_rx_udp_pkt` and `wlan0` still leaves AP/RF/Quest radio/firmware/earlier-driver causes combined.

### Decision justified by the evidence

Permit one runtime validation attempt only after the dry generated-artifact gate passes. If the dry gate fails again, do not enter the headset workload. If the runtime completes, analyze the collected bundle before any further run.

## Scope freeze

No additional mechanism tuning or network changes are in scope for this validation. In particular, do not reopen pacing, bitrate, QoS, 160 MHz channel width, decoder behavior, FEC/RTX tuning, PC-to-router wiring, router rooting, or external sniffing without new contradictory evidence.
