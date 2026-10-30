#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools" / "helix-apply-prediction-invalidation.py"
EXPECTED = {
    "server/encoder/video_encoder.h": "734a88e8868326e6678ca44210c456aeb4521ca3",
    "server/encoder/video_encoder.cpp": "bb08dce75292edc18e1732d105d3a94b572c1b51",
    "server/encoder/video_encoder_nvenc.h": "567cbb8d28aec14e9c013d43271be6e42973650e",
    "server/encoder/video_encoder_nvenc.cpp": "19f4287836cf576236a445f5a67bb4c12275bb62",
}


def run(*args: str) -> str:
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def load_helper():
    spec = importlib.util.spec_from_file_location("helix_prediction_invalidation", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load invalidation transformer helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def verify_inputs() -> None:
    if run("git", "status", "--porcelain"):
        raise RuntimeError("worktree is not clean; refusing to transform source")
    for rel, expected in EXPECTED.items():
        actual = run("git", "hash-object", rel)
        if actual != expected:
            raise RuntimeError(f"{rel}: expected blob {expected}, found {actual}")


def disable_full_replay(text: str) -> str:
    old = "        helix_td_enabled(settings.encoder_name == encoder_nvenc),"
    new = "        helix_td_enabled(false),"
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"time-diverse replay disable: expected exactly one source match, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    verify_inputs()
    helper = load_helper()
    transforms = {
        "server/encoder/video_encoder.h": helper.transform_video_encoder_h,
        "server/encoder/video_encoder.cpp": disable_full_replay,
        "server/encoder/video_encoder_nvenc.h": helper.transform_nvenc_h,
        "server/encoder/video_encoder_nvenc.cpp": helper.transform_nvenc_cpp,
    }

    originals: dict[str, str] = {}
    transformed: dict[str, str] = {}
    for rel, transform in transforms.items():
        before = (ROOT / rel).read_text()
        after = transform(before)
        if after == before:
            raise RuntimeError(f"{rel}: transformation produced no change")
        originals[rel] = before
        transformed[rel] = after

    try:
        for rel, after in transformed.items():
            (ROOT / rel).write_text(after)
        subprocess.check_call(["git", "diff", "--check"], cwd=ROOT)
        changed = run("git", "diff", "--name-only").splitlines()
        if set(changed) != set(transforms) or len(changed) != len(transforms):
            raise RuntimeError(f"unexpected changed paths: {changed!r}")
        diff = run("git", "diff", "--", *transforms.keys())
        if "helix_td_enabled(false)" not in diff:
            raise RuntimeError("full-replay disable is absent from resulting diff")
        if "inputTimeStamp = frame_index" not in diff:
            raise RuntimeError("unique NVENC frame timestamp is absent from resulting diff")
        if "nvEncInvalidateRefFrames" not in diff:
            raise RuntimeError("NVENC reference invalidation is absent from resulting diff")
    except Exception:
        for rel, before in originals.items():
            (ROOT / rel).write_text(before)
        raise

    print("PASS: prediction-chain experiment source transformation applied")
    for rel in sorted(changed):
        print(f"  {rel}")
    print("full_time_diverse_replay=disabled")
    print("matrix_transport=unchanged")
    print("quest_protocol=unchanged")
    print("STATUS: source modified only; not built, installed, or runtime-tested")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Helix transform gate: {exc}", file=sys.stderr)
        raise SystemExit(1)
