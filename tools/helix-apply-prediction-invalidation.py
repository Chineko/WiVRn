#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
EXPECTED = {
    "server/encoder/video_encoder.h": "734a88e8868326e6678ca44210c456aeb4521ca3",
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


def verify_inputs() -> None:
    status = run("git", "status", "--porcelain")
    if status:
        raise RuntimeError("worktree is not clean; refusing to transform source")
    for rel, expected in EXPECTED.items():
        actual = run("git", "hash-object", rel)
        if actual != expected:
            raise RuntimeError(f"{rel}: expected blob {expected}, found {actual}")


def transform_video_encoder_h(text: str) -> str:
    return replace_once(
        text,
        "\tvoid on_feedback(const from_headset::feedback &);\n\tvoid reset();",
        "\tvirtual void on_feedback(const from_headset::feedback &);\n\tvirtual void reset();",
        "video_encoder virtual feedback/reset",
    )


def transform_nvenc_h(text: str) -> str:
    text = replace_once(
        text,
        '#include "video_encoder_nvenc_shared_state.h"\n#include <array>\n#include <ffnvcodec/dynlink_cuda.h>\n#include <ffnvcodec/dynlink_loader.h>\n#include <ffnvcodec/nvEncodeAPI.h>\n#include <vulkan/vulkan_raii.hpp>',
        '#include "video_encoder_nvenc_shared_state.h"\n#include <array>\n#include <atomic>\n#include <deque>\n#include <ffnvcodec/dynlink_cuda.h>\n#include <ffnvcodec/dynlink_loader.h>\n#include <ffnvcodec/nvEncodeAPI.h>\n#include <mutex>\n#include <vulkan/vulkan_raii.hpp>',
        "nvenc includes",
    )
    text = replace_once(
        text,
        "\tfloat fps;\n\tuint64_t bitrate;\n\tint bytesPerPixel = 1;\n\n\tNV_ENC_RC_PARAMS get_rc_params(uint64_t bitrate, float framerate);\n\tvoid set_init_params_fps(float framerate);",
        "\tfloat fps;\n\tuint64_t bitrate;\n\tint bytesPerPixel = 1;\n\n"
        "\tstatic constexpr size_t helix_invalidation_queue_limit = 16;\n"
        "\tstatic constexpr uint64_t helix_invalidation_recent_horizon = 64;\n"
        "\tstd::mutex helix_invalidation_mutex;\n"
        "\tstd::deque<uint64_t> helix_pending_invalidations;\n"
        "\tstd::atomic<uint64_t> helix_last_submitted_frame{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_queued{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_applied{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_nonref_skipped{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_duplicates{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_overflow{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_stale{0};\n"
        "\tstd::atomic<uint64_t> helix_invalidation_errors{0};\n\n"
        "\tNV_ENC_RC_PARAMS get_rc_params(uint64_t bitrate, float framerate);\n"
        "\tvoid set_init_params_fps(float framerate);\n"
        "\tvoid helix_drain_reference_invalidations();\n"
        "\tvoid helix_clear_reference_invalidations();",
        "nvenc invalidation state",
    )
    return replace_once(
        text,
        "\tvoid present_image(vk::Image y_cbcr, vk::SemaphoreSubmitInfo info, uint8_t slot, uint64_t frame_index) override;\n\tstd::optional<data> encode(uint8_t slot, uint64_t frame_index) override;\n\n\tstatic std::array<int, 2> get_max_size(video_codec);",
        "\tvoid present_image(vk::Image y_cbcr, vk::SemaphoreSubmitInfo info, uint8_t slot, uint64_t frame_index) override;\n"
        "\tstd::optional<data> encode(uint8_t slot, uint64_t frame_index) override;\n"
        "\tvoid on_feedback(const from_headset::feedback &) override;\n"
        "\tvoid reset() override;\n\n"
        "\tstatic std::array<int, 2> get_max_size(video_codec);",
        "nvenc overrides",
    )


def transform_nvenc_cpp(text: str) -> str:
    text = replace_once(
        text,
        "void video_encoder_nvenc::set_init_params_fps(float framerate)\n{\n\tinit_params.frameRateNum = framerate;\n\tinit_params.frameRateDen = 1;\n}\n",
        "void video_encoder_nvenc::set_init_params_fps(float framerate)\n"
        "{\n\tinit_params.frameRateNum = framerate;\n\tinit_params.frameRateDen = 1;\n}\n\n"
        "void video_encoder_nvenc::on_feedback(const from_headset::feedback & feedback)\n"
        "{\n"
        "\tauto & idr_handler = static_cast<default_idr_handler &>(*idr);\n"
        "\tif (!feedback.sent_to_decoder)\n"
        "\t{\n"
        "\t\tif (idr_handler.is_non_ref_frame(feedback.frame_index))\n"
        "\t\t{\n\t\t\t++helix_invalidation_nonref_skipped;\n\t\t}\n"
        "\t\telse\n"
        "\t\t{\n"
        "\t\t\tstd::scoped_lock lock(helix_invalidation_mutex);\n"
        "\t\t\tif (std::ranges::contains(helix_pending_invalidations, feedback.frame_index))\n"
        "\t\t\t{\n\t\t\t\t++helix_invalidation_duplicates;\n\t\t\t}\n"
        "\t\t\telse\n"
        "\t\t\t{\n"
        "\t\t\t\tif (helix_pending_invalidations.size() == helix_invalidation_queue_limit)\n"
        "\t\t\t\t{\n\t\t\t\t\thelix_pending_invalidations.pop_front();\n\t\t\t\t\t++helix_invalidation_overflow;\n\t\t\t\t}\n"
        "\t\t\t\thelix_pending_invalidations.push_back(feedback.frame_index);\n"
        "\t\t\t\t++helix_invalidation_queued;\n"
        "\t\t\t}\n\t\t}\n\t}\n\n"
        "\tvideo_encoder::on_feedback(feedback);\n}\n\n"
        "void video_encoder_nvenc::reset()\n"
        "{\n\thelix_clear_reference_invalidations();\n\tvideo_encoder::reset();\n}\n\n"
        "void video_encoder_nvenc::helix_clear_reference_invalidations()\n"
        "{\n\tstd::scoped_lock lock(helix_invalidation_mutex);\n\thelix_pending_invalidations.clear();\n}\n\n"
        "void video_encoder_nvenc::helix_drain_reference_invalidations()\n"
        "{\n"
        "\tstd::scoped_lock lock(helix_invalidation_mutex);\n"
        "\tconst uint64_t newest = helix_last_submitted_frame.load(std::memory_order_relaxed);\n"
        "\twhile (!helix_pending_invalidations.empty())\n"
        "\t{\n"
        "\t\tconst uint64_t frame_index = helix_pending_invalidations.front();\n"
        "\t\thelix_pending_invalidations.pop_front();\n"
        "\t\tif (newest > frame_index && newest - frame_index > helix_invalidation_recent_horizon)\n"
        "\t\t{\n\t\t\t++helix_invalidation_stale;\n\t\t\tcontinue;\n\t\t}\n\n"
        "\t\tNVENCSTATUS status = shared_state->fn.nvEncInvalidateRefFrames(session_handle, frame_index);\n"
        "\t\tif (status == NV_ENC_SUCCESS)\n"
        "\t\t{\n"
        "\t\t\t++helix_invalidation_applied;\n"
        "\t\t\tU_LOG_I(\"Helix NVENC invalidated reference stream=%u frame=%llu\",\n"
        "\t\t\t        stream_idx,\n"
        "\t\t\t        static_cast<unsigned long long>(frame_index));\n"
        "\t\t}\n"
        "\t\telse\n"
        "\t\t{\n"
        "\t\t\t++helix_invalidation_errors;\n"
        "\t\t\tU_LOG_W(\"Helix NVENC reference invalidation failed stream=%u frame=%llu status=%d\",\n"
        "\t\t\t        stream_idx,\n"
        "\t\t\t        static_cast<unsigned long long>(frame_index),\n"
        "\t\t\t        static_cast<int>(status));\n"
        "\t\t}\n\t}\n}\n",
        "nvenc invalidation methods",
    )
    text = replace_once(
        text,
        "video_encoder_nvenc::~video_encoder_nvenc()\n{\n\tif (session_handle)\n\t\tshared_state->fn.nvEncDestroyEncoder(session_handle);\n}",
        "video_encoder_nvenc::~video_encoder_nvenc()\n"
        "{\n"
        "\tsize_t pending_invalidations = 0;\n"
        "\t{\n\t\tstd::scoped_lock lock(helix_invalidation_mutex);\n\t\tpending_invalidations = helix_pending_invalidations.size();\n\t}\n"
        "\tU_LOG_I(\"Helix NVENC invalidation summary stream=%u queued=%llu applied=%llu nonref_skipped=%llu duplicate=%llu overflow=%llu stale=%llu errors=%llu pending=%zu\",\n"
        "\t        stream_idx,\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_queued.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_applied.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_nonref_skipped.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_duplicates.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_overflow.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_stale.load(std::memory_order_relaxed)),\n"
        "\t        static_cast<unsigned long long>(helix_invalidation_errors.load(std::memory_order_relaxed)),\n"
        "\t        pending_invalidations);\n"
        "\tif (session_handle)\n\t\tshared_state->fn.nvEncDestroyEncoder(session_handle);\n}",
        "nvenc invalidation summary",
    )
    text = replace_once(
        text,
        "\t\t\tidr_handler.reset();\n\n\t\t\tU_LOG_I(\"nvenc: reconfiguring succeeded.\");",
        "\t\t\tidr_handler.reset();\n\t\t\thelix_clear_reference_invalidations();\n\n\t\t\tU_LOG_I(\"nvenc: reconfiguring succeeded.\");",
        "nvenc reconfigure clear",
    )
    text = replace_once(text, "\t        .inputTimeStamp = 0,", "\t        .inputTimeStamp = frame_index,", "nvenc frame timestamp")
    return replace_once(
        text,
        "\t\tNVENC_CHECK(shared_state->fn.nvEncEncodePicture(session_handle, &frame_params));\n\t\tNVENC_CHECK(shared_state->fn.nvEncLockBitstream(session_handle, &buf_lock_params));",
        "\t\thelix_drain_reference_invalidations();\n"
        "\t\tNVENC_CHECK(shared_state->fn.nvEncEncodePicture(session_handle, &frame_params));\n"
        "\t\thelix_last_submitted_frame.store(frame_index, std::memory_order_relaxed);\n"
        "\t\tNVENC_CHECK(shared_state->fn.nvEncLockBitstream(session_handle, &buf_lock_params));",
        "nvenc drain before encode",
    )


def main() -> int:
    verify_inputs()
    transforms = {
        "server/encoder/video_encoder.h": transform_video_encoder_h,
        "server/encoder/video_encoder_nvenc.h": transform_nvenc_h,
        "server/encoder/video_encoder_nvenc.cpp": transform_nvenc_cpp,
    }
    for rel, transform in transforms.items():
        path = ROOT / rel
        before = path.read_text()
        after = transform(before)
        if after == before:
            raise RuntimeError(f"{rel}: transformation produced no change")
        path.write_text(after)

    subprocess.check_call(["git", "diff", "--check"], cwd=ROOT)
    changed = run("git", "diff", "--name-only").splitlines()
    expected_paths = list(transforms)
    if changed != expected_paths:
        raise RuntimeError(f"unexpected changed paths: {changed!r}")
    print("PASS: bounded NVENC reference invalidation source transformation applied")
    for rel in changed:
        print(f"  {rel}")
    print("STATUS: source modified only; not built, installed, or runtime-tested")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Helix transform gate: {exc}", file=sys.stderr)
        raise SystemExit(1)
