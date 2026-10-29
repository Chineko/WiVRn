# Helix bounded time-diverse recovery — full Rule 40–42 audit

Date: 2026-10-29
Branch: `helix-bounded-time-diverse-recovery`
Parent: `helix-time-diverse-recovery` at `20616b623698e0d761450ad0e906fb35daf17877`
Prototype contract commit: `dac1bd7150562caa79fe05636858e4e89d03844f`
Implementation patch commit after initializer-order correction: `553fdad708622c247a2cb01edcd2f7ac7765c190`

## Scope

This audit covers the exact prototype described in `2026-10-29-bounded-time-diverse-recovery-prototype.md` and represented by `tools/helix-bounded-time-diverse-recovery.patch`.

The prototype is deliberately narrower than generic cross-frame FEC. It replays a complete, bounded NVENC reference-bearing frame once at the beginning of the following normal UDP frame, subject to a hard 48-shard cap and a 20% long-run fresh-payload budget.

It does not add a packet type, client buffer, jitter window, bitrate adaptation, pacing sweep, router control, or Quest lower-radio instrumentation.

## Audit A — local/function/source audit

### Source ownership and lifetime

The implementation adds only per-`video_encoder` scalar counters, one optional pending frame id, and helper methods. Replay payload is not copied into a second unbounded store: it reuses the existing bounded RTX cache, whose entries own the payload bytes and view/timing metadata.

The existing RTX cache limit remains 512 entries. A scheduled replay frame is limited to 48 shards, so an eligible frame cannot by itself exceed the cache. Replay is attempted exactly at the start of the next normal frame; it is not retained across arbitrary future frames.

### Eligibility and bounds

Time-diverse replay is enabled only when `settings.encoder_name == encoder_nvenc`, matching the actual encoder configuration used for the decisive loss evidence.

A frame is eligible only when:

- it is sent on the normal UDP video path, not the reliable control/IDR path;
- the existing `default_idr_handler`/NVENC classification does not mark it non-reference;
- the complete frame is at most 48 shards;
- enough token credit exists to replay the whole frame.

Partial-frame scheduling is forbidden. If a frame cannot be fully replayed under the cap/budget, it is skipped.

### Budget invariant

For each fresh UDP frame, replay credit increases by `fresh_payload_bytes / 5`, capped at two maximum protected frames. Scheduling a protected frame deducts its complete fresh payload size before replay occurs.

With zero initial credit, cumulative scheduled replay payload cannot exceed 20% of cumulative fresh UDP payload. Expired or partially failed replays consume already-deducted credit rather than refunding it, making the budget conservative.

The cap only limits saved credit; it cannot create additional credit.

### Replay ordering

At the first `SendData` call of a normal frame N+1, a pending frame N is replayed before N+1 fresh shards begin. The fresh frame's existing `send_begin` timestamp is taken after replay, so the additional delay remains visible to end-to-end timing rather than being hidden as fresh send time.

Each replayed shard uses the existing 50 us spacing. Forty-eight shards therefore have 47 pacing intervals, about 2.35 ms, plus syscall/network overhead. The per-event replay log records the measured replay span.

If the following frame is sent on the reliable control path, pending replay is expired instead of delaying IDR/control traffic.

### Packet semantics

Replay reconstructs the existing `to_headset::video_stream_data_shard` fields from the RTX cache:

- same stream id;
- same frame id;
- same original packet sequence;
- same shard id;
- same view/timing metadata;
- same payload;
- `retransmission=true`.

This is the same late-shard representation used by selective RTX. The Quest `shard_accumulator` already accepts a missing shard for `current`, ignores duplicate shard indices, records that retransmission participated, and completes the frame normally if all shards become present before `next` completes.

No serialization or protocol-revision change is introduced.

### Reference classification and locking

NVENC records `NV_ENC_PIC_TYPE_NONREF_P` through `default_idr_handler::set_non_ref()` before the encoded data is queued to the shared sender. Therefore classification is available by the time `SendData` finishes the frame.

The implementation makes the public `is_non_ref_frame()` query lock the existing IDR mutex because it is now called from the sender thread. The existing `on_feedback()` path already holds that mutex, so it uses the underlying ring entry directly instead of recursively calling the now-locking accessor. This avoids introducing a self-deadlock while removing an unsynchronized cross-thread read.

### Pending-frame invariant

A frame is scheduled only at its end. Its replay is consumed/reset at the beginning of the immediately following normal frame before that following frame can schedule itself. Therefore one pending id cannot be overwritten by a later frame.

A frame-index discontinuity expires the pending replay instead of carrying it forward.

### Error handling

Individual replay send failures increment a dedicated counter and do not throw out of the sender path. A replay with zero successfully sent shards is classified expired/non-useful. A partially failed replay remains bounded and cannot exceed the already-consumed budget.

The prototype does not retry replay packets a second time.

### Existing mechanisms

