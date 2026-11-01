# Exact peak/input correlation

Failure class: run 06 recovery passed but the right-eye encoded P-frame peak
78,379 bytes exceeded the unchanged 75,898.75-byte traffic gate. Encoder and
sender agree on frame 24678; input identity was not recorded. Prior full failure
audits are in the saved 2026-11-01 checkpoint. No causal repair is justified yet.

This diagnostic joins the peak's selected projection-layer timestamp to the exact
application submission. Monado's frame-end path converts XrTime to host monotonic
nanoseconds before storing the projection layer timestamp. The stimulus uses the
runtime's XR_KHR_convert_timespec_time conversion, not a wall-clock estimate.
The compositor carries the selected single projection layer timestamp with its
two-slot image to the existing encoding thread. NVENC retains the source timestamp
and previous encoded source timestamp when a new maximum is observed; teardown
logs them with exact peak frame identity. Multi-layer/unmapped inputs yield zero
and cannot pass source correlation.

Stimulus timestamps are collected only after successful xrEndFrame and dumped
after production. Storage is bounded by the existing maximum 162001 submissions
(about 1.3 MiB timestamps). Levels are derived from the same immutable plan and
same formula as the actual copy offsets. No per-frame server logging or protocol
change is introduced. Source context is written/read only by the encoding thread;
image-slot ownership follows existing producer/consumer synchronization. Peak state
is read after encoder-thread join. No new worker, payload modification or queue.

Reducer joins exact timestamps and exact peak frame; rejects duplicates, absent
inputs, invalid levels and reversed order. It reports the current and previous
encoded source levels. Repeated use of one source is permitted; proximity-based
matching is forbidden. Correlation is a separate diagnostic gate, not a substitute
for the full exact MediaCodec canary chain or traffic calibration. Historical
results are retained; older captures without this trace cannot satisfy the new
source gate and are not rewritten.

Rule 40: a matched transition establishes selected-input identity, not why NVENC
produced a large frame. Head pose, compositor sampling, reference state and rate
control may still contribute. No content, seed, bitrate, plan or acceptance threshold
changes. Pixel cleanliness remains NOT_ESTABLISHED. Success for this slice is
exact both-eye peak/input correlation; calibration may still fail independently.

Before runtime: exact committed source, full private builds and independent seals,
full Audit A/B of the entire runner/transport/decoder/capture/reduction path, source
timestamp conversion checks, and reserved awake Quest/LAN prerequisites are required.
Previous runtime gate remains CLOSED until those checks pass.
