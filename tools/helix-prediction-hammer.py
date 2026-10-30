#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random
from collections import Counter, deque
from dataclasses import dataclass, asdict

FRAME_MS = 11.1
QUEUE_LIMIT = 16
RECENT_HORIZON = 64
GOOD_GATE = 0.95
FALLBACK_GATE = 0.95

# event_id, stream, missing_shards, send_span_ms, report_delay_ms
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
    """Behavioral mirror of default_idr_handler at cc9e68c09d86."""

    def __init__(self, last_ack: int = 0):
        self.kind = "running"
        self.value = last_ack
        self.non_ref: set[int] = set()

    def reset(self) -> None:
        self.kind = "need_idr"
        self.value = -1
        self.non_ref.clear()

    def set_non_ref(self, frame: int) -> None:
        self.non_ref.add(frame)

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

        assert self.kind == "running"
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
            if frame > self.value + 60:
                self.kind = "wait_idr_feedback"
                self.value = frame
                return "I"
            return "P"

        assert self.kind == "wait_idr_feedback"
        if frame < self.value:
            self.value = frame
            return "I"
        if frame > self.value:
            return "P"
        return "I"


class DeferredInvalidationModel:
    """Behavioral mirror of the compiled deferred-IDR policy at cc9e68c09d86."""

    def __init__(self, supported: bool = True, last_ack: int = 0):
        self.idr = IdrModel(last_ack)
        self.supported = supported
        self.pending: deque[Feedback] = deque()
        self.last_submitted = 0
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
                    overflow = self.pending[0]
                    self.pending.clear()
                    self.stats["overflow"] += 1
                    self.stats["fallback_idr"] += 1
                    self.idr.on_feedback(overflow)
                    self._check()
                    return
                self.pending.append(f)
                self.stats["queued"] += 1
                self._check()
                return

        self.idr.on_feedback(f)
        self._check()

    def reset(self) -> None:
        self.pending.clear()
        self.idr.reset()
        self._check()

    def drain(self, invalidation_success: dict[int, bool] | None = None) -> None:
        invalidation_success = invalidation_success or {}
        newest = self.last_submitted
        while self.pending:
            f = self.pending.popleft()
            frame = f.frame_index
            if newest > frame and newest - frame > RECENT_HORIZON:
                self.stats["stale"] += 1
                self.stats["fallback_idr"] += 1
                self.pending.clear()
                self.idr.on_feedback(f)
                break

            ok = invalidation_success.get(frame, True)
            if ok:
                self.stats["applied"] += 1
            else:
                self.stats["errors"] += 1
                self.stats["fallback_idr"] += 1
                self.pending.clear()
                self.idr.on_feedback(f)
                break
        self._check()

    def encode(self, frame: int, invalidation_success: dict[int, bool] | None = None) -> str:
        self.drain(invalidation_success)
        frame_type = self.idr.get_type(frame)
        self.last_submitted = frame
        self._check()
        return frame_type


@dataclass
class Outcome:
    family: str
    good: bool
    fallback_expected: bool
    fallback_clean: bool
    catastrophic: bool
    detail: str


def outcome(family: str, good: bool, fallback_expected: bool, fallback_clean: bool,
            model: DeferredInvalidationModel, detail: str) -> Outcome:
    return Outcome(
        family=family,
        good=good and not model.catastrophic,
        fallback_expected=fallback_expected,
        fallback_clean=fallback_clean and not model.catastrophic,
        catastrophic=bool(model.catastrophic),
        detail=detail if not model.catastrophic else f"{detail}; catastrophic={model.catastrophic}",
    )


def case_successful_reference(frame: int, lag: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame + lag
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + lag + 1, {frame: True})
    watchdog = lag + 3 > 60
    if watchdog:
        clean = t == "I" and m.stats["applied"] == 1 and not m.pending and m.idr.kind == "wait_idr_feedback"
        return outcome("successful_reference", clean, True, clean, m,
                       f"frame={frame} lag={lag} type={t} reason=decoder_stale_watchdog")
    good = t == "P" and m.stats["applied"] == 1 and not m.pending and m.idr.kind == "running"
    return outcome("successful_reference", good, False, True, m, f"frame={frame} lag={lag} type={t}")


