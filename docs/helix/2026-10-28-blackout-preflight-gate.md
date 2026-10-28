# Helix blackout attribution preflight gate — 2026-10-28

## Purpose

This addendum closes the remaining pre-run validity gaps found after the full blackout-harness audit. It does not change WiVRn runtime behavior.

## Added gate

`tools/helix-blackout-run.sh` is now the only user-facing entry point for the next attribution run.

Before the harness can print `CAPTURE ARMED`, the gate verifies:

- capture-script Bash syntax;
- reducer Python syntax without creating a `__pycache__` artifact;
- runtime source remains equivalent to validated runtime base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a` outside docs/tools;
- no tracked working-tree changes are present;
- the existing dashboard/server executables are present;
- the desktop server binary contains the expected `ffdc6bb7` runtime identity;
- exactly one ADB device is connected;
- ADB shell has effective root;
- the installed Quest package reports a version containing `ffdc6bb7`;
- any already-running dashboard/server instance from the build tree is stopped so an unknown in-memory build cannot be reused;
- Quest interface, Quest IP, host IP, and Quest tcpdump are discoverable;
- a root-created one-packet Quest PCAP can be pulled through ordinary ADB and read successfully on the host;
- that pull/capture preflight has a hard timeout and therefore cannot hang indefinitely before a VR run.

If any gate fails, the user must not start the headset workload. The failure occurs before `CAPTURE ARMED` and should be treated as a tooling/setup failure rather than a runtime validation result.

## Full audit conclusions retained

The underlying capture/reducer design remains the one documented in `2026-10-28-blackout-harness-audit.md`:

- high-volume Quest PCAP and logcat stay local on the Quest during the workload;
- paired packet captures are aligned from matching encrypted UDP traffic rather than assumed wall-clock equality;
- current-run gap events are bounded by capture timestamps;
- sender-side loss windows are reconstructed from `report_delay` and `send_span`;
- live network/socket state is sampled before server shutdown;
- both captures must report zero kernel capture drops for packet absence to support path attribution;
- original large captures remain local and only reduced decision-relevant windows are uploaded.

## Repository audit

A compare against runtime base `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a` shows the attribution branch changes only files under `docs/` and `tools/`. No WiVRn runtime source is changed by this diagnostic slice.

A redundant packet-correlation helper briefly introduced during the resumed audit was removed immediately; the established reducer remains the single correlation implementation.

## Remaining limitations

Passing preflight proves setup capability and identity, not the causal result. The next run is decision-capable only if:

1. a representative blackout is reproduced;
2. host and Quest captures cover the reconstructed event window;
3. both captures report zero kernel drops;
4. ordinary nearby traffic correlates across the two capture points strongly enough to make packet absence meaningful.

The final analysis must still keep the boundary proportional to evidence. Packet absence at Quest `wlan0` can localize loss to somewhere between the host capture point and the Quest packet-capture point; it does not by itself distinguish PC NIC/driver, wired/AP path, RF, or Quest firmware/driver below that capture point.
