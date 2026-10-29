# Helix bounded time-diverse recovery — compile-gate span audit

Date: 2026-10-29
Branch: `helix-bounded-time-diverse-recovery`
Failure class: prototype compile/type mismatch in replay payload construction

## Failure observed

The transformed and formatted source reached C++ compilation and failed in `video_encoder::helix_send_time_diverse_replay()` because `to_headset::video_stream_data_shard::payload` is `std::span<uint8_t>` while the time-diverse replay loop iterated the RTX cache entry as `const auto &`, exposing `entry.payload` as `const std::vector<uint8_t>`. A mutable span cannot be assigned from that const vector.

This is a prototype implementation error, not an inherited build-system or formatting failure.

## Audit A — local/type/lifetime audit

The RTX cache owns each payload as `std::vector<uint8_t>`. The replay path does not need a copy or allocation. It needs a temporary mutable view for serialization during the synchronous `cnx->send_stream()` call.

The corrected construction is:

```cpp
packet.payload = std::span<uint8_t>{entry.payload.data(), entry.payload.size()};
```

The cache entry remains alive for the entire replay loop. `helix_send_time_diverse_replay()` is called from `SendData()` while `video_encoder::mutex` is held, so the RTX cache cannot be concurrently mutated by the encoder's retransmission path during construction/send of this packet. The span therefore does not outlive its backing vector during `send_stream()`.

No new allocation, ownership transfer, queue, or buffer lifetime is introduced by this correction.

Neighboring replay fields were rechecked:

- `view_info` is copied from the cache entry optional.
- `timing_info` is copied from the cache entry optional.
- `packet_sequence`, `frame_idx`, and `shard_idx` are scalar copies.
- `retransmission` remains true.
- replay accounting reads `entry.payload.size()` while the cache entry remains owned by the deque.

## Audit B — whole-system effect

This correction does not alter the prototype architecture, bandwidth budget, shard cap, scheduling policy, timing separation, IDR fallback, packet identity, or receiver behavior. It only makes the intended existing cached bytes serializable through the packet's span field.

The active helper remains a resume path for the already-transformed working tree. It verifies prototype markers, refuses unrelated tracked changes, performs bounded formatting audit, full format/diff checks, and then rebuilds `wivrn-server`.

A new headset/runtime run remains prohibited until compilation succeeds and the exact compiled source diff is reviewed/committed.

## Gate status

- Failure classified: complete.
- Audit A: complete for payload type, ownership, lifetime, and locking.
- Audit B: complete; no architecture or experiment change introduced.
- Build validation: pending rerun.
- Runtime validation: not permitted yet.
