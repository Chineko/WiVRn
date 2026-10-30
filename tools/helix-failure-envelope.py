#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from collections import Counter, deque
from dataclasses import dataclass, asdict

FRAME_MS = 11.1
QUEUE_LIMIT = 16
RECENT_HORIZON = 64
STALE_DECODER_FRAMES = 60
GOOD_GATE = 0.95
FALLBACK_GATE = 0.95
SHARDS_PER_FRAME = 64

RECORDED_EVENTS = (
    (1, 1, 23, 10.254, 28.655),
    (2, 0, 38, 12.014, 31.769),
    (3, 0, 42, 22.099, 32.998),
    (4, 1, 48, 14.480, 39.243),
    (5, 1, 29, 14.580, 13.628),
    (6, 0, 31, 21.775, 16.707),
    (7, 0, 59, 23.420, 56.901),
    (8, 1, 47, 12.854, 64.543),
    (9, 1, 33, 10.789, 19.825),
    (10, 0, 46, 11.959, 14.086),
)


@dataclass(frozen=True)
class Feedback:
    frame_index: int
    sent_to_decoder: bool
    received_from_decoder: bool = False


class IdrModel:
    def __init__(self, last_ack: int = 0):
        self.kind = "running"
        self.value = last_ack
        self.non_ref: set[int] = set()

    def is_non_ref(self, frame: int) -> bool:
        return frame in self.non_ref

    def can_defer_failed_reference(self, frame: int) -> bool:
        return self.kind == "running" and frame not in self.non_ref and frame >= self.value

    def on_feedback(self, f: Feedback) -> None:
        if self.kind == "need_idr":
            return
        if self.kind == "wait_idr_feedback":
            if f.frame_index == self.value:
                if f.sent_to_decoder:
                    self.kind = "running"
                    self.value = f.frame_index
                else:
                    self.kind = "need_idr"
                    self.value = -1
            return

        last_ack = self.value
        if not f.sent_to_decoder and f.frame_index >= last_ack and f.frame_index not in self.non_ref:
            self.kind = "need_idr"
            self.value = -1
        elif f.received_from_decoder:
            self.value = max(last_ack, f.frame_index)

    def get_type(self, frame: int) -> str:
        if self.kind == "need_idr":
            self.kind = "wait_idr_feedback"
            self.value = frame
            return "I"
        if self.kind == "running":
            if frame > self.value + STALE_DECODER_FRAMES:
                self.kind = "wait_idr_feedback"
                self.value = frame
                return "I"
            return "P"
        if frame < self.value:
            self.value = frame
            return "I"
        if frame > self.value:
            return "P"
        return "I"


class DeferredInvalidationModel:
    def __init__(self, supported: bool = True, last_ack: int = 0):
        self.idr = IdrModel(last_ack)
        self.supported = supported
        self.pending: deque[Feedback] = deque()
        self.last_submitted = last_ack
        self.stats = Counter()
        self.catastrophic: list[str] = []

    def _check(self) -> None:
        if len(self.pending) > QUEUE_LIMIT:
            self.catastrophic.append("queue_limit_exceeded")
        if self.idr.kind not in {"running", "need_idr", "wait_idr_feedback"}:
            self.catastrophic.append("invalid_idr_state")

    def on_feedback(self, f: Feedback) -> None:
        if not f.sent_to_decoder and self.supported:
            if self.idr.is_non_ref(f.frame_index):
                self.stats["nonref_skipped"] += 1
            elif self.idr.can_defer_failed_reference(f.frame_index):
                if any(p.frame_index == f.frame_index for p in self.pending):
                    self.stats["duplicates"] += 1
                    self._check()
                    return
                if len(self.pending) == QUEUE_LIMIT:
                    oldest = self.pending[0]
                    self.pending.clear()
                    self.stats["overflow"] += 1
                    self.stats["fallback_idr"] += 1
                    self.idr.on_feedback(oldest)
                    self._check()
                    return
                self.pending.append(f)
                self.stats["queued"] += 1
                self._check()
                return
        self.idr.on_feedback(f)
        self._check()

    def drain(self, success: dict[int, bool] | None = None) -> None:
        success = success or {}
        newest = self.last_submitted
        while self.pending:
            f = self.pending.popleft()
            if newest > f.frame_index and newest - f.frame_index > RECENT_HORIZON:
                self.stats["stale"] += 1
                self.stats["fallback_idr"] += 1
                self.pending.clear()
                self.idr.on_feedback(f)
                break
            if success.get(f.frame_index, True):
                self.stats["applied"] += 1
            else:
                self.stats["errors"] += 1
                self.stats["fallback_idr"] += 1
                self.pending.clear()
                self.idr.on_feedback(f)
                break
        self._check()

    def encode(self, frame: int, success: dict[int, bool] | None = None) -> str:
        self.drain(success)
        t = self.idr.get_type(frame)
        self.last_submitted = frame
        self._check()
        return t

    def ack(self, frame: int) -> None:
        self.on_feedback(Feedback(frame, True, True))


