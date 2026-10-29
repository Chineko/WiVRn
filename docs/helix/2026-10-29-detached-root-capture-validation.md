# Helix detached Quest capture validation — 2026-10-29

## Failure evidence

The original detached preflight did not create a PCAP. The preserved Quest-side artifacts showed:

- PID file existed;
- stderr file existed and was empty in the first harness failure;
- PCAP file did not exist;
- a direct reproduction of the old detached launch form created PID/error files as `shell:shell` and tcpdump failed with `socket: Operation not permitted`.

This established that the old detached launch did not preserve the root execution context required for packet capture.

## Corrected invocation evidence

A direct device test used the remote command form:

`adb shell "su -c '<compound detached command>'"`

The resulting evidence was:

- `id` reported `uid=0(root)` with Magisk context;
- detached tcpdump PID/error/PCAP files were owned by `root:root`;
- tcpdump reported `wlan0`, link type `EN10MB (Ethernet)`;
- one packet was captured;
- kernel capture drops were zero.

This validates the corrected detached-root command form on the Quest used for Helix testing.

## Applied implementation change

Both detached tcpdump launch sites now use the device-proven remote-root quoting form:

- detached preflight capture;
- actual blackout capture.

The related PID check/stop commands and compound Quest-side diagnostic commands were normalized to the same remote-root grouping so the detached process lifecycle is not split across different quoting semantics.

The preflight now also verifies that the Quest PCAP actually exists and is nonempty before attempting retrieval/parsing. If not, tcpdump stderr is emitted and the harness stops before runtime validation.

## Local/function audit

Checked:

- launch command preserves the complete compound command under `su -c`;
- `$!` is evaluated on the Quest root shell, not by the host shell;
- preflight process exit is no longer treated as proof of successful capture;
- PCAP existence is a separate explicit gate;
- tcpdump stderr is surfaced on missing-PCAP failure;
- actual capture uses the same device-proven launch pattern;
- PID stop/check operations use the same root grouping;
- host capture and host sampler failure gates remain unchanged;
- no WiVRn runtime source was modified.

## Whole-system audit

The corrected design still preserves the intended experiment properties:

- Quest tcpdump is launched locally and detached before `CAPTURE ARMED`;
- no PCAP data is streamed over ADB during the workload;
- the ADB setup command exits before the workload begins;
- Quest PCAP retrieval occurs only after capture is stopped;
- preflight exercises detached launch, actual packet capture, local file creation, root retrieval, and PCAP readability before VR;
- failures before `CAPTURE ARMED` remain setup failures and must not trigger a headset workload;
- dual-PCAP evidence remains limited to the declared host-capture -> Quest-wlan attribution boundary.

## Status

The corrected command form has been validated directly on the Quest. The updated full harness has not yet passed its end-to-end preflight after this change. Therefore the next permitted action is a preflight retry only; runtime/VR validation begins only if the harness reaches `CAPTURE ARMED`.
