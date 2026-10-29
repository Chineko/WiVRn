# Helix standalone synthetic UDP baseline — 2026-10-29

## Question

Can the Quest reproduce the measured stall/loss signature with WiVRn entirely out of the runtime path?

This experiment is intentionally narrower than root-cause attribution. It sends a deterministic UDP burst pattern from the PC to a standalone native Quest receiver. WiVRn server/dashboard/client are stopped, and the first baseline run uses no tcpdump.

A positive result would show that the stall/loss class exists without WiVRn. A negative result would not prove WiVRn causes the blackout, because synthetic traffic cannot reproduce every codec, socket, AP, RF, or device-state property of a live VR session.

## Traffic pattern

Default pattern:

- 90 Hz burst cadence;
- 56 UDP datagrams per burst;
- 50 microseconds between datagrams inside a burst;
- 1432-byte UDP payloads;
- 300-second sender workload.

The 1432-byte payload default is based on the decisive paired blackout capture, where the dominant PC->Quest packets were 1474-byte Ethernet frames (14-byte Ethernet + 20-byte IPv4 + 8-byte UDP + 1432-byte payload).

The 56-packet burst default yields 5,040 packets/s, close to the roughly 4.4–5.0 kpacket/s density observed inside the dominant blackout packet runs. It is a starting approximation, not a claim that all live WiVRn traffic has this exact shape.

Environment variables can change duration, cadence, burst size, spacing, payload size, and port without source edits.

## Runtime isolation

The runner:

- stops known desktop WiVRn dashboard/server processes;
- force-stops both known Quest WiVRn package names;
- refuses to run if Quest tcpdump is already active;
- refuses to run if a host tcpdump matching the Wi-Fi/UDP capture pattern is active;
- refuses wireless ADB because that would share the network path under test;
- requires the Quest to start on 6 GHz and records frequency/BSSID before and after;
- performs no ADB command while the sender workload is active.

The Quest receiver is a separate native executable pushed to `/data/local/tmp`. It does not load or invoke WiVRn runtime code.

## Instrumentation

Every sender packet contains:

- global sequence number;
- burst number;
- packet index;
- actual host `CLOCK_REALTIME` timestamp immediately before `sendto`.

The host also writes a compact binary send log containing the actual timestamp and send result for every sequence. This allows a missing Quest sequence to be checked against an actual successful host send instead of an assumed schedule.

The Quest receiver:

- uses a normal UDP socket;
- requests a large socket receive buffer;
- enables `SO_RXQ_OVFL`;
- enables kernel receive timestamps with `SO_TIMESTAMPNS`;
- records sequence, sender timestamp, kernel receive timestamp, packet index, and cumulative socket-drop count.

Kernel receive timestamps are required so receiver userspace scheduling or buffered file writes cannot manufacture a false tens-of-milliseconds "network delay" signature.

## Reducer

The reducer independently verifies:

- complete sender-log coverage;
- zero sender send failures/short sends;
- receiver log format and sequence bounds;
- `SO_RXQ_OVFL` availability;
- kernel timestamp availability and completeness;
- zero socket kernel drops for a decision-capable run;
- duplicate and out-of-order receiver records;
- contiguous missing sequence runs;
- actual sender timestamp span of each missing run;
- local pre-gap versus post-gap relative-delay change.

Absolute one-way latency is not claimed because host and Quest clocks are not synchronized. The relevant stall metric is the local change in `(Quest kernel receive timestamp - host send timestamp)` immediately before versus immediately after a loss run. Constant clock offset cancels, and short-window comparison limits clock-drift sensitivity.

A "WiVRn-like candidate" is descriptive, not a root-cause verdict. Current threshold:

- at least 20 contiguous missing packets;
- actual sender span at least 8 ms;
- median relative delay of the next 32 received packets at least 10 ms higher than the median of the preceding 32 received packets.

These thresholds are deliberately below the measured dominant event (90 missing host-observed packets over 18.196 ms with surviving traffic tens of milliseconds late).

## Audit A — local/function audit

Validated locally before device use:

- `tools/helix-net-test.c` compiles with `cc -O2 -std=c11 -Wall -Wextra -Werror`;
- sender and receiver complete a loopback run with zero loss;
- Linux reports `SO_RXQ_OVFL` and kernel timestamp support and no missing timestamps;
- reducer parses the native binary logs and passes a zero-loss loopback run;
- an injected 30-packet / ~11.7 ms hole plus a 20 ms post-gap timestamp shift is detected as a candidate;
- runner passes Bash syntax validation;
- reducer passes Python compilation.

Function-level failure handling:

- malformed arguments and impossible burst occupancy fail before workload;
- send failures are recorded and make the reducer non-decision-capable;
- socket queue overflow is an integrity blocker rather than path-loss evidence;
- missing kernel timestamps are an integrity blocker;
- raw evidence is retained locally even if reduction fails;
- no sudo credential lifetime is involved.

## Audit B — whole-system audit

Engineering decision supported by a positive run:

> The measured stall/loss class can occur on the PC->Quest network/receive path without any WiVRn runtime process participating.

A positive run does **not** distinguish host NIC, wired/router/AP, RF, Quest Wi-Fi firmware/driver, or the standalone Quest socket path.

A negative run does **not** prove WiVRn is responsible. Synthetic traffic differs from live VR state and may fail to trigger a state-dependent fault.

Observer effects:

- tcpdump is excluded from the first baseline because the paired capture showed Quest `wlan0` entering promiscuous mode;
- receiver disk logging is low bandwidth but still an observer;
- kernel timestamps prevent receiver logging stalls from being misclassified as network delay;
- `SO_RXQ_OVFL` prevents receiver socket overflow from being misclassified as path loss;
- wireless ADB is rejected so ADB traffic does not share the path during the workload.

Clock/correlation:

- host send timestamps and Quest kernel receive timestamps use realtime clocks with unknown offset;
- only local pre/post delay changes are used for the stall signature;
- missing-run spans use the host's actual per-packet send timestamps.

Remaining limitation:

This baseline has only one wireless endpoint and therefore cannot remove the PC NIC/router/AP side of the boundary by comparison with a simultaneous wired receiver.

## User workflow

After pulling the commit:

```fish
cd ~/WiVRn
git pull --ff-only
bash tools/helix-net-test-run.sh
```

The runner builds both tiny binaries, deploys the Quest receiver, runs the bounded workload without WiVRn/tcpdump, retrieves evidence, reduces it, and prints a small `-reduced.tar.gz` bundle for analysis.