def case_failed_invalidation(frame: int, lag: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame + lag
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + lag + 1, {frame: False})
    clean = t == "I" and not m.pending and m.stats["fallback_idr"] == 1 and m.idr.kind == "wait_idr_feedback"
    return outcome("failed_invalidation", clean, True, clean, m, f"frame={frame} lag={lag} type={t}")


def case_stale(frame: int, age_frames: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame + age_frames
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + age_frames + 1)
    if age_frames > RECENT_HORIZON:
        clean = t == "I" and m.stats["stale"] == 1 and m.stats["fallback_idr"] == 1 and not m.pending
        return outcome("stale_boundary", clean, True, clean, m,
                       f"age={age_frames} type={t} reason=helix_stale_horizon")
    watchdog = age_frames + 3 > 60
    if watchdog:
        clean = t == "I" and m.stats["applied"] == 1 and not m.pending and m.idr.kind == "wait_idr_feedback"
        return outcome("stale_boundary", clean, True, clean, m,
                       f"age={age_frames} type={t} reason=decoder_stale_watchdog")
    good = t == "P" and m.stats["applied"] == 1 and not m.pending
    return outcome("stale_boundary", good, False, True, m, f"age={age_frames} type={t}")


def case_nonref(frame: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.idr.set_non_ref(frame)
    m.last_submitted = frame
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + 1)
    good = t == "P" and m.stats["nonref_skipped"] == 1 and m.stats["fallback_idr"] == 0 and not m.pending
    return outcome("non_reference", good, False, True, m, f"frame={frame} type={t}")


def case_unsupported(frame: int) -> Outcome:
    m = DeferredInvalidationModel(False, last_ack=frame - 2)
    m.last_submitted = frame
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + 1)
    clean = t == "I" and not m.pending and m.idr.kind == "wait_idr_feedback"
    return outcome("unsupported", clean, True, clean, m, f"frame={frame} type={t}")


