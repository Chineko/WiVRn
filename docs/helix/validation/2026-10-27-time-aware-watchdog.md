# Helix 0.1 time-aware watchdog validation — 2026-10-27

## Purpose

This record preserves the runtime evidence used to promote the Helix decoder watchdog from the count-only experiment to the time-aware watchdog behavior. It is intended for future comparison and for resuming development without relying on chat history.

## Tested build

- Repository: `Chineko/WiVRn`
- Branch under test: `helix-time-aware-watchdog`
- Tested code commit: `d68928756249da35b7343da7cc3ebc87d65d515e`
- Parent validated diagnostics commit: `67a7f526f57d02ec66c23679dc65dbfc95124f6c`
- Diagnostics marker: `time-aware-v1`
- Headset: Meta Quest 3
- Codec in tested streams: HEVC
- Primary eye streams: 1280x1344 @ 90 fps
- Test date: 2026-10-27

## Watchdog behavior under test

The previous watchdog declared a decoder stall when five complete frames had been submitted without decoded output. Runtime evidence showed that this was too aggressive because a long upstream starvation interval could be followed by five fresh frames arriving in a burst.

The time-aware watchdog requires all of the following before qualifying a decoder stall:

- at least 5 complete pending frames;
- oldest pending frame age >= 35 ms;
- time since last MediaCodec output >= 35 ms.

MediaCodec output resets the watchdog pending counter. Five-frame candidates that do not satisfy the age gate are logged as `action=diagnostic_only_wait` and do not request recovery.

The 35 ms threshold is an experimental, reversible threshold chosen because the previous long run measured normal submit-to-MediaCodec output latency around 4–5 ms average and roughly 20–25 ms maximum.

## Previous count-only diagnostics baseline

Previous long Quest run on `67a7f526f57d02ec66c23679dc65dbfc95124f6c`:

- stream 0: submitted 159738, decoded 159695, watchdog stalls 47, recovery requests sent 47, flushes 0;
- stream 1: submitted 159722, decoded 159680, watchdog stalls 34, recovery requests sent 34, flushes 0;
- combined watchdog events: 81;
- 58 distinct incident episodes when events were grouped in time;
- 23 of those episodes involved both primary streams within 50 ms;
- many events had five pending frames only about 4–10 ms old;
- some events fired less than 1 ms after a MediaCodec output;
- normal decoder latency remained about 4.5 ms average with maxima around 22–25 ms;
- complete/network delivery interruptions and burst arrivals were therefore being misclassified as decoder stalls.

This baseline is the comparison point for the time-aware run below.

## Time-aware validation result

### Stream 0

- submitted: 151070
- decoded: 151022
- MediaCodec outputs: 151023
- watchdog candidates: 18
- deferred candidates: 18
- qualified watchdog stalls: 0
- recovery requests sent: 1
- recovery requests suppressed: 0
- successful recoveries: 1
- flush attempts/successes/failures: 0/0/0
- decode latency average: 4270 us
- decode latency max: 20879 us
- submit -> MediaCodec average: 4064 us
- submit -> MediaCodec max: 20697 us
- MediaCodec output-gap max: 181147 us
- complete-frame interval average/last/max: 11118 / 13223 / 181963 us
- MediaCodec release -> AImageReader average/max: 42 / 2179 us
- image processing average/max: 85 / 2746 us
- errors async/input/overflow/output/image: 0/0/0/0/1
- network complete/incomplete/zero/missing/old/jumps/skipped: 151070/50/43/91/0/25/67
- frame assembly last/max: 301 / 76779 us

### Stream 1

- submitted: 151060
- decoded: 151009
- MediaCodec outputs: 151012
- watchdog candidates: 17
- deferred candidates: 17
- qualified watchdog stalls: 0
- recovery requests sent: 0
- recovery requests suppressed: 0
- successful recoveries: 0
- flush attempts/successes/failures: 0/0/0
- decode latency average: 4156 us
- decode latency max: 16785 us
- submit -> MediaCodec average: 3971 us
- submit -> MediaCodec max: 17901 us
- MediaCodec output-gap max: 180287 us
- complete-frame interval average/last/max: 11119 / 11496 / 179700 us
- MediaCodec release -> AImageReader average/max: 36 / 1905 us
- image processing average/max: 76 / 1556 us
- errors async/input/overflow/output/image: 0/0/0/0/0
- network complete/incomplete/zero/missing/old/jumps/skipped: 151060/52/47/50/0/25/72
- frame assembly last/max: 259 / 68557 us

