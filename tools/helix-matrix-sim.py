#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import random

FRAME_MS = 11.1
SHARDS_PER_FRAME = 21.0
SOURCE_SHARDS_PER_MS = SHARDS_PER_FRAME / FRAME_MS
RECEIVER_WINDOW_MS = 2.0 * FRAME_MS

# id, stream, missing shards, mapped send span ms, report delay ms
EVENTS = (
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

INCOMPLETE_FRAMES = 36
ZERO_SHARD_INCOMPLETE_FRAMES = 31

EXP = [0] * 512
LOG = [0] * 256
x = 1
for i in range(255):
    EXP[i] = x
    LOG[x] = i
    x <<= 1
    if x & 0x100:
        x ^= 0x11D
for i in range(255, 512):
    EXP[i] = EXP[i - 255]


def gf_mul(a: int, b: int) -> int:
    if a == 0 or b == 0:
        return 0
    return EXP[LOG[a] + LOG[b]]


def gf_inv(a: int) -> int:
    if a == 0:
        raise ZeroDivisionError
    return EXP[255 - LOG[a]]


def solve_gf256(a: list[list[int]], b: list[list[int]]) -> list[list[int]]:
    n = len(a)
    if n == 0 or any(len(row) != n for row in a):
        raise ValueError("A must be non-empty square")
    width = len(b[0])
    if len(b) != n or any(len(row) != width for row in b):
        raise ValueError("B shape mismatch")
    aug = [a[i][:] + b[i][:] for i in range(n)]
    for col in range(n):
        pivot = next((r for r in range(col, n) if aug[r][col]), None)
        if pivot is None:
            raise ValueError("rank deficient")
        aug[col], aug[pivot] = aug[pivot], aug[col]
        inv = gf_inv(aug[col][col])
        aug[col] = [gf_mul(v, inv) for v in aug[col]]
        for row in range(n):
            if row == col:
                continue
            factor = aug[row][col]
            if factor:
                aug[row] = [v ^ gf_mul(factor, p) for v, p in zip(aug[row], aug[col])]
    return [row[n:] for row in aug]


def matrix_self_test(cases: int, seed: int = 0x48454C4958) -> None:
    rng = random.Random(seed)
    for _ in range(cases):
        n = rng.randint(1, 8)
        width = rng.randint(1, 32)
        matrix = [[1 if r == c else 0 for c in range(n)] for r in range(n)]
        for _ in range(n * 4):
            if n > 1:
                r1, r2 = rng.sample(range(n), 2)
            else:
                r1 = r2 = 0
            if n > 1 and rng.random() < 0.5:
                matrix[r1], matrix[r2] = matrix[r2], matrix[r1]
            else:
                factor = rng.randint(1, 255)
                if r1 == r2:
                    matrix[r1] = [gf_mul(v, factor) for v in matrix[r1]]
                else:
                    matrix[r1] = [v ^ gf_mul(factor, w) for v, w in zip(matrix[r1], matrix[r2])]
        source = [[rng.randrange(256) for _ in range(width)] for _ in range(n)]
        encoded = []
        for row in matrix:
            out = [0] * width
            for coeff, shard in zip(row, source):
                if coeff:
                    out = [v ^ gf_mul(coeff, s) for v, s in zip(out, shard)]
            encoded.append(out)
        if solve_gf256(matrix, encoded) != source:
            raise AssertionError("GF(256) reconstruction mismatch")


def analyze(rates: tuple[float, ...]) -> dict:
    events = []
    for event_id, stream, missing, span, delay in EVENTS:
        age_at_report = span + delay
        post_burst_ms = max(0.0, RECEIVER_WINDOW_MS - span)
        symbols = {
            f"{int(rate * 100)}%": post_burst_ms * SOURCE_SHARDS_PER_MS * rate
            for rate in rates
        }
        events.append({
            "event_id": event_id,
            "stream": stream,
            "missing_shards": missing,
            "send_span_ms": span,
            "report_delay_ms": delay,
            "earliest_age_at_report_ms": age_at_report,
            "report_before_deadline": age_at_report < RECEIVER_WINDOW_MS,
            "post_burst_budget_ms": post_burst_ms,
            "max_post_burst_symbols": symbols,
        })

    zero_fraction = ZERO_SHARD_INCOMPLETE_FRAMES / INCOMPLETE_FRAMES
    return {
        "assumptions": {
            "frame_ms": FRAME_MS,
            "shards_per_frame": SHARDS_PER_FRAME,
            "receiver_window_ms": RECEIVER_WINDOW_MS,
            "source_shards_per_ms": SOURCE_SHARDS_PER_MS,
            "information_bound": "N arbitrary missing source shards require at least N independent repair symbols",
        },
        "recorded_receiver_outcomes": {
            "incomplete_frames": INCOMPLETE_FRAMES,
            "zero_shard_incomplete_frames": ZERO_SHARD_INCOMPLETE_FRAMES,
            "zero_shard_fraction": zero_fraction,
        },
        "events": events,
        "summary": {
            "event_count": len(events),
            "reports_before_current_next_deadline": sum(e["report_before_deadline"] for e in events),
            "reports_too_late": sum(not e["report_before_deadline"] for e in events),
            "smallest_missing_shards": min(e["missing_shards"] for e in events),
            "largest_missing_shards": max(e["missing_shards"] for e in events),
            "decision": (
                "Existing gap-report-triggered full repair is too late for all recorded events. "
                "Low-rate proactive parity can only repair small/edge losses inside current+next; "
                "it cannot reconstruct a fully erased approximately 21-shard frame at single-digit overhead. "
                "Matrix coding is therefore a secondary edge-loss mechanism unless the receiver usefulness "
                "window or encoded protection unit changes."
            ),
        },
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--self-test-cases", type=int, default=1000)
    args = parser.parse_args()

    matrix_self_test(args.self_test_cases)
    report = analyze((0.04, 0.08, 0.10, 0.20))
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
        return 0

    print(f"GF256 self-test: PASS ({args.self_test_cases} cases)")
    a = report["assumptions"]
    o = report["recorded_receiver_outcomes"]
    s = report["summary"]
    print(f"receiver window={a['receiver_window_ms']:.1f}ms; source rate={a['source_shards_per_ms']:.3f} shards/ms")
    print(f"recorded incomplete frames={o['incomplete_frames']}; zero-shard={o['zero_shard_incomplete_frames']} ({o['zero_shard_fraction']:.1%})")
    print("id miss span_ms report_ms age_at_report deadline? postburst_ms 4%eq 8%eq 20%eq")
    for e in report["events"]:
        print(
            f"{e['event_id']:2d} {e['missing_shards']:4d} {e['send_span_ms']:7.3f} "
            f"{e['report_delay_ms']:9.3f} {e['earliest_age_at_report_ms']:13.3f} "
            f"{'yes' if e['report_before_deadline'] else 'NO ':>8} {e['post_burst_budget_ms']:11.3f} "
            f"{e['max_post_burst_symbols']['4%']:4.1f} {e['max_post_burst_symbols']['8%']:4.1f} "
            f"{e['max_post_burst_symbols']['20%']:5.1f}"
        )
    print(f"gap reports before deadline: {s['reports_before_current_next_deadline']}/{s['event_count']}")
    print("Decision:", s["decision"])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
