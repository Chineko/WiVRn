# Helix FEC viability gate — 2026-10-28

## Purpose

Before adding forward-error-correction bandwidth or a new erasure-code dependency, measure whether the packet-loss bursts observed on Quest 3 are short enough in server-send time for same-path FEC to plausibly repair them before the frame deadline.

This is a decision gate, not a FEC implementation.

## Evidence motivating the gate

The retransmission torture run established two separate classes of failure:

- host frame-production gaps, visible as server-side `helix_note_frame_gap` events
- receiver-observed missing UDP sequence positions, which cannot be explained by unsent host frames because packet sequence numbers are allocated only for attempted UDP video sends and the run recorded zero initial send errors

The receiver observed 12 forward sequence-gap events and every event was larger than eight packet positions.

The decoder diagnostic summaries also reported 36 incomplete-frame events across the two main streams, of which 31 were zero-shard events. That means ordinary frame-local FEC sent adjacent to a frame is not automatically a good fit: when the Quest receives no shard from a frame, its parity is exposed to the same delivery blackout unless redundancy is separated enough in time to survive it, and that separation is constrained by the decode deadline.

This does not prove FEC is ineffective. It proves that packet-count loss alone is insufficient to choose a FEC code or overhead ratio.

## Direct question to answer

For each receiver-observed forward sequence gap:

1. when did the server send the first missing sequence position?
2. when did it send the last missing sequence position?
3. how many source frames and shard positions did the missing range span?
4. was the missing range fully present in the bounded server cache when the report arrived?
5. how long after the last missing send did the server receive the client's gap report?

The primary metric is the server-send time span of the missing sequence range.

## Minimal instrumentation

### Sender

Extend each existing bounded RTX cache entry with the monotonic timestamp at which the original UDP send was attempted.

Do not create a second packet-history structure.

### Receiver

When the existing per-stream sequence tracker observes a forward gap, send one reliable control report containing:

- stream index
- first missing packet sequence
- missing packet count
- packet sequence that exposed the gap
- frame index of the packet that exposed the gap

This is one report per gap event, not one report per missing packet.

The report must not request recovery and must not delay normal packet handling.

### Server

Use the existing encoder registry and RTX cache to map the report back to source packets.

Record one event line and aggregate summary counters for:

- reports received
- reported missing packet positions
- fully mapped / partially mapped / unmapped reports
- missing-range send span in microseconds
- frame span of the missing range
- report delay from the last missing send to report receipt
- histogram of send span: `<1 / 2 / 5 / 10 / 20 / >20 ms`
- histogram of frame span: `1 / 2 / 3 / 4 / >4 frames`

Do not log one line per packet.

## Flaw and bottleneck checks

Before runtime validation, verify:

1. no unbounded state is added; reuse the 512-entry RTX cache
2. the report handler cannot hold a global registry lock across slow I/O
3. cache inspection does not block fresh `SendData` long enough to disturb the 50 us pacer
4. timestamps use one server monotonic clock domain and are not compared directly with Quest clock values
5. report traffic uses the existing reliable control path and remains negligible at the observed event rate
6. no new dependency is introduced
7. no FEC/parity bandwidth is added in this slice
8. protocol-version hashing continues to protect mismatched builds
9. RTX behavior remains unchanged
10. host frame-production gaps remain a separate metric and are not counted as network loss

## Decision gate

After one representative runtime session:

- If most missing ranges were transmitted over a short window that still leaves realistic decode-deadline headroom, proceed to a bounded FEC design sized to the measured burst duration and packet count.
- If most missing ranges span multiple frame periods or tens of milliseconds, do not add enough static FEC overhead to cover them blindly. Prioritize prevention/adaptation or a different recovery architecture.
- If the result is mixed, target FEC only at the short recoverable class and keep the long-blackout class separate.

Do not select Reed-Solomon parameters, parity percentage, interleave depth, or a new library before this gate is measured.

## Success condition

The slice succeeds when a single client/server run can classify observed UDP loss bursts by exact source send-time span and frame span without materially changing streaming behavior.