## Watchdog promotion result

Combined result:

- 35 watchdog candidates;
- 35 candidates deferred as premature;
- 0 qualified watchdog stalls;
- 0 watchdog-triggered IDRs;
- 0 watchdog-triggered flushes;
- no recovery loops;
- normal decoder latency preserved.

This is a strong validation of the time-aware gate. The previous count-only detector converted burst arrivals into false decoder failures. The new gate correctly leaves fresh pending frames alone.

Representative candidate:

- stream 0, frame 30428;
- five pending complete frames;
- oldest pending frame only 2645 us old;
- 179567 us since MediaCodec output;
- most recent complete-frame interval only 2052 us;
- action: `diagnostic_only_wait`.

This shows the important failure mode clearly: a long output/input starvation interval is followed by a fresh burst. The decoder has not had 35 ms to process those newly submitted frames, so recovery must not fire.

## Upstream starvation evidence

The final summaries strongly align complete-frame delivery gaps with MediaCodec output gaps:

- stream 0 complete-frame interval max: 181963 us;
- stream 0 MediaCodec output-gap max: 181147 us;
- stream 1 complete-frame interval max: 179700 us;
- stream 1 MediaCodec output-gap max: 180287 us.

At the same time, once frames were submitted to MediaCodec, normal decode remained fast:

- stream 0 submit -> MediaCodec average/max: 4064 / 20697 us;
- stream 1 submit -> MediaCodec average/max: 3971 / 17901 us.

Interpretation: the largest output gaps are primarily explained by MediaCodec not receiving complete frames for similar periods, not by MediaCodec spending roughly 180 ms decoding an already-submitted frame.

This moves the main investigation boundary upstream of MediaCodec toward frame delivery, assembly, pacing, reorder behavior, receive scheduling, and related Quest-side transport timing.

## Single non-watchdog recovery

There was exactly one recovery request in the time-aware run and it did not come from the watchdog.

At 18:04:36:

- `AImageReader_acquireLatestImage` returned MediaCodec error `-30001`;
- Helix classified an image-output failure on stream 0;
- Helix requested an IDR at frame 54866;
- diagnostic action: `idr_sent`, reason `image output processing failed`;
- decoder output resumed on frame 54867 after 6451 us;
- no flush was required;
- the error did not recur in the run.

This isolated image-output error does not block watchdog promotion.

## Promotion decision

The decoder watchdog investigation is considered closed enough to continue Helix development.

Promotion gate status:

- false five-frame watchdog storm eliminated: PASS;
- watchdog IDR storm eliminated: PASS;
- normal decoder latency preserved: PASS;
- no new watchdog-related decoder errors: PASS;
- no flush/recovery loops: PASS;
- complete-frame timing identifies upstream starvation/burst behavior: PASS.

Keep the time-aware watchdog and its telemetry available for future regressions. Do not continue threshold tuning without new evidence.

## Next development focus

Move upstream according to the Helix roadmap:

1. delivery pacing;
2. short reorder handling;
3. transport resilience around complete-frame starvation/burst episodes;
4. later adaptive bitrate/FEC/RTX work according to the existing roadmap.

Do not return to decoder recreation unless runtime evidence shows IDR + flush are insufficient for a genuine decoder-output stall.

## Preserved incident data

All 35 time-aware watchdog candidate lines and the sole recovery action are preserved next to this report in:

`docs/helix/validation/2026-10-27-time-aware-incidents.log`

The raw Android log contained about 49k lines, most of which were unrelated tracking/runtime noise. The comparison-critical summaries and every watchdog/recovery incident are preserved in the repository instead of committing the full noisy log.
