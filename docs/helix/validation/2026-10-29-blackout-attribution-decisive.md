# Helix shared-path blackout attribution — decisive paired capture, 2026-10-29

## Runtime and scope

- Branch: `helix-blackout-attribution`
- Capture tooling commit recorded by run: `4dd055978709c1caa5fcf1dae061e798a3a5c3b1`
- Runtime source base: `ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a`
- Attribution scope: host packet-capture point -> Quest `wlan0` packet-capture point
- Host: `192.168.0.44` via `enp14s0`
- Quest: `192.168.0.54` via `wlan0`
- Quest endpoint state: 6295 MHz, BSSID `02:6a:d2:79:19:10`, unchanged between before/after snapshots

## Capture integrity

The reducer marked the run `decision_capable=true`.

Capture statistics:

- host tcpdump: 5,118,814 packets captured, 0 packets dropped by kernel;
- Quest tcpdump: 1,499,624 packets captured, 0 packets dropped by kernel;
- both captures used `DLT_EN10MB` and 96-byte snaplen;
- coarse PC->Quest clock alignment used 1000 identical UDP packet fingerprints with MAD ~0.287 ms;
- local blackout-window alignment MAD was ~0.282 ms and ~0.316 ms;
- local normal-traffic PC->Quest match ratios were 99.3434% and 97.4676%;
- packet fingerprint duplicate ratios were 0 on both sides for both decision windows.

The host capture continued after the intended capture interval because teardown later hit an interactive sudo problem. The reducer bounded analysis to the metadata capture interval; the decisive windows are well before teardown, and the Quest capture covers them completely. This teardown defect does not change the paired-packet result for the selected windows.

## Reproduced loss events

The reducer found 15 current-run Helix gap events merged into two decision windows.

The dominant synchronized incident occurred near 15:41:37 local time:

- stream 1: 46 missing sequence positions over 10.586 ms / 2 frames;
- stream 0: 43 missing sequence positions over 13.529 ms / 2 frames;
- later same-incident gaps included 4, 2, 2, 18 and 30 missing positions.

All listed gap mappings were `full`.

## Paired packet-capture result

Packet fingerprints were compared directly between host and Quest captures after local per-window clock alignment.

For the dominant first phase of the 15:41:37 incident, the host capture contains a contiguous run of 90 UDP datagrams from approximately 15:41:37.368413 to 15:41:37.386609, spanning ~18.196 ms. None of those 90 packet fingerprints appears anywhere in the reduced Quest capture.

The two primary reconstructed Helix loss intervals align with this run:

- stream-1 46-position interval: 69 host UDP datagrams in the reconstructed interval; 0 matching Quest packet fingerprints;
- stream-0 43-position interval: 66 host UDP datagrams in the reconstructed interval; 0 matching Quest packet fingerprints.

A later same-incident host run of 48 UDP datagrams from approximately 15:41:37.436193 to 15:41:37.447181, spanning ~10.988 ms, is likewise absent from the Quest capture and overlaps the later reported Helix gaps.

Normal host traffic immediately before, between, and after these missing runs does match the Quest capture. Some packets after the blackout are observed at Quest with tens of milliseconds of additional delay relative to the local baseline, but the packet fingerprints from the decisive missing runs never appear in the retained Quest window.

This is direct paired-capture evidence that the loss happened after the host capture point and before the Quest `wlan0` capture point.

## Counter and load cross-checks

Host qdisc/link counters over the run:

- `fq_codel`: 0 drops, 0 overlimits;
- host link: 0 TX errors, 0 TX drops, 0 carrier errors/collisions;
- host softnet sampled around both decision windows: 0 drops and 0 time-squeeze increments;
- host NIC statistics show no TX error counter increase.

Quest counters:

- `wlan0`: 0 RX errors and 0 RX drops before/after;
- UDP `RcvbufErrors`: 1318 -> 1318;
- UDP `InErrors`: 1318 -> 1318;
- UDP `SndbufErrors`: 0 -> 0.

Host load/traffic sampling shows the first small-loss window coincided with elevated host RX traffic, but the dominant 15:41:37 blackout did not require the same RX spike. Therefore elevated host WAN/download traffic is not established as a necessary condition for the dominant blackout.

## Evidence-proportional conclusion

Direct evidence supports all of the following:

1. the Helix-reported missing packet positions correspond in time to UDP datagrams visible at the host capture point;
2. the same datagrams are absent from the Quest `wlan0` capture;
3. normal traffic surrounding the blackout correlates strongly between host and Quest captures;
4. neither capture reported kernel packet drops;
5. aggregate host qdisc/NIC and Quest UDP-buffer counters do not explain the missing runs;
6. the dominant loss therefore occurs somewhere between the two capture points.

The strongest justified boundary statement is:

> The dominant reproduced blackout occurs after the host packet-capture point and before the Quest `wlan0` packet-capture point.

This excludes WiVRn userspace send failure, Quest UDP socket overflow, WiVRn receive/decrypt/dispatch after `wlan0`, and decoder-side causes for this dominant packet-loss event.

It does **not** distinguish among the remaining lower-path possibilities: host lower driver/NIC behavior below the capture hook, wired link/router/AP behavior, RF/6 GHz transmission loss or buffering, or Quest Wi-Fi firmware/driver behavior below the `wlan0` packet-capture hook.

Do not claim that RF or the AP is the exact drop point from this run alone.

## Engineering implication

The shared-path attribution milestone is closed at the host-capture -> Quest-wlan boundary. Further decoder tuning, reorder-grace tuning, and ordinary selective RTX tuning are not justified as primary responses to this failure mode.

Any Helix-side mitigation should target multi-frame burst erasure resilience rather than a single missing packet or single-frame assumption. The observed dominant loss includes ~11-18 ms packet-erasure runs synchronized across both video streams, and prior runtime evidence already showed frame-local one-XOR FEC and deadline-bound RTX are insufficient for this envelope.
