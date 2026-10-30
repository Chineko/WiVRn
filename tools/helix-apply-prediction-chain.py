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


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one source match, found {count}")
    return text.replace(old, new, 1)


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
    return replace_once(
        text,
        "        helix_td_enabled(settings.encoder_name == encoder_nvenc),",
        "        helix_td_enabled(false),",
        "time-diverse replay disable",
    )


def transform_nvenc_h(helper, text: str) -> str:
    text = helper.transform_nvenc_h(text)
    return replace_once(
        text,
        "\tstd::atomic<uint64_t> helix_last_submitted_frame{0};\n",
        "\tstd::atomic<uint64_t> helix_last_submitted_frame{0};\n\tbool helix_ref_invalidation_supported = false;\n",
        "reference invalidation capability state",
    )


def transform_nvenc_cpp(helper, text: str) -> str:
    text = helper.transform_nvenc_cpp(text)
    text = replace_once(
        text,
        "\tif (!feedback.sent_to_decoder)\n",
        "\tif (!feedback.sent_to_decoder && helix_ref_invalidation_supported)\n",
        "capability-gated failed-frame queue",
    )
    text = replace_once(
        text,
        "\tcheck_encode_guid_supported(shared_state, session_handle, encodeGUID);\n",
        "\tcheck_encode_guid_supported(shared_state, session_handle, encodeGUID);\n\n"
        "\tNV_ENC_CAPS_PARAM ref_invalidation_cap{\n"
        "\t        .version = NV_ENC_CAPS_PARAM_VER,\n"
        "\t        .capsToQuery = NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION,\n"
        "\t};\n"
        "\tint ref_invalidation_supported = 0;\n"
        "\tNVENC_CHECK(shared_state->fn.nvEncGetEncodeCaps(\n"
        "\t        session_handle, encodeGUID, &ref_invalidation_cap, &ref_invalidation_supported));\n"
        "\thelix_ref_invalidation_supported = ref_invalidation_supported == 1;\n"
        "\tU_LOG_I(\"Helix NVENC reference invalidation stream=%u supported=%d\",\n"
        "\t        stream_idx, helix_ref_invalidation_supported);\n",
        "reference invalidation capability query",
    )
    text = replace_once(
        text,
        "\tU_LOG_I(\"Helix NVENC invalidation summary stream=%u queued=%llu",
        "\tU_LOG_I(\"Helix NVENC invalidation summary stream=%u supported=%d queued=%llu",
        "invalidation summary capability field",
    )
    return replace_once(
        text,
        "\t        stream_idx,\n\t        static_cast<unsigned long long>(helix_invalidation_queued.load",
        "\t        stream_idx,\n\t        helix_ref_invalidation_supported,\n\t        static_cast<unsigned long long>(helix_invalidation_queued.load",
        "invalidation summary capability value",
    )


def main() -> int:
    verify_inputs()
    helper = load_helper()
    transforms = {
        "server/encoder/video_encoder.h": helper.transform_video_encoder_h,
        "server/encoder/video_encoder.cpp": disable_full_replay,
        "server/encoder/video_encoder_nvenc.h": lambda text: transform_nvenc_h(helper, text),
        "server/encoder/video_encoder_nvenc.cpp": lambda text: transform_nvenc_cpp(helper, text),
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
        required = (
            "helix_td_enabled(false)",
            "inputTimeStamp = frame_index",
            "NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION",
            "nvEncInvalidateRefFrames",
            "helix_ref_invalidation_supported",
        )
        missing = [needle for needle in required if needle not in diff]
        if missing:
            raise RuntimeError(f"required experiment changes absent from resulting diff: {missing!r}")
    except Exception:
        for rel, before in originals.items():
            (ROOT / rel).write_text(before)
        raise

    print("PASS: prediction-chain experiment source transformation applied")
    for rel in sorted(changed):
        print(f"  {rel}")
    print("full_time_diverse_replay=disabled")
    print("reference_invalidation=capability_gated")
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
