#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import pathlib
import sys

HERE = pathlib.Path(__file__).resolve().parent
HAMMER = HERE / "helix-prediction-hammer.py"
spec = importlib.util.spec_from_file_location("helix_prediction_hammer", HAMMER)
if spec is None or spec.loader is None:
    raise RuntimeError("cannot load hammer module")
h = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = h
spec.loader.exec_module(h)


class NoErrorFallback(h.DeferredInvalidationModel):
    def drain(self, invalidation_success=None):
        invalidation_success = invalidation_success or {}
        newest = self.last_submitted
        while self.pending:
            f = self.pending.popleft()
            frame = f.frame_index
            if newest > frame and newest - frame > h.RECENT_HORIZON:
                self.stats["stale"] += 1
                # MUTATION: silently discard instead of entering IDR fallback.
                continue
            if invalidation_success.get(frame, True):
                self.stats["applied"] += 1
            else:
                self.stats["errors"] += 1
                # MUTATION: silently discard instead of entering IDR fallback.
        self._check()


class UnboundedQueue(h.DeferredInvalidationModel):
    def on_feedback(self, f):
        if not f.sent_to_decoder and self.supported and self.idr.can_defer_failed_reference(f.frame_index):
            if not any(p.frame_index == f.frame_index for p in self.pending):
                # MUTATION: ignore the queue limit.
                self.pending.append(f)
                self.stats["queued"] += 1
                self._check()
                return
        self.idr.on_feedback(f)
        self._check()


class LateDrain(h.DeferredInvalidationModel):
    def encode(self, frame, invalidation_success=None):
        # MUTATION: decide P/IDR before applying invalidation/fallback.
        frame_type = self.idr.get_type(frame)
        self.drain(invalidation_success)
        self.last_submitted = frame
        self._check()
        return frame_type


def check_no_error_fallback() -> bool:
    frame = 1000
    m = NoErrorFallback(True, last_ack=frame - 2)
    m.last_submitted = frame
    m.on_feedback(h.Feedback(frame, False))
    t = m.encode(frame + 1, {frame: False})
    # Correct policy must choose IDR immediately on injected NVENC failure.
    return not (t == "I" and m.stats["fallback_idr"] == 1 and not m.pending)


def check_unbounded_queue() -> bool:
    frame = 2000
    m = UnboundedQueue(True, last_ack=frame - 2)
    m.last_submitted = frame
    for i in range(h.QUEUE_LIMIT + 1):
        m.on_feedback(h.Feedback(frame + i, False))
    # The normal invariant checker must flag this mutation as catastrophic.
    return "queue_limit_exceeded" in m.catastrophic


def check_late_drain() -> bool:
    frame = 3000
    m = LateDrain(True, last_ack=frame - 2)
    m.last_submitted = frame
    m.on_feedback(h.Feedback(frame, False))
    t = m.encode(frame + 1, {frame: False})
    # The mutation emits P for the decision that should have become an IDR.
    return t != "I" and m.stats["fallback_idr"] == 1


def main() -> int:
    checks = {
        "no_error_fallback_detected": check_no_error_fallback(),
        "unbounded_queue_detected": check_unbounded_queue(),
        "late_drain_detected": check_late_drain(),
    }
    passed = all(checks.values())
    report = {
        "mutation_sanity": "PASS" if passed else "FAIL",
        "checks": checks,
        "meaning": "PASS means the validation model rejects three intentionally broken recovery policies.",
    }
    if "--json" in sys.argv:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print(f"Helix hammer mutation sanity: {report['mutation_sanity']}")
        for name, value in checks.items():
            print(f"  {name}={value}")
        print(report["meaning"])
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
