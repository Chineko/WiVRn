#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE = HERE / "helix-failure-envelope.py"
spec = importlib.util.spec_from_file_location("helix_failure_envelope", BASE)
if spec is None or spec.loader is None:
    raise RuntimeError("unable to load helix-failure-envelope.py")
mod = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = mod
spec.loader.exec_module(mod)

MAX_BATCH = 24
MAX_AGE = 80


def run_case(batch: int, age: int) -> dict:
    base = 1000
    m = mod.DeferredInvalidationModel(True, base - 2)
    newest_failed = base + batch - 1
    m.last_submitted = newest_failed + age

    for frame in range(base, base + batch):
        m.on_feedback(mod.Feedback(frame, False))

    frame_type = m.encode(newest_failed + age + 1)
    fallback = m.stats["fallback_idr"] > 0 or frame_type == "I"
    fallback_clean = fallback and frame_type == "I" and not m.pending
    contained = not fallback and frame_type == "P" and not m.pending
    safe = (contained or fallback_clean) and not m.catastrophic
    return {
        "batch": batch,
        "age_frames": age,
        "age_ms": age * mod.FRAME_MS,
        "contained_without_idr": contained,
        "fallback": fallback,
        "fallback_clean": fallback_clean,
        "safe": safe,
        "frame_type": frame_type,
        "stats": dict(m.stats),
        "catastrophic": list(m.catastrophic),
    }


def main() -> int:
    rows = [run_case(batch, age) for batch in range(1, MAX_BATCH + 1) for age in range(MAX_AGE + 1)]
    unsafe = [r for r in rows if not r["safe"]]
    catastrophic = [r for r in rows if r["catastrophic"]]
    fallback_rows = [r for r in rows if r["fallback"]]
    clean_fallback = [r for r in fallback_rows if r["fallback_clean"]]

    first_fallback_age = {}
    max_contained_age = {}
    for batch in range(1, MAX_BATCH + 1):
        br = [r for r in rows if r["batch"] == batch]
        fb = [r["age_frames"] for r in br if r["fallback"]]
        ok = [r["age_frames"] for r in br if r["contained_without_idr"]]
        first_fallback_age[batch] = min(fb) if fb else None
        max_contained_age[batch] = max(ok) if ok else None

    payload = {
        "model_commit": "cc9e68c09d863ed32559116a0edea2e1caa5ffde",
        "scope": "host-only source-derived burst-depth x feedback-age grid",
        "cases": len(rows),
        "safe": len(rows) - len(unsafe),
        "unsafe": len(unsafe),
        "fallback": len(fallback_rows),
        "clean_fallback": len(clean_fallback),
        "catastrophic": len(catastrophic),
        "first_fallback_age_frames_by_batch": first_fallback_age,
        "max_contained_age_frames_by_batch": max_contained_age,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0 if not unsafe and not catastrophic and len(clean_fallback) == len(fallback_rows) else 1


if __name__ == "__main__":
    raise SystemExit(main())