Selective RTX is unchanged. IDR/control sending is unchanged and takes priority over replay. The parent IDR pipeline-overlap correction remains intact. Existing fresh shard pacing remains 50 us and is not retuned.

### Diff/prototype containment

The implementation patch targets only:

- `server/encoder/idr_handler.cpp`;
- `server/encoder/video_encoder.h`;
- `server/encoder/video_encoder.cpp`.

The first source-audit pass found an initializer-order issue for the new `helix_td_enabled` member. The patch was corrected before this audit checkpoint. This restart is recorded rather than treated as a local exception.

## Audit B — whole-system audit

### Actual question

Can approximately one frame of temporal separation repair a useful subset of the measured correlated loss events without adding an open-ended receive wait, corrupting prediction state, or creating a new major sender latency spike?

This slice is not expected to recover every 10–23 ms event.

### End-to-end path

The complete intended path is:

1. NVENC produces frame N and records whether it is non-reference.
2. Normal frame-N UDP shards are paced/sent and cached by the existing RTX cache.
3. At frame N end, the sender accumulates 20% credit and schedules N only if it is reference-bearing, complete under 48 shards, and fully affordable.
4. At normal frame N+1 start, the complete cached N shard set is replayed with existing retransmission semantics at 50 us spacing.
5. Quest packet handling sees replay shards as late retransmissions in the original frame/shard namespace.
6. If N is still `current`, missing positions can be filled before N+1 becomes complete.
7. If N completes, normal decoder submission/feedback occurs and the existing `received_retransmission` telemetry identifies recovered frames.
8. If replay is too late or also erased, no receive deadline is extended; current behavior eventually abandons N and existing IDR recovery handles prediction resynchronization.

### Latency and observer-effect analysis

Healthy unprotected frames add no replay traffic. A protected replay delays the start of the following fresh frame by at most the bounded replay work; the pacing component is approximately <=2.35 ms under the 48-shard cap.

The 20% long-run payload budget prevents unrestricted duplication. This is still enough added traffic to perturb a marginal wireless path, so validation must compare lower-path loss morphology and sender queue telemetry rather than assuming replay is observationally free.

No client timer, extra decode wait, or larger jitter window is introduced. Therefore the prototype cannot silently turn unrecoverable packet loss into an unbounded latency queue.

### Information-theoretic limit

The measured events can erase dozens of packets. A generic code cannot reconstruct K arbitrary lost payload packets from materially less than K packets' worth of independent recovery information. The complete-replay prototype accepts this cost but bounds how often it is paid.

This slice tests whether selective video-semantic protection plus one-frame time diversity is useful before committing to a larger coding design.

### Existing evidence first

The current client source confirms only current + next retention. Existing decisive logs establish the multi-frame loss envelope. Existing RTX behavior confirms the late-shard packet representation. Existing NVENC code confirms non-reference classification. No new attribution run is needed to justify a build of this prototype.

### Runtime success evidence required

The pre-registered prototype document remains authoritative. In particular, runtime success requires an actually exercised protected-frame recovery, <=20% replay/fresh payload, no persistent sender backlog or new major latency spike, and no corruption/IDR storm attributable to the recovered event.

A build-only pass is not success. A run with scheduled/replayed frames but no loss/recovery opportunity is compatibility evidence only.

### Stop conditions

Do not tune the 48-shard cap, 20% budget, or replay delay within this slice after a material failure. If the bounds make useful recovery too rare, or replay produces unacceptable latency/loss amplification, this mechanism fails and the next slice changes method.

## Rule 40 status before build

### Direct evidence

- The lower-path failure is a correlated multi-packet/multi-frame erasure.
- Quest retains current + next only.
- RTX late shards can fill current-frame holes using existing packet semantics.
- NVENC exposes non-reference output classification before sender transmission completes.
- The proposed implementation has fixed caps and a conservative token-budget invariant.

### Supported inference

A complete copy of an eligible reference-bearing frame delivered at the beginning of the following frame can recover some events whose erasure ends before enough of the replay is lost, without extending the Quest frame-retention window.

### Remaining ambiguity

- The fraction of runtime NVENC frames that are reference-bearing under this configuration is not yet measured by this patch.
- The fraction fitting <=48 shards is not yet measured.
- The measured 10–23 ms events may often outlive useful one-frame replay.
- Added replay traffic could alter the wireless loss process.

### Decision justified by evidence

Proceed to exact patch-application and compile validation only. Do not perform headset/runtime validation until those gates pass.

## Gate status

- Rules 41–42: inherited and binding.
- Scope/success/stop criteria: frozen.
- Implementation artifact: committed as an exact patch.
- Audit A: complete at source/design level after correcting initializer order.
- Audit B: complete at whole-system design level.
- `git apply --check` against an actual checkout: **not yet performed**.
- C++ compile/build validation: **not yet performed**.
- Exact applied-source diff audit: **not yet performed**.
- Matching desktop/Quest runtime validation: **not yet performed**.
- Measured improvement: **not established**.

The unavailable gates above are material. No runtime/headset command is justified until they pass.
