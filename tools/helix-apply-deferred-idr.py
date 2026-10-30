#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

EXPECTED = {
    "server/encoder/idr_handler.h": "54f6b488710a66d1765c7bc9cf4fc3c486ca8e72",
    "server/encoder/idr_handler.cpp": "eca028a50d52dc8389ef5926d3ecb703fea5973b",
    "server/encoder/video_encoder_nvenc.h": "382ef1579effb5532bd3dea4c73c12d41d96ab5f",
    "server/encoder/video_encoder_nvenc.cpp": "87996d4027791353676f3f90f4c7fc5cd72d716f",
}


def git_blob(path: str) -> str:
    return subprocess.check_output(["git", "hash-object", path], text=True).strip()


def replace_once(text: str, old: str, new: str, path: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{path}: expected exactly one replacement anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    for path, expected in EXPECTED.items():
        actual = git_blob(path)
        if actual != expected:
            raise RuntimeError(f"{path}: blob mismatch: expected {expected}, got {actual}")

    originals = {path: Path(path).read_text() for path in EXPECTED}
    updated = dict(originals)

    path = "server/encoder/idr_handler.h"
    updated[path] = replace_once(
        updated[path],
        "\tbool is_non_ref_frame(uint64_t frame_index);\n\tframe_type get_type(uint64_t frame_index, uint8_t stream_idx);",
        "\tbool is_non_ref_frame(uint64_t frame_index);\n\tbool can_defer_failed_reference(uint64_t frame_index);\n\tframe_type get_type(uint64_t frame_index, uint8_t stream_idx);",
        path,
    )

    path = "server/encoder/idr_handler.cpp"
    updated[path] = replace_once(
        updated[path],
        "bool default_idr_handler::is_non_ref_frame(uint64_t frame_index)\n{\n\tstd::unique_lock lock(mutex);\n\treturn non_ref_frames[frame_index % non_ref_frames.size()] == frame_index;\n}\n\ndefault_idr_handler::frame_type",
        "bool default_idr_handler::is_non_ref_frame(uint64_t frame_index)\n{\n\tstd::unique_lock lock(mutex);\n\treturn non_ref_frames[frame_index % non_ref_frames.size()] == frame_index;\n}\n\nbool default_idr_handler::can_defer_failed_reference(uint64_t frame_index)\n{\n\tstd::unique_lock lock(mutex);\n\tif (non_ref_frames[frame_index % non_ref_frames.size()] == frame_index)\n\t\treturn false;\n\tauto * running_state = std::get_if<running>(&state);\n\treturn running_state && frame_index >= running_state->last_ack;\n}\n\ndefault_idr_handler::frame_type",
        path,
    )

    path = "server/encoder/video_encoder_nvenc.h"
    updated[path] = replace_once(
        updated[path],
        "\tstd::deque<uint64_t> helix_pending_invalidations;",
        "\tstd::deque<from_headset::feedback> helix_pending_invalidations;",
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "\tstd::atomic<uint64_t> helix_invalidation_errors{0};",
        "\tstd::atomic<uint64_t> helix_invalidation_errors{0};\n\tstd::atomic<uint64_t> helix_invalidation_fallback_idr{0};",
        path,
    )
    updated[path] = replace_once(
        updated[path],
        "\tvoid helix_drain_reference_invalidations();\n\tvoid helix_clear_reference_invalidations();",
        "\tvoid helix_drain_reference_invalidations();",
        path,
    )

    path = "server/encoder/video_encoder_nvenc.cpp"
    old_feedback = '''void video_encoder_nvenc::on_feedback(const from_headset::feedback & feedback)
{
\tauto & idr_handler = static_cast<default_idr_handler &>(*idr);
\tif (!feedback.sent_to_decoder && helix_ref_invalidation_supported)
\t{
\t\tif (idr_handler.is_non_ref_frame(feedback.frame_index))
\t\t{
\t\t\t++helix_invalidation_nonref_skipped;
\t\t}
\t\telse
\t\t{
\t\t\tstd::scoped_lock lock(helix_invalidation_mutex);
\t\t\tif (std::ranges::contains(helix_pending_invalidations, feedback.frame_index))
\t\t\t{
\t\t\t\t++helix_invalidation_duplicates;
\t\t\t}
\t\t\telse
\t\t\t{
\t\t\t\tif (helix_pending_invalidations.size() == helix_invalidation_queue_limit)
\t\t\t\t{
\t\t\t\t\thelix_pending_invalidations.pop_front();
\t\t\t\t\t++helix_invalidation_overflow;
\t\t\t\t}
\t\t\t\thelix_pending_invalidations.push_back(feedback.frame_index);
\t\t\t\t++helix_invalidation_queued;
\t\t\t}
\t\t}
\t}

\tvideo_encoder::on_feedback(feedback);
}

void video_encoder_nvenc::reset()
{
\thelix_clear_reference_invalidations();
\tvideo_encoder::reset();
}

void video_encoder_nvenc::helix_clear_reference_invalidations()
{
\tstd::scoped_lock lock(helix_invalidation_mutex);
\thelix_pending_invalidations.clear();
}

void video_encoder_nvenc::helix_drain_reference_invalidations()
{
\tstd::scoped_lock lock(helix_invalidation_mutex);
\tconst uint64_t newest = helix_last_submitted_frame.load(std::memory_order_relaxed);
\twhile (!helix_pending_invalidations.empty())
\t{
\t\tconst uint64_t frame_index = helix_pending_invalidations.front();
\t\thelix_pending_invalidations.pop_front();
\t\tif (newest > frame_index && newest - frame_index > helix_invalidation_recent_horizon)
\t\t{
\t\t\t++helix_invalidation_stale;
\t\t\tcontinue;
\t\t}

\t\tNVENCSTATUS status = shared_state->fn.nvEncInvalidateRefFrames(session_handle, frame_index);
\t\tif (status == NV_ENC_SUCCESS)
\t\t{
\t\t\t++helix_invalidation_applied;
\t\t\tU_LOG_I("Helix NVENC invalidated reference stream=%u frame=%llu",
\t\t\t        stream_idx,
\t\t\t        static_cast<unsigned long long>(frame_index));
\t\t}
\t\telse
\t\t{
\t\t\t++helix_invalidation_errors;
\t\t\tU_LOG_W("Helix NVENC reference invalidation failed stream=%u frame=%llu status=%d",
\t\t\t        stream_idx,
\t\t\t        static_cast<unsigned long long>(frame_index),
\t\t\t        static_cast<int>(status));
\t\t}
\t}
}
'''
    new_feedback = '''void video_encoder_nvenc::on_feedback(const from_headset::feedback & feedback)
{
\tauto & idr_handler = static_cast<default_idr_handler &>(*idr);
\tif (!feedback.sent_to_decoder && helix_ref_invalidation_supported)
\t{
\t\tstd::scoped_lock lock(helix_invalidation_mutex);
\t\tif (idr_handler.is_non_ref_frame(feedback.frame_index))
\t\t{
\t\t\t++helix_invalidation_nonref_skipped;
\t\t}
\t\telse if (idr_handler.can_defer_failed_reference(feedback.frame_index))
\t\t{
\t\t\tconst bool duplicate = std::ranges::any_of(helix_pending_invalidations, [&](const auto & pending) {
\t\t\t\treturn pending.frame_index == feedback.frame_index;
\t\t\t});
\t\t\tif (duplicate)
\t\t\t{
\t\t\t\t++helix_invalidation_duplicates;
\t\t\t\treturn;
\t\t\t}
\t\t\tif (helix_pending_invalidations.size() == helix_invalidation_queue_limit)
\t\t\t{
\t\t\t\tauto overflow = helix_pending_invalidations.front();
\t\t\t\thelix_pending_invalidations.clear();
\t\t\t\t++helix_invalidation_overflow;
\t\t\t\t++helix_invalidation_fallback_idr;
\t\t\t\tvideo_encoder::on_feedback(overflow);
\t\t\t\treturn;
\t\t\t}
\t\t\thelix_pending_invalidations.push_back(feedback);
\t\t\t++helix_invalidation_queued;
\t\t\treturn;
\t\t}
\t}

\tvideo_encoder::on_feedback(feedback);
}

void video_encoder_nvenc::reset()
{
\tstd::scoped_lock lock(helix_invalidation_mutex);
\thelix_pending_invalidations.clear();
\tvideo_encoder::reset();
}

void video_encoder_nvenc::helix_drain_reference_invalidations()
{
\tstd::scoped_lock lock(helix_invalidation_mutex);
\tconst uint64_t newest = helix_last_submitted_frame.load(std::memory_order_relaxed);
\twhile (!helix_pending_invalidations.empty())
\t{
\t\tauto feedback = helix_pending_invalidations.front();
\t\thelix_pending_invalidations.pop_front();
\t\tconst uint64_t frame_index = feedback.frame_index;
\t\tif (newest > frame_index && newest - frame_index > helix_invalidation_recent_horizon)
\t\t{
\t\t\t++helix_invalidation_stale;
\t\t\t++helix_invalidation_fallback_idr;
\t\t\thelix_pending_invalidations.clear();
\t\t\tvideo_encoder::on_feedback(feedback);
\t\t\tbreak;
\t\t}

\t\tNVENCSTATUS status = shared_state->fn.nvEncInvalidateRefFrames(session_handle, frame_index);
\t\tif (status == NV_ENC_SUCCESS)
\t\t{
\t\t\t++helix_invalidation_applied;
\t\t\tU_LOG_I("Helix NVENC invalidated reference stream=%u frame=%llu",
\t\t\t        stream_idx,
\t\t\t        static_cast<unsigned long long>(frame_index));
\t\t}
\t\telse
\t\t{
\t\t\t++helix_invalidation_errors;
\t\t\t++helix_invalidation_fallback_idr;
\t\t\thelix_pending_invalidations.clear();
\t\t\tU_LOG_W("Helix NVENC reference invalidation failed stream=%u frame=%llu status=%d; falling back to IDR",
\t\t\t        stream_idx,
\t\t\t        static_cast<unsigned long long>(frame_index),
\t\t\t        static_cast<int>(status));
\t\t\tvideo_encoder::on_feedback(feedback);
\t\t\tbreak;
\t\t}
\t}
}
'''
    updated[path] = replace_once(updated[path], old_feedback, new_feedback, path)
    updated[path] = replace_once(
        updated[path],
        'errors=%llu pending=%zu",',
        'errors=%llu fallback_idr=%llu pending=%zu",',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        'static_cast<unsigned long long>(helix_invalidation_errors.load(std::memory_order_relaxed)),\n\t        pending_invalidations);',
        'static_cast<unsigned long long>(helix_invalidation_errors.load(std::memory_order_relaxed)),\n\t        static_cast<unsigned long long>(helix_invalidation_fallback_idr.load(std::memory_order_relaxed)),\n\t        pending_invalidations);',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        '\t\t\tidr_handler.reset();\n\t\t\thelix_clear_reference_invalidations();',
        '\t\t\t{\n\t\t\t\tstd::scoped_lock lock(helix_invalidation_mutex);\n\t\t\t\thelix_pending_invalidations.clear();\n\t\t\t\tidr_handler.reset();\n\t\t\t}',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        '\tauto frame_type = idr_handler.get_type(frame_index, stream_idx);',
        '\thelix_drain_reference_invalidations();\n\tauto frame_type = idr_handler.get_type(frame_index, stream_idx);',
        path,
    )
    updated[path] = replace_once(
        updated[path],
        '\t\thelix_drain_reference_invalidations();\n\t\tNVENC_CHECK(shared_state->fn.nvEncEncodePicture(session_handle, &frame_params));',
        '\t\tNVENC_CHECK(shared_state->fn.nvEncEncodePicture(session_handle, &frame_params));',
        path,
    )

    try:
        for path in EXPECTED:
            Path(path).write_text(updated[path])
        subprocess.run(["git", "diff", "--check", "--", *EXPECTED.keys()], check=True)
        changed = set(subprocess.check_output(["git", "diff", "--name-only", "--", *EXPECTED.keys()], text=True).splitlines())
        if changed != set(EXPECTED):
            raise RuntimeError(f"unexpected changed path set: {sorted(changed)}")
    except Exception:
        for path, text in originals.items():
            Path(path).write_text(text)
        raise

    print("PASS: deferred-IDR source transformation applied")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