def case_duplicate(frame: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame
    f = Feedback(frame, False)
    m.on_feedback(f)
    m.on_feedback(f)
    t = m.encode(frame + 1, {frame: True})
    good = t == "P" and m.stats["queued"] == 1 and m.stats["duplicates"] == 1 and m.stats["applied"] == 1
    return outcome("duplicate", good, False, True, m, f"frame={frame} type={t}")


def case_overflow(frame: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame + QUEUE_LIMIT
    for i in range(QUEUE_LIMIT + 1):
        m.on_feedback(Feedback(frame + i, False))
    t = m.encode(frame + QUEUE_LIMIT + 1)
    clean = t == "I" and m.stats["overflow"] == 1 and m.stats["fallback_idr"] == 1 and not m.pending
    return outcome("queue_overflow", clean, True, clean, m, f"type={t} queued={m.stats['queued']}")


def case_reset(frame: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame
    m.on_feedback(Feedback(frame, False))
    m.reset()
    t = m.encode(frame + 1)
    clean = t == "I" and not m.pending and m.idr.kind == "wait_idr_feedback"
    return outcome("reset", clean, True, clean, m, f"frame={frame} type={t}")


def case_failed_idr(frame: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.idr.kind = "wait_idr_feedback"
    m.idr.value = frame
    m.last_submitted = frame
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + 1)
    clean = t == "I" and not m.pending and m.idr.kind == "wait_idr_feedback" and m.idr.value == frame + 1
    return outcome("failed_idr", clean, True, clean, m, f"frame={frame} type={t}")


def case_recorded(event: tuple[int, int, int, float, float], jitter_ms: float, api_success: bool) -> Outcome:
    event_id, stream, missing, span, delay = event
    frame = 10_000 + event_id * 100
    age_ms = max(0.0, span + delay + jitter_ms)
    lag = max(0, int(round(age_ms / FRAME_MS)))
    m = DeferredInvalidationModel(True, last_ack=frame - 2)
    m.last_submitted = frame + lag
    m.on_feedback(Feedback(frame, False))
    t = m.encode(frame + lag + 1, {frame: api_success})
    if api_success:
        good = t == "P" and m.stats["applied"] == 1 and not m.pending
        return outcome("recorded_corpus", good, False, True, m,
                       f"event={event_id} stream={stream} missing={missing} age_ms={age_ms:.3f} lag={lag} type={t}")
    clean = t == "I" and m.stats["fallback_idr"] == 1 and not m.pending
    return outcome("recorded_corpus", clean, True, clean, m,
                   f"event={event_id} stream={stream} missing={missing} age_ms={age_ms:.3f} lag={lag} type={t}")


def case_burst_train(rng: random.Random, base: int) -> Outcome:
    m = DeferredInvalidationModel(True, last_ack=base - 2)
    m.last_submitted = base + rng.randint(0, 8)
    count = rng.randint(1, 24)

    # Reference status is an encoder-output property. Freeze it before any feedback
    # arrives so the generator cannot create the impossible chronology where a loss
    # is queued as a reference and only later becomes NONREF_P.
    sequence = [base + rng.randint(0, 24) for _ in range(count)]
    unique_frames = set(sequence)
    nonrefs = {frame for frame in unique_frames if rng.random() < 0.08}
    for frame in nonrefs:
        m.idr.set_non_ref(frame)

    outcomes: dict[int, bool] = {}
    for frame in unique_frames:
        if frame not in nonrefs and rng.random() < 0.12:
            outcomes[frame] = False
    for frame in sequence:
        m.on_feedback(Feedback(frame, False))

    t = m.encode(base + 30, outcomes)
    fallback_happened = m.stats["fallback_idr"] > 0
    clean = not fallback_happened or (t == "I" and not m.pending)
    good = clean and len(m.pending) == 0
    return outcome("burst_train", good, fallback_happened, clean if fallback_happened else True, m,
                   f"count={count} fallback={fallback_happened} type={t}")


def build_cases(seed: int, random_cases: int, recorded_variants: int) -> list[Outcome]:
    rng = random.Random(seed)
    out: list[Outcome] = []

    # Exact and jittered versions of every measured event. Split API success/failure
    # so the harness tests both containment and fallback on the same measured timing.
    for event in RECORDED_EVENTS:
        out.append(case_recorded(event, 0.0, True))
        out.append(case_recorded(event, 0.0, False))
        for _ in range(recorded_variants):
            jitter = rng.uniform(-8.0, 20.0)
            out.append(case_recorded(event, jitter, rng.random() >= 0.20))

    # Deterministic boundaries.
    for age in (0, 1, 63, 64, 65, 66, 128):
        out.append(case_stale(20_000 + age * 10, age))
    for i in range(100):
        f = 30_000 + i * 100
        out.extend((
            case_successful_reference(f, rng.randint(0, 12)),
            case_failed_invalidation(f + 20, rng.randint(0, 12)),
            case_nonref(f + 40),
            case_unsupported(f + 50),
            case_duplicate(f + 60),
            case_overflow(f + 70),
            case_reset(f + 80),
            case_failed_idr(f + 90),
        ))

    for i in range(random_cases):
        base = 100_000 + i * 100
        selector = rng.randrange(7)
        if selector == 0:
            out.append(case_successful_reference(base, rng.randint(0, 63)))
        elif selector == 1:
            out.append(case_failed_invalidation(base, rng.randint(0, 63)))
        elif selector == 2:
            out.append(case_stale(base, rng.randint(0, 130)))
        elif selector == 3:
            out.append(case_nonref(base))
        elif selector == 4:
            out.append(case_unsupported(base))
        elif selector == 5:
            out.append(case_duplicate(base))
        else:
            out.append(case_burst_train(rng, base))
    return out


def summarize(cases: list[Outcome], seed: int) -> dict:
    total = len(cases)
    good = sum(c.good for c in cases)
    fallback_cases = [c for c in cases if c.fallback_expected]
    fallback_good = sum(c.fallback_clean for c in fallback_cases)
    catastrophic = sum(c.catastrophic for c in cases)

    families: dict[str, dict] = {}
    for family in sorted({c.family for c in cases}):
        subset = [c for c in cases if c.family == family]
        fb = [c for c in subset if c.fallback_expected]
        families[family] = {
            "cases": len(subset),
            "good": sum(c.good for c in subset),
            "good_rate": sum(c.good for c in subset) / len(subset),
            "fallback_cases": len(fb),
            "fallback_clean": sum(c.fallback_clean for c in fb),
            "fallback_clean_rate": (sum(c.fallback_clean for c in fb) / len(fb)) if fb else None,
            "catastrophic": sum(c.catastrophic for c in subset),
        }

    good_rate = good / total
    fallback_rate = fallback_good / len(fallback_cases) if fallback_cases else 1.0
    promotion = good_rate >= GOOD_GATE and fallback_rate >= FALLBACK_GATE and catastrophic == 0
    failures = [asdict(c) for c in cases if not c.good or (c.fallback_expected and not c.fallback_clean) or c.catastrophic][:50]

    return {
        "model_commit": "cc9e68c09d863ed32559116a0edea2e1caa5ffde",
        "seed": seed,
        "thresholds": {
            "good_outcome_rate": GOOD_GATE,
            "clean_fallback_rate": FALLBACK_GATE,
            "catastrophic_failures": 0,
        },
        "totals": {
            "cases": total,
            "good": good,
            "good_outcome_rate": good_rate,
            "fallback_cases": len(fallback_cases),
            "clean_fallback": fallback_good,
            "clean_fallback_rate": fallback_rate,
            "catastrophic_failures": catastrophic,
        },
        "recorded_corpus": families.get("recorded_corpus", {}),
        "families": families,
        "promotion_gate": "PASS" if promotion else "FAIL",
        "scope_note": (
            "Host-only behavioral model of the compiled deferred-IDR policy. It validates state-machine, queue, "
            "timing-boundary, and fallback behavior under injected NVENC outcomes. It does not prove actual GPU "
            "reference-invalidation success, RF behavior, decoder output quality, or perceptual recovery."
        ),
        "failures": failures,
    }


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--seed", type=lambda x: int(x, 0), default=0x48454C4958)
    p.add_argument("--random-cases", type=int, default=50_000)
    p.add_argument("--recorded-variants", type=int, default=500)
    p.add_argument("--json", action="store_true")
    args = p.parse_args()

    cases = build_cases(args.seed, args.random_cases, args.recorded_variants)
    report = summarize(cases, args.seed)
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        t = report["totals"]
        print(f"Helix prediction-chain hammer: {report['promotion_gate']}")
        print(f"model_commit={report['model_commit']}")
        print(f"cases={t['cases']} good={t['good']} good_rate={t['good_outcome_rate']:.3%}")
        print(f"fallback_cases={t['fallback_cases']} clean={t['clean_fallback']} clean_rate={t['clean_fallback_rate']:.3%}")
        print(f"catastrophic_failures={t['catastrophic_failures']}")
        rc = report["recorded_corpus"]
        print(f"recorded_corpus={rc.get('good', 0)}/{rc.get('cases', 0)} ({rc.get('good_rate', 0):.3%})")
        for name, f in report["families"].items():
            fb = "n/a" if f["fallback_clean_rate"] is None else f"{f['fallback_clean_rate']:.3%}"
            print(f"  {name:22s} cases={f['cases']:6d} good={f['good_rate']:.3%} fallback={fb} catastrophic={f['catastrophic']}")
        if report["failures"]:
            print("first failures:")
            for failure in report["failures"][:10]:
                print(" ", failure)
        print("Scope:", report["scope_note"])

    return 0 if report["promotion_gate"] == "PASS" else 1


if __name__ == "__main__":
    raise SystemExit(main())
