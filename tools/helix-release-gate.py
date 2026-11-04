#!/usr/bin/env python3
"""Refuse release approval unless required CI succeeded for an exact source commit."""

import argparse
import json
import re
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--repo", default="Chineko/WiVRn")
    parser.add_argument("--branch", default="helix-rc1")
    parser.add_argument("--tag", required=True, help="Candidate tag; tag-only CI must also pass")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.commit):
        parser.error("--commit must be the full 40-character source identity")
    data = json.loads(
        subprocess.check_output(
            [
                "gh",
                "api",
                f"repos/{args.repo}/actions/runs?head_sha={args.commit}&per_page=100",
            ],
            text=True,
        )
    )
    failures = []
    for ref in (args.branch, args.tag):
        for name in ("Build", "Format", "Locales"):
            runs = [
                run
                for run in data["workflow_runs"]
                if run["head_sha"] == args.commit
                and run["head_branch"] == ref
                and run["event"] == "push"
                and run["name"] == name
            ]
            if not runs:
                failures.append(f"{ref} / {name}: missing")
                continue
            run = max(runs, key=lambda item: item["id"])
            if run["status"] != "completed" or run["conclusion"] != "success":
                failures.append(f"{ref} / {name}: {run['status']} / {run['conclusion']}")
            else:
                print(f"PASS {ref} / {name}: {run['html_url']}")
    if failures:
        raise SystemExit("RELEASE BLOCKED: " + "; ".join(failures))
    print(f"RELEASE CI GATE PASS: {args.commit}")


if __name__ == "__main__":
    main()
