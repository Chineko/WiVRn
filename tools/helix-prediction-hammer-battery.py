#!/usr/bin/env python3
from __future__ import annotations

import json
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
HAMMER = HERE / "helix-prediction-hammer.py"
MUTATIONS = HERE / "helix-prediction-hammer-mutations.py"
SEEDS = (0x48454C4958, 1, 2, 3, 4, 5, 0xDEADBEEF, 0xC0FFEE, 0x12345678, 0xFFFFFFFF)


def run_json(args: list[str]) -> dict:
    proc = subprocess.run(args, check=False, text=True, capture_output=True)
    if proc.returncode not in (0, 1):
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise RuntimeError(f"child command failed with status {proc.returncode}: {args}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError:
        sys.stderr.write(proc.stdout)
        sys.stderr.write(proc.stderr)
        raise


def main() -> int:
    reports = []
    for seed in SEEDS:
        report = run_json([
            sys.executable,
            str(HAMMER),
            "--seed", hex(seed),
            "--random-cases", "50000",
            "--recorded-variants", "500",
            "--json",
        ])
        reports.append(report)

    mutation = run_json([sys.executable, str(MUTATIONS), "--json"])
    total_cases = sum(r["totals"]["cases"] for r in reports)
    total_good = sum(r["totals"]["good"] for r in reports)
    fallback_cases = sum(r["totals"]["fallback_cases"] for r in reports)
    fallback_clean = sum(r["totals"]["clean_fallback"] for r in reports)
    catastrophic = sum(r["totals"]["catastrophic_failures"] for r in reports)
    recorded_cases = sum(r["recorded_corpus"]["cases"] for r in reports)
    recorded_good = sum(r["recorded_corpus"]["good"] for r in reports)

    good_rate = total_good / total_cases
    fallback_rate = fallback_clean / fallback_cases if fallback_cases else 1.0
    mutation_ok = mutation["mutation_sanity"] == "PASS"
    every_seed_passed = all(r["promotion_gate"] == "PASS" for r in reports)
    passed = (
        every_seed_passed
        and good_rate >= 0.95
        and fallback_rate >= 0.95
        and catastrophic == 0
        and mutation_ok
    )

    result = {
        "battery": "PASS" if passed else "FAIL",
        "model_commit": reports[0]["model_commit"],
        "seeds": [hex(s) for s in SEEDS],
        "seed_count": len(SEEDS),
        "totals": {
            "cases": total_cases,
            "good": total_good,
            "good_outcome_rate": good_rate,
            "fallback_cases": fallback_cases,
            "clean_fallback": fallback_clean,
            "clean_fallback_rate": fallback_rate,
            "catastrophic_failures": catastrophic,
            "recorded_corpus_cases": recorded_cases,
            "recorded_corpus_good": recorded_good,
            "recorded_corpus_good_rate": recorded_good / recorded_cases,
        },
        "mutation_sanity": mutation,
        "per_seed": [
            {
                "seed": hex(r["seed"]),
                "promotion_gate": r["promotion_gate"],
                "good_outcome_rate": r["totals"]["good_outcome_rate"],
                "clean_fallback_rate": r["totals"]["clean_fallback_rate"],
                "catastrophic_failures": r["totals"]["catastrophic_failures"],
            }
            for r in reports
        ],
        "scope_note": (
            "This battery is host-only behavioral validation. PASS does not prove GPU invalidation success, "
            "Quest transport behavior, RF resilience, decoder visual quality, or perceptual recovery."
        ),
    }

    if "--json" in sys.argv:
        print(json.dumps(result, indent=2, sort_keys=True))
    else:
        t = result["totals"]
        print(f"Helix prediction-chain hammer battery: {result['battery']}")
        print(f"model_commit={result['model_commit']}")
        print(f"seeds={result['seed_count']} cases={t['cases']}")
        print(f"good={t['good']}/{t['cases']} ({t['good_outcome_rate']:.3%})")
        print(f"clean_fallback={t['clean_fallback']}/{t['fallback_cases']} ({t['clean_fallback_rate']:.3%})")
        print(f"recorded_corpus={t['recorded_corpus_good']}/{t['recorded_corpus_cases']} ({t['recorded_corpus_good_rate']:.3%})")
        print(f"catastrophic_failures={t['catastrophic_failures']}")
        print(f"mutation_sanity={mutation['mutation_sanity']}")
        for check, value in mutation["checks"].items():
            print(f"  {check}={value}")
        print("Scope:", result["scope_note"])
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
