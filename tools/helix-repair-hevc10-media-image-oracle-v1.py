#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

BASE = "709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
DIAG = Path("client/decoder/helix_diagnostics.h")
ANDROID = Path("client/decoder/android/android_decoder.cpp")
EXPECTED_DIRTY = {
    "client/decoder/android/android_decoder.cpp",
    "client/decoder/helix_diagnostics.h",
    "client/decoder/shard_accumulator.cpp",
    "server/encoder/video_encoder.cpp",
    "server/encoder/video_encoder.h",
    "server/encoder/video_encoder_nvenc.cpp",
}


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def transform_diag(text: str) -> str:
    text = replace_once(
        text,
        "\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n",
        "\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t rtx_exact_media_output = 0;\n\tuint64_t image_after_rtx = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n\tstd::optional<uint64_t> pending_rtx_image_frame;\n",
        "probe snapshot fields",
    )
    text = replace_once(
        text,
        "\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n",
        "\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t rtx_exact_media_output = 0;\n\tuint64_t image_after_rtx = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n\tstd::optional<uint64_t> pending_rtx_image_frame;\n",
        "probe state fields",
    )
    text = replace_once(
        text,
        "struct hevc10_decoded_correlation\n{\n\tstd::optional<uint64_t> rtx_exact_frame;\n\tstd::optional<uint64_t> resumed_after_incomplete_frame;\n};\n",
        "struct hevc10_decoded_correlation\n{\n\tstd::optional<uint64_t> rtx_exact_frame;\n\tstd::optional<uint64_t> image_after_rtx_frame;\n\tstd::optional<uint64_t> resumed_after_incomplete_frame;\n};\n",
        "decoded correlation fields",
    )
    text = replace_once(
        text,
        "\tstate.rtx_complete_markers++;\n\tstate.pending_rtx_frame = frame_index;\n}\n\ninline hevc10_decoded_correlation hevc10_note_decoded_image",
        "\tstate.rtx_complete_markers++;\n\tstate.pending_rtx_frame = frame_index;\n\tstate.pending_rtx_image_frame = frame_index;\n}\n\ninline std::optional<uint64_t> hevc10_note_media_output(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tif (state.pending_rtx_frame && frame_index == *state.pending_rtx_frame)\n\t{\n\t\tauto recovered = state.pending_rtx_frame;\n\t\tstate.pending_rtx_frame.reset();\n\t\tstate.rtx_exact_media_output++;\n\t\treturn recovered;\n\t}\n\treturn {};\n}\n\ninline hevc10_decoded_correlation hevc10_note_decoded_image",
        "media output oracle",
    )
    text = replace_once(
        text,
        "\tif (state.pending_rtx_frame && frame_index == *state.pending_rtx_frame)\n\t{\n\t\tresult.rtx_exact_frame = *state.pending_rtx_frame;\n\t\tstate.pending_rtx_frame.reset();\n\t\tstate.rtx_exact_decoded++;\n\t}\n",
        "\tif (state.pending_rtx_image_frame && frame_index >= *state.pending_rtx_image_frame)\n\t{\n\t\tresult.rtx_exact_frame = *state.pending_rtx_image_frame;\n\t\tresult.image_after_rtx_frame = *state.pending_rtx_image_frame;\n\t\tstate.pending_rtx_image_frame.reset();\n\t\tstate.rtx_exact_decoded += frame_index == *result.rtx_exact_frame;\n\t\tstate.image_after_rtx++;\n\t}\n",
        "AImage oracle",
    )
    text = replace_once(
        text,
        "\t        .rtx_exact_decoded = state.rtx_exact_decoded,\n\t        .output_resumed_after_incomplete = state.output_resumed_after_incomplete,\n\t        .pending_incomplete_frame = state.pending_incomplete_frame,\n\t        .pending_rtx_frame = state.pending_rtx_frame,\n",
        "\t        .rtx_exact_decoded = state.rtx_exact_decoded,\n\t        .rtx_exact_media_output = state.rtx_exact_media_output,\n\t        .image_after_rtx = state.image_after_rtx,\n\t        .output_resumed_after_incomplete = state.output_resumed_after_incomplete,\n\t        .pending_incomplete_frame = state.pending_incomplete_frame,\n\t        .pending_rtx_frame = state.pending_rtx_frame,\n\t        .pending_rtx_image_frame = state.pending_rtx_image_frame,\n",
        "snapshot initializer",
    )
    return text


