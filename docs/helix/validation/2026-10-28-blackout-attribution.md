# Helix shared-path blackout attribution — 2026-10-28

## Runtime

Branch: `helix-blackout-attribution`
Capture harness commit recorded by the run: `7c6064084d836e2762d65d091e0c88ef2315d0d7`
Quest: rooted Meta Quest 3, Wi-Fi 6, 6295 MHz, 2401 Mbps link rate.

## Reproduction

A long avatar load/unload stress run reproduced eight Helix gap reports grouped into three synchronized blackout windows.

Main synchronized windows:

- ~20:11:08.934: stream 0 lost 44 positions over 21.847 ms / 3 frames; stream 1 lost 40 over 11.479 ms / 2 frames.
- ~20:22:46.034: stream 0 lost 82 over 33.883 ms / 4 frames; stream 1 lost 67 over 23.075 ms / 3 frames.
- ~20:24:39.457: stream 0 lost 92 over 34.264 ms / 4 frames; stream 1 lost 95 over 34.379 ms / 4 frames.

Two additional same-frame gaps of 16 and 20 positions appeared shortly after the first main event.

## PC-side capture result

The host interface capture completed successfully with 5,544,704 packets captured and zero capture drops. The active WiVRn UDP flow was 192.168.0.44:9757 -> 192.168.0.54:34818.

Using the server gap-report receive timestamp minus the recorded Helix report delay and mapped send span to reconstruct each sender-side loss interval, the host capture contained:

- first synchronized interval: 83 outbound UDP datagrams versus 84 combined missing Helix sequence positions;
- second synchronized interval: 140 outbound UDP datagrams versus 149 combined missing positions;
- third synchronized interval: 171 outbound UDP datagrams versus 187 combined missing positions.

This is strong evidence that UDP traffic continued through the host packet-capture point during the exact intervals later reported missing by the Quest. Because the capture is below WiVRn userspace but does not itself prove physical wire airtime, the result moves the failure boundary past the application send loop but does not by itself prove AP/wireless loss.

Host network counters over the run:

- `fq_codel`: 0 dropped, 0 overlimits; requeues increased but no backlog remained.
- Ethernet link: 0 TX errors, 0 TX drops, 0 carrier errors/collisions.
- NIC statistics: 0 `tx_errors`, 0 `tx_aborted`, 0 `tx_underrun`.

These counters show no aggregate evidence of host qdisc/NIC failure, but they are not per-blackout timestamps and therefore do not fully exclude a transient driver/NIC event.

## Quest-side counters

Quest `wlan0` before/after counters remained at 0 RX errors and 0 RX dropped.

Quest UDP SNMP counters:

- `RcvbufErrors`: 1299 -> 1299
- `InErrors`: 1299 -> 1299
- `SndbufErrors`: 0 -> 0

Therefore the reproduced blackouts were not accompanied by new kernel UDP receive-buffer overflow errors during the run.

The active Wi-Fi link remained associated on 6295 MHz, Wi-Fi 6, reported 2401 Mbps link speed, with RSSI improving from roughly -49 dBm to -39 dBm in the before/after snapshots. These endpoint snapshots do not exclude sub-second RF/AP events.

## Quest interface capture limitation

The Quest-side `tcpdump` process failed to open the capture socket:

`wlan0: You don't have permission to perform this capture on that device (socket: Operation not permitted)`

The logcat audit records show tcpdump-related SELinux denials marked `permissive=1`, so the failed packet capture cannot be treated as evidence of missing packets at the Quest interface. The next capability check should test tcpdump while retaining root privileges (for example `-Z root`) before any additional VR run.

## Decoder cross-check

End-of-run decoder summaries remained healthy:

- stream 1: 84,363 submitted / 84,353 decoded, 0 qualified stalls, 0 recoveries, 0 flushes, average ~4.344 ms, max ~18.723 ms;
- stream 0: 84,365 submitted / 84,357 decoded, 0 qualified stalls, 0 recoveries, 0 flushes, average ~4.453 ms, max ~19.829 ms.

This run does not reopen the decoder as the primary failure class.

## Evidence-proportional conclusion

Direct evidence now supports:

1. the blackouts are synchronized across both main video streams;
2. they span roughly 11–34 ms and up to four frame generations;
3. WiVRn userspace continued sending through the mapped intervals;
4. outbound UDP traffic was visible at the PC network capture point during those same intervals;
5. the host qdisc/NIC aggregate counters reported no drops/errors;
6. the Quest did not accumulate UDP receive-buffer errors during the run.

The strongest justified boundary statement is therefore:

> The dominant reproduced loss occurs after the WiVRn application send loop and is not explained by host qdisc drops, host NIC error counters, or Quest UDP receive-buffer overflow. The remaining unresolved boundary is between the host's lower transmit path and the Quest's pre-socket receive path, including transient NIC/driver behavior, AP buffering/drop, the 6 GHz wireless hop, and Quest Wi-Fi driver/firmware receive behavior.

Do not claim that the wireless hop itself is proven as the exact drop point until Quest-side interface capture or equivalent driver/kernel telemetry succeeds.

## Next step

Before another VR run, make Quest interface capture work in a short capability test. If it succeeds, one more ~5 minute avatar stress run with simultaneous PC/Quest capture should directly distinguish:

- packets present in PC capture but absent at Quest interface -> loss before/at Quest NIC (PC NIC/AP/wireless path), versus
- packets present at Quest interface but absent from WiVRn sequence telemetry -> Quest kernel/socket/userspace receive path.

No further FEC, RTX, pacing, or decoder tuning is justified before that boundary is closed.