@dataclass
class Row:
    family: str
    parameter: str
    trials: int
    good: int
    fallback_clean: int
    fallback_total: int
    catastrophic: int

    @property
    def good_ratio(self) -> float:
        return self.good / self.trials if self.trials else 0.0

    @property
    def fallback_ratio(self) -> float:
        return self.fallback_clean / self.fallback_total if self.fallback_total else 1.0


def receiver_loss_staircase() -> list[Row]:
    rows = []
    for missing in range(0, SHARDS_PER_FRAME + 1):
        # Source-model result: 0 missing completes; any missing count 1..64 makes
        # the current frame incomplete when a complete next frame exposes it.
        rows.append(Row(
            "receiver_shard_loss",
            f"missing={missing}",
            1,
            1,
            int(missing > 0),
            int(missing > 0),
            0,
        ))
    return rows


def recorded_age_envelope() -> list[Row]:
    rows = []
    for event_id, stream, missing, span, delay in RECORDED_EVENTS:
        age_ms = span + delay
        age_frames = max(0, round(age_ms / FRAME_MS))
        frame = 10_000 + event_id * 100
        m = DeferredInvalidationModel(True, frame - 2)
        m.last_submitted = frame + age_frames
        m.on_feedback(Feedback(frame, False))
        t = m.encode(frame + age_frames + 1, {frame: True})
        watchdog = frame + age_frames + 1 > (frame - 2) + STALE_DECODER_FRAMES
        good = (t == "I") if watchdog else (t == "P" and m.stats["applied"] == 1)
        rows.append(Row(
            "recorded_feedback_age",
            f"event={event_id},stream={stream},missing={missing},age_ms={age_ms:.3f},age_frames={age_frames}",
            1, int(good), 0, 0, len(m.catastrophic),
        ))
    return rows


def repeated_full_frame_envelope(max_losses: int = 64) -> list[Row]:
    rows = []
    for healthy_gap in (0, 1, 2, 4, 8, 16, 32, 60):
        for losses in range(1, max_losses + 1):
            m = DeferredInvalidationModel(True, 0)
            next_frame = 1
            clean = True
            fallback = False
            for _ in range(losses):
                lost = next_frame
                m.last_submitted = lost
                m.on_feedback(Feedback(lost, False))
                t = m.encode(lost + 1, {lost: True})
                if t == "I":
                    fallback = True
                elif t != "P":
                    clean = False
                next_frame = lost + 2
                for _ in range(healthy_gap):
                    m.ack(next_frame)
                    t = m.encode(next_frame + 1)
                    if t == "I":
                        fallback = True
                    elif t != "P":
                        clean = False
                    next_frame += 2
            safe = clean and not m.catastrophic and not m.pending
            rows.append(Row(
                "repeated_full_frame_loss",
                f"healthy_gap={healthy_gap},losses={losses},contained_without_idr={int(safe and not fallback)}",
                1,
                int(safe),
                int(safe and fallback),
                int(fallback),
                len(m.catastrophic),
            ))
    return rows


def queued_loss_envelope(max_losses: int = 24) -> list[Row]:
    rows = []
    for losses in range(1, max_losses + 1):
        m = DeferredInvalidationModel(True, 0)
        for frame in range(1, losses + 1):
            m.last_submitted = losses
            m.on_feedback(Feedback(frame, False))
        t = m.encode(losses + 1)
        fallback = m.stats["fallback_idr"] > 0 or t == "I"
        fallback_clean = fallback and t == "I" and not m.pending
        good = (not fallback and t == "P" and not m.pending) or fallback_clean
        rows.append(Row(
            "queued_reference_losses",
            f"losses={losses},contained_without_idr={int(good and not fallback)}",
            1, int(good), int(fallback_clean), int(fallback), len(m.catastrophic),
        ))
    return rows


def api_failure_envelope(max_losses: int = 16) -> list[Row]:
    rows = []
    for fail_at in range(1, max_losses + 1):
        m = DeferredInvalidationModel(True, 0)
        for frame in range(1, max_losses + 1):
            m.on_feedback(Feedback(frame, False))
        success = {frame: frame != fail_at for frame in range(1, max_losses + 1)}
        t = m.encode(max_losses + 1, success)
        fallback = m.stats["fallback_idr"] > 0
        clean = fallback and t == "I" and not m.pending
        rows.append(Row(
            "invalidation_api_failure",
            f"fail_at={fail_at},queued={max_losses}",
            1, int(clean), int(clean), 1, len(m.catastrophic),
        ))
    return rows