def transform_android(text: str) -> str:
    text = replace_once(
        text,
        "\t        \"HELIX_HEVC10_PROBE_SUMMARY stream={} incomplete_markers={} rtx_complete={} rtx_exact_decoded={} output_resumed_after_incomplete={} pending_incomplete={} pending_rtx={}\",\n",
        "\t        \"HELIX_HEVC10_PROBE_SUMMARY stream={} incomplete_markers={} rtx_complete={} rtx_exact_media_output={} image_after_rtx={} rtx_exact_aimage={} output_resumed_after_incomplete={} pending_incomplete={} pending_rtx={} pending_rtx_image={}\",\n",
        "probe summary format",
    )
    text = replace_once(
        text,
        "\t        hevc10_probe.rtx_complete_markers,\n\t        hevc10_probe.rtx_exact_decoded,\n\t        hevc10_probe.output_resumed_after_incomplete,\n\t        hevc10_probe.pending_incomplete_frame ? std::to_string(*hevc10_probe.pending_incomplete_frame) : std::string(\"none\"),\n\t        hevc10_probe.pending_rtx_frame ? std::to_string(*hevc10_probe.pending_rtx_frame) : std::string(\"none\"));\n",
        "\t        hevc10_probe.rtx_complete_markers,\n\t        hevc10_probe.rtx_exact_media_output,\n\t        hevc10_probe.image_after_rtx,\n\t        hevc10_probe.rtx_exact_decoded,\n\t        hevc10_probe.output_resumed_after_incomplete,\n\t        hevc10_probe.pending_incomplete_frame ? std::to_string(*hevc10_probe.pending_incomplete_frame) : std::string(\"none\"),\n\t        hevc10_probe.pending_rtx_frame ? std::to_string(*hevc10_probe.pending_rtx_frame) : std::string(\"none\"),\n\t        hevc10_probe.pending_rtx_image_frame ? std::to_string(*hevc10_probe.pending_rtx_image_frame) : std::string(\"none\"));\n",
        "probe summary arguments",
    )
    text = replace_once(
        text,
        "\tif (auto it = state->submitted_at.find(frame_index); it != state->submitted_at.end())\n\t{\n\t\tauto latency_us = helix_duration_us(now, it->second);\n\t\tstate->submit_to_media_samples++;\n\t\tstate->submit_to_media_total_us += latency_us;\n\t\tstate->submit_to_media_max_us = std::max(state->submit_to_media_max_us, latency_us);\n\t\tstate->submit_to_media_hist[wivrn::helix_diag::latency_bucket(latency_us)]++;\n\t}\n}\n\nvoid helix_note_output_released",
        "\tif (auto it = state->submitted_at.find(frame_index); it != state->submitted_at.end())\n\t{\n\t\tauto latency_us = helix_duration_us(now, it->second);\n\t\tstate->submit_to_media_samples++;\n\t\tstate->submit_to_media_total_us += latency_us;\n\t\tstate->submit_to_media_max_us = std::max(state->submit_to_media_max_us, latency_us);\n\t\tstate->submit_to_media_hist[wivrn::helix_diag::latency_bucket(latency_us)]++;\n\t}\n\n\tif (auto exact = wivrn::helix_diag::hevc10_note_media_output(stream_index, frame_index))\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_MEDIA_OUTPUT stream={} frame={} exact_recovered_frame=1\", stream_index, *exact);\n}\n\nvoid helix_note_output_released",
        "MediaCodec exact output marker",
    )
    text = replace_once(
        text,
        "\tif (hevc10_correlation.rtx_exact_frame)\n\t{\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_DECODED stream={} frame={} exact_recovered_frame=1\",\n\t\t             stream_index, frame_index);\n\t}\n",
        "\tif (hevc10_correlation.image_after_rtx_frame)\n\t{\n\t\tspdlog::info(\"HELIX_HEVC10_IMAGE_AFTER_RTX stream={} recovered_frame={} image_frame={} exact={}\",\n\t\t             stream_index, *hevc10_correlation.image_after_rtx_frame, frame_index,\n\t\t             frame_index == *hevc10_correlation.image_after_rtx_frame);\n\t}\n",
        "AImage marker",
    )
    return text


def validate(diag: str, android: str) -> None:
    for marker in [
        "rtx_exact_media_output",
        "image_after_rtx",
        "pending_rtx_image_frame",
        "hevc10_note_media_output",
    ]:
        if marker not in diag:
            raise RuntimeError(f"diagnostics missing {marker}")
    for marker in [
        "HELIX_HEVC10_RTX_MEDIA_OUTPUT",
        "HELIX_HEVC10_IMAGE_AFTER_RTX",
        "rtx_exact_media_output",
        "pending_rtx_image_frame",
    ]:
        if marker not in android:
            raise RuntimeError(f"android decoder missing {marker}")
    if "HELIX_HEVC10_RTX_DECODED" in android:
        raise RuntimeError("stale exact-AImage verdict marker remains")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    if git("rev-parse", "HEAD") != BASE:
        raise RuntimeError(f"expected HEAD {BASE}")
    dirty = set()
    for line in git("status", "--porcelain").splitlines():
        if line:
            dirty.add(line[3:])
    if dirty != EXPECTED_DIRTY:
        raise RuntimeError(f"expected exact six-file v1 dirty set, got {sorted(dirty)}")

    diag0 = DIAG.read_text()
    android0 = ANDROID.read_text()
    diag1 = transform_diag(diag0)
    android1 = transform_android(android0)
    validate(diag1, android1)

    if args.check_only:
        print("CHECK_ONLY=PASS hevc10-media-image-oracle-repair-v1")
        print(f"source_parent={BASE}")
        print("formal_rtx_decoder_oracle=exact-MediaCodec-output-plus-AImage-at-or-after-recovered-frame")
        print("pixel_cleanliness=NOT_ESTABLISHED")
        return 0

    DIAG.write_text(diag1)
    ANDROID.write_text(android1)
    print("APPLY=PASS hevc10-media-image-oracle-repair-v1")
    print("formal_rtx_decoder_oracle=exact-MediaCodec-output-plus-AImage-at-or-after-recovered-frame")
    print("pixel_cleanliness=NOT_ESTABLISHED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
