# Helix retransmission validation — 2026-10-28

## Checkpoint

Branch: `helix-retransmission`

Committed audit-fix head: `436e9bd8e1aa40d4dde0c72cee52937a449d6b22`

Runtime build identifier printed by the server: `v26.9-145-gf6ceeca8`.

Important build-ID caveat: the corrected RTX working tree was rebuilt before `436e9bd8` was committed, so the embedded Git version remained `gf6ceeca8`. The Quest runtime log contains fields introduced only by the later audit fix (`recovered_frames` and `skipped_cross_frame`), which demonstrates that the tested binaries included the corrected source despite the stale embedded revision string. Future validation must commit first and then rebuild so the binary version exactly identifies the tested source.

## Test workload

Quest 3 over Wi-Fi 6E, with the PC connected by Ethernet.

The runtime workload was intentionally severe: VRChat in a world with roughly 60 people while moving around and repeatedly loading and unloading avatars. This was a torture test rather than an ordinary representative session.

## RTX design under test

- per-stream UDP packet sequence identity
- compact headset-to-server retransmission request keyed by `(stream_index, packet_sequence)`
- bounded 512-shard server cache per stream with owned payload memory
- retransmission preserves the original packet sequence and shard metadata
- explicit retransmission marker on the returned shard
- receiver only requests sequence positions provably belonging to the current observed frame
- ambiguous cross-frame gaps are skipped instead of guessed
- provisional 5 ms receiver-local display-time usefulness floor when that frame's deadline is known
- maximum 8 requested missing packets for one observed same-frame gap; larger missing sets are treated as burst-loss territory
- separate RTX and fresh-send telemetry
- recovered-frame counter increments only when a completed frame actually contained an accepted retransmitted shard

## Runtime results

Quest shutdown summaries:

- stream 0: `received=1806989`, `forward_gap_candidates=399`, `late_or_duplicate=0`, `unsequenced_control_or_fallback=12`, `highest=1807388`
- stream 0 RTX: `requests=0`, `arrivals=0`, `useful=0`, `late=0`, `recovered_frames=0`, `skipped_deadline=0`, `skipped_cross_frame=399`, `skipped_gap_cap=0`, `pending=0`, `gap_hist(1/2/3-4/5-8/>8)=0/0/0/0/6`
- stream 1: `received=1820545`, `forward_gap_candidates=411`, `late_or_duplicate=6`, `unsequenced_control_or_fallback=11`, `highest=1820950`
- stream 1 RTX: `requests=6`, `arrivals=6`, `useful=0`, `late=6`, `recovered_frames=0`, `skipped_deadline=19`, `skipped_cross_frame=386`, `skipped_gap_cap=0`, `pending=0`, `gap_hist(1/2/3-4/5-8/>8)=0/0/0/0/6`

Aggregate main-stream result:

- 810 forward missing sequence positions were observed during the session
- all 12 forward-gap events were in the `>8` packet histogram bucket
- 785 of the 810 forward missing positions were classified as ambiguous cross-frame portions of those bursts
- 19 same-frame positions were rejected by the usefulness deadline
- 6 retransmission requests were emitted
- all 6 were found in the server cache
- all 6 were retransmitted successfully
- all 6 arrived back at the Quest
- all 6 arrived after their target frame had ceased to be useful
- 0 frames completed because of RTX

The server confirmed the transport mechanism itself worked:

- stream 1: `requests=6`, `cache_hits=6`, `cache_misses=0`, `sent=6`, `rtx_bytes=8169`, `rtx_send_time(avg/max)=7/19us`, `rtx_send_errors=0`, `initial_send_errors=0`
- stream 0: `requests=0`, `cache_hits=0`, `cache_misses=0`, `sent=0`, `rtx_send_errors=0`, `initial_send_errors=0`

## Tail-loss accounting

Final original server packet sequences:

- stream 0: `1807413`
- stream 1: `1820981`

Highest sequence values observed by the Quest before shutdown:

- stream 0: `1807388`
- stream 1: `1820950`

This exposes 25 stream-0 and 31 stream-1 sequence positions at the tail that cannot be discovered by forward-gap logic because no later packet exists to reveal them.

The final-sequence telemetry therefore closed a real observability gap and should be kept.

## Loss shape

The headline average loss rate is less important than its clustering in this run.

Counting original UDP sequence positions at the server gives approximately 3,628,394 positions across streams 0 and 1. Accounting for the six RTX duplicates, approximately 866 original positions were not observed by the Quest, or roughly 0.024%.

Despite the low average percentage, loss was concentrated in large bursts. Every observed forward gap was greater than eight packets, and most missing positions crossed a frame boundary. This is a poor fit for selective retransmission and a much better target for burst-loss recovery such as FEC.

## Pacing impact

RTX traffic itself was negligible: six retransmissions, 8,169 bytes total, with server send time averaging 7 us and peaking at 19 us.

Fresh-video pacing remained mechanically healthy under the torture workload:

- stream 0: `frames=86391`, `send_span(avg/max)=1041/6822us`, queue depth max 1, queue delay avg/max `8/3267us`
- stream 1: `frames=86387`, `send_span(avg/max)=1050/6457us`, queue depth max 2, queue delay avg/max `8/10826us`

There were several large 45–66 ms frame-production gaps and a small number of slow-send / sender-queue outliers during the extreme VRChat workload, but RTX did not create a persistent sender backlog or materially load the fresh-video path.

## Decoder observations

Decoder summaries remained consistent with the earlier conclusion that the ordinary MediaCodec path is healthy:

- stream 1: `submitted=86357`, `decoded=86340`, `watchdog_candidates=5`, `deferred=3`, `stalls=2`, `recovery_sent=2`, `recoveries=2`, `flush=0/0/0`, `latency_avg=4063us`, `latency_max=18825us`, MediaCodec errors all zero
- stream 0: `submitted=86366`, `decoded=86347`, `watchdog_candidates=6`, `deferred=4`, `stalls=2`, `recovery_sent=2`, `recoveries=2`, `flush=0/0/0`, `latency_avg=4256us`, `latency_max=20942us`, MediaCodec errors all zero

The corresponding diagnostic summaries again show large complete-frame delivery gaps alongside decoder-output gaps. No decoder flush was required.

## Interpretation

RTX Slice B is a successful negative result for the severe burst-loss failure class.

The complete request/cache/resend/arrival mechanism worked end-to-end, but it recovered zero frames. The tested failure pattern was dominated by large, cross-frame packet bursts rather than small isolated losses that RTX can cheaply repair before deadline.

Do not respond by tuning the provisional 5 ms threshold repeatedly, increasing the cache size, or running a retransmission-threshold sweep. The server path is already fast enough that these changes are unlikely to address the dominant failure class observed here.

RTX remains a useful cheap selective mechanism for isolated losses, but this test does not support making RTX the primary Helix recovery mechanism.

## Decision

Keep the bounded selective RTX implementation as a checkpoint, but stop RTX parameter tuning.

Next high-impact mechanism: FEC / burst-loss recovery.

The next FEC slice should:

1. target the observed multi-packet and cross-frame burst-loss failure class
2. preserve bounded latency and fresh-video priority
3. start with a small, measurable protection model rather than a large generic jitter buffer
4. include enough telemetry to measure protected packets, repair attempts, successful frame completion because of FEC, unrecoverable bursts, and bandwidth overhead
5. keep FEC and RTX telemetry separate so their value can be measured independently
6. avoid another decoder or reorder detour unless new evidence points there

Do not run another RTX-only headset session before implementing a materially different recovery mechanism.