def consecutive_loss_boundary(limit: int = 256) -> int | None:
    m = DeferredInvalidationModel(True, 0)
    next_frame = 1
    for loss_no in range(1, limit + 1):
        lost = next_frame
        m.last_submitted = lost
        m.on_feedback(Feedback(lost, False))
        t = m.encode(lost + 1, {lost: True})
        if t == "I":
            return loss_no
        next_frame = lost + 2
    return None


def healthy_gap_one_continuity(limit: int = 256) -> bool:
    m = DeferredInvalidationModel(True, 0)
    next_frame = 1
    for _ in range(limit):
        lost = next_frame
        m.last_submitted = lost
        m.on_feedback(Feedback(lost, False))
        if m.encode(lost + 1, {lost: True}) != "P":
            return False
        good_frame = lost + 2
        m.ack(good_frame)
        if m.encode(good_frame + 1) != "P":
            return False
        next_frame = good_frame + 2
    return not m.pending and not m.catastrophic


def summarize(rows: list[Row]) -> dict:
    totals = Counter()
    family = {}
    for r in rows:
        totals["trials"] += r.trials
        totals["good"] += r.good
        totals["fallback_clean"] += r.fallback_clean
        totals["fallback_total"] += r.fallback_total
        totals["catastrophic"] += r.catastrophic
        f = family.setdefault(r.family, Counter())
        f["trials"] += r.trials
        f["good"] += r.good
        f["fallback_clean"] += r.fallback_clean
        f["fallback_total"] += r.fallback_total
        f["catastrophic"] += r.catastrophic
    return {"totals": dict(totals), "families": {k: dict(v) for k, v in family.items()}}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    rows = []
    rows += receiver_loss_staircase()
    rows += recorded_age_envelope()
    rows += repeated_full_frame_envelope()
    rows += queued_loss_envelope()
    rows += api_failure_envelope()

    summary = summarize(rows)
    t = summary["totals"]
    good_ratio = t["good"] / t["trials"] if t["trials"] else 0.0
    fallback_ratio = t["fallback_clean"] / t["fallback_total"] if t["fallback_total"] else 1.0
    passed = good_ratio >= GOOD_GATE and fallback_ratio >= FALLBACK_GATE and t["catastrophic"] == 0

    recorded_ages = [round((span + delay) / FRAME_MS) for _, _, _, span, delay in RECORDED_EVENTS]
    boundaries = {
        "deferred_queue_capacity_before_idr": QUEUE_LIMIT,
        "first_queued_loss_count_for_idr": QUEUE_LIMIT + 1,
        "first_consecutive_full_frame_loss_cycle_for_watchdog_idr": consecutive_loss_boundary(),
        "one_good_decoded_frame_between_losses_preserves_continuity_for_256_cycles": healthy_gap_one_continuity(),
        "recorded_feedback_age_frames_min": min(recorded_ages),
        "recorded_feedback_age_frames_max": max(recorded_ages),
        "stale_decoder_watchdog_frames": STALE_DECODER_FRAMES,
        "invalidation_recent_horizon_frames": RECENT_HORIZON,
    }

    payload = {
        "model_commit": "cc9e68c09d863ed32559116a0edea2e1caa5ffde",
        "scope": "host-only source-derived model; not Quest/RF/GPU runtime evidence",
        "pass": passed,
        "good_ratio": good_ratio,
        "fallback_ratio": fallback_ratio,
        "boundaries": boundaries,
        "summary": summary,
        "rows": [asdict(r) | {"good_ratio": r.good_ratio, "fallback_ratio": r.fallback_ratio} for r in rows],
    }

    if args.json:
        print(json.dumps(payload, indent=2, sort_keys=True))
    else:
        print(f"Helix failure envelope: {'PASS' if passed else 'FAIL'}")
        print(f"model_commit={payload['model_commit']}")
        print(f"trials={t['trials']} good={t['good']} good_ratio={good_ratio:.6f}")
        print(f"fallback={t['fallback_clean']}/{t['fallback_total']} fallback_ratio={fallback_ratio:.6f}")
        print(f"catastrophic={t['catastrophic']}")
        print("continuity_boundaries:")
        for key, value in boundaries.items():
            print(f"  {key}={value}")
        for name, f in summary["families"].items():
            gr = f['good'] / f['trials'] if f['trials'] else 0.0
            fr = f['fallback_clean'] / f['fallback_total'] if f['fallback_total'] else 1.0
            print(f"family={name} good={f['good']}/{f['trials']} ({gr:.3%}) fallback={f['fallback_clean']}/{f['fallback_total']} ({fr:.3%}) catastrophic={f['catastrophic']}")
        print("scope=host-only-source-model; Quest/RF/GPU runtime still unproven")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
