#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
from pathlib import Path

BASE = "709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
FILES = [
    Path("server/encoder/video_encoder.h"),
    Path("server/encoder/video_encoder.cpp"),
    Path("server/encoder/video_encoder_nvenc.cpp"),
    Path("client/decoder/helix_diagnostics.h"),
    Path("client/decoder/shard_accumulator.cpp"),
    Path("client/decoder/android/android_decoder.cpp"),
]


def git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True).strip()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"{label}: expected exactly one anchor, found {count}")
    return text.replace(old, new, 1)


def transform_video_encoder_h(text: str) -> str:
    old = """\tuint64_t helix_rtx_send_errors = 0;\n\tuint64_t helix_initial_send_errors = 0;\n\n\tuint64_t helix_gap_reports = 0;\n"""
    new = """\tuint64_t helix_rtx_send_errors = 0;\n\tuint64_t helix_initial_send_errors = 0;\n\n\t// Deterministic HEVC10 recovery canary. When HELIX_HEVC10_RECOVERY=1,\n\t// one cached fresh shard is withheld once per eye. The packet sequence is\n\t// still reserved and cached, so only the normal gap/RTX path can recover it.\n\tbool helix_hevc10_fault_enabled = false;\n\tuint64_t helix_hevc10_frame_ordinal = 0;\n\tuint64_t helix_hevc10_fault_target_ordinal = 0;\n\tbool helix_hevc10_fault_current_frame = false;\n\tbool helix_hevc10_fault_dropped = false;\n\tuint64_t helix_hevc10_faults_injected = 0;\n\n\tuint64_t helix_gap_reports = 0;\n"""
    return replace_once(text, old, new, "video_encoder.h canary state")


def transform_video_encoder_cpp(text: str) -> str:
    text = replace_once(
        text,
        "#include <array>\n#include <chrono>\n#include <string>\n",
        "#include <array>\n#include <chrono>\n#include <cstdlib>\n#include <cstring>\n#include <string>\n",
        "video_encoder.cpp includes",
    )

    old = """std::unique_ptr<video_encoder> video_encoder::create(\n        wivrn::vk_bundle & wivrn_vk,\n        const encoder_settings & settings,\n        uint8_t stream_idx)\n{\n\tusing namespace std::string_literals;\n\tstd::unique_ptr<video_encoder> res;\n"""
    new = """std::unique_ptr<video_encoder> video_encoder::create(\n        wivrn::vk_bundle & wivrn_vk,\n        const encoder_settings & settings,\n        uint8_t stream_idx)\n{\n\tusing namespace std::string_literals;\n\tstd::unique_ptr<video_encoder> res;\n\n\tconst char * helix_hevc10 = std::getenv(\"HELIX_HEVC10_RECOVERY\");\n\tconst bool helix_hevc10_enabled = helix_hevc10 && std::strcmp(helix_hevc10, \"1\") == 0;\n\tif (helix_hevc10_enabled && stream_idx < 2)\n\t{\n\t\tif (settings.encoder_name != encoder_nvenc || settings.codec != video_codec::h265 || settings.bit_depth != 10)\n\t\t\tthrow std::runtime_error(\"HELIX_HEVC10_RECOVERY requires NVENC H.265 Main10 on both eye streams\");\n\t\tU_LOG_I(\"HELIX_HEVC10_ENCODER_GATE stream=%u encoder=nvenc codec=h265 bit_depth=10\", stream_idx);\n\t}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp encoder gate")

    old = """\tU_LOG_I(\"Helix pacing telemetry %s stream=%u shard_spacing=%lluus\", helix_pacing_telemetry_version, stream_idx, static_cast<unsigned long long>(helix_shard_spacing.count()));\n}\n"""
    new = """\tU_LOG_I(\"Helix pacing telemetry %s stream=%u shard_spacing=%lluus\", helix_pacing_telemetry_version, stream_idx, static_cast<unsigned long long>(helix_shard_spacing.count()));\n\n\tconst char * helix_hevc10 = std::getenv(\"HELIX_HEVC10_RECOVERY\");\n\thelix_hevc10_fault_enabled = helix_hevc10 && std::strcmp(helix_hevc10, \"1\") == 0 && stream_idx < 2;\n\tif (helix_hevc10_fault_enabled)\n\t{\n\t\t// Stagger the eyes so each recovery is independently observable after warmup.\n\t\thelix_hevc10_fault_target_ordinal = stream_idx == 0 ? 600 : 900;\n\t\tU_LOG_I(\"HELIX_HEVC10_FAULT_PLAN stream=%u target_ordinal=%llu shard=0\",\n\t\t        stream_idx,\n\t\t        static_cast<unsigned long long>(helix_hevc10_fault_target_ordinal));\n\t}\n}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp fault plan")

    old = """\tU_LOG_I(\n\t        \"Helix time-diverse summary stream=%u enabled=%d fresh_bytes=%llu replay_bytes=%llu reference_frames=%llu scheduled=%llu replayed=%llu replayed_shards=%llu skipped_oversize=%llu skipped_budget=%llu expired=%llu send_errors=%llu credit=%llu\",\n"""
    new = """\tif (helix_hevc10_fault_enabled)\n\t{\n\t\tU_LOG_I(\"HELIX_HEVC10_FAULT_SUMMARY stream=%u target_ordinal=%llu injected=%llu\",\n\t\t        stream_idx,\n\t\t        static_cast<unsigned long long>(helix_hevc10_fault_target_ordinal),\n\t\t        static_cast<unsigned long long>(helix_hevc10_faults_injected));\n\t}\n\n\tU_LOG_I(\n\t        \"Helix time-diverse summary stream=%u enabled=%d fresh_bytes=%llu replay_bytes=%llu reference_frames=%llu scheduled=%llu replayed=%llu replayed_shards=%llu skipped_oversize=%llu skipped_budget=%llu expired=%llu send_errors=%llu credit=%llu\",\n"""
    text = replace_once(text, old, new, "video_encoder.cpp fault summary")

    old = """\tif (shard.shard_idx == 0)\n\t{\n\t\tif (control)\n"""
    new = """\tif (shard.shard_idx == 0)\n\t{\n\t\tif (helix_hevc10_fault_enabled && !control)\n\t\t{\n\t\t\t++helix_hevc10_frame_ordinal;\n\t\t\thelix_hevc10_fault_current_frame = helix_hevc10_frame_ordinal == helix_hevc10_fault_target_ordinal;\n\t\t\thelix_hevc10_fault_dropped = false;\n\t\t}\n\n\t\tif (control)\n"""
    text = replace_once(text, old, new, "video_encoder.cpp frame ordinal")

    old = """\t\thelix_current_frame_bytes += std::distance(begin, next);\n\t\thelix_current_frame_shards++;\n\t\ttry\n\t\t{\n\t\t\tif (control)\n\t\t\t\tcnx->send_control(to_headset::video_stream_data_shard{shard});\n\t\t\telse\n\t\t\t\tcnx->send_stream(to_headset::video_stream_data_shard{shard});\n\t\t}\n\t\tcatch (...)\n\t\t{\n\t\t\t++helix_initial_send_errors;\n\t\t\t// Ignore network errors\n\t\t}\n"""
    new = """\t\thelix_current_frame_bytes += std::distance(begin, next);\n\t\thelix_current_frame_shards++;\n\n\t\tconst bool helix_hevc10_drop =\n\t\t        helix_hevc10_fault_enabled &&\n\t\t        helix_hevc10_fault_current_frame &&\n\t\t        !helix_hevc10_fault_dropped &&\n\t\t        !control && shard.packet_sequence != 0 && shard.shard_idx == 0;\n\t\tif (helix_hevc10_drop)\n\t\t{\n\t\t\thelix_hevc10_fault_dropped = true;\n\t\t\t++helix_hevc10_faults_injected;\n\t\t\tU_LOG_W(\"HELIX_HEVC10_DROP stream=%u ordinal=%llu frame=%llu shard=%u packet_sequence=%llu cached=1\",\n\t\t\t        stream_idx,\n\t\t\t        static_cast<unsigned long long>(helix_hevc10_frame_ordinal),\n\t\t\t        static_cast<unsigned long long>(shard.frame_idx),\n\t\t\t        shard.shard_idx,\n\t\t\t        static_cast<unsigned long long>(shard.packet_sequence));\n\t\t}\n\t\telse\n\t\t{\n\t\t\ttry\n\t\t\t{\n\t\t\t\tif (control)\n\t\t\t\t\tcnx->send_control(to_headset::video_stream_data_shard{shard});\n\t\t\t\telse\n\t\t\t\t\tcnx->send_stream(to_headset::video_stream_data_shard{shard});\n\t\t\t}\n\t\t\tcatch (...)\n\t\t\t{\n\t\t\t\t++helix_initial_send_errors;\n\t\t\t\t// Ignore network errors\n\t\t\t}\n\t\t}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp deterministic drop")
    return text


def transform_nvenc(text: str) -> str:
    text = replace_once(
        text,
        "#include <algorithm>\n#include <stdexcept>\n",
        "#include <algorithm>\n#include <cstdlib>\n#include <stdexcept>\n#include <string_view>\n",
        "video_encoder_nvenc.cpp includes",
    )
    old = """\t\tcase video_codec::h265:\n\t\t\tif (bitDepth == NV_ENC_BIT_DEPTH_10)\n\t\t\t{\n\t\t\t\tconfig.profileGUID = NV_ENC_HEVC_PROFILE_MAIN10_GUID;\n\t\t\t\tcheck_profile_guid_supported(shared_state, session_handle, encodeGUID, config.profileGUID, \"GPU doesn't support 10-bit depth with H.265 codec.\");\n\t\t\t}\n"""
    new = """\t\tcase video_codec::h265:\n\t\t\tif (bitDepth == NV_ENC_BIT_DEPTH_10)\n\t\t\t{\n\t\t\t\tconfig.profileGUID = NV_ENC_HEVC_PROFILE_MAIN10_GUID;\n\t\t\t\tcheck_profile_guid_supported(shared_state, session_handle, encodeGUID, config.profileGUID, \"GPU doesn't support 10-bit depth with H.265 codec.\");\n\t\t\t\tif (const char * helix_hevc10 = std::getenv(\"HELIX_HEVC10_RECOVERY\");\n\t\t\t\t    helix_hevc10 && std::string_view(helix_hevc10) == \"1\" && stream_idx < 2)\n\t\t\t\t{\n\t\t\t\t\tU_LOG_I(\"HELIX_HEVC10_MAIN10_PROFILE stream=%u profile=main10 input_bit_depth=10 output_bit_depth=10\", stream_idx);\n\t\t\t\t}\n\t\t\t}\n"""
    return replace_once(text, old, new, "video_encoder_nvenc.cpp Main10 marker")


def transform_diag(text: str) -> str:
    text = replace_once(
        text,
        "#include <mutex>\n",
        "#include <mutex>\n#include <optional>\n",
        "helix_diagnostics.h optional include",
    )
    anchor = """inline network_snapshot snapshot(uint8_t stream_index)\n{\n\tauto & state = network(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tauto now = clock::now();\n\treturn {\n\t        .completed_frames = state.completed_frames,\n\t        .incomplete_frames = state.incomplete_frames,\n\t        .zero_shard_frames = state.zero_shard_frames,\n\t        .missing_shards = state.missing_shards,\n\t        .old_shards = state.old_shards,\n\t        .frame_jump_events = state.frame_jump_events,\n\t        .skipped_frames = state.skipped_frames,\n\t        .last_assembly_us = state.last_assembly_us,\n\t        .max_assembly_us = state.max_assembly_us,\n\t        .since_incomplete_us = age_us(now, state.last_incomplete),\n\t        .since_old_shard_us = age_us(now, state.last_old_shard),\n\t        .since_frame_jump_us = age_us(now, state.last_frame_jump),\n\t        .assembly_hist = state.assembly_hist,\n\t};\n}\n\n"""
    addition = anchor + """struct hevc10_probe_snapshot\n{\n\tuint64_t incomplete_markers = 0;\n\tuint64_t rtx_complete_markers = 0;\n\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n};\n\nstruct hevc10_probe_state\n{\n\tstd::mutex mutex;\n\tuint64_t incomplete_markers = 0;\n\tuint64_t rtx_complete_markers = 0;\n\tuint64_t rtx_exact_decoded = 0;\n\tuint64_t output_resumed_after_incomplete = 0;\n\tstd::optional<uint64_t> pending_incomplete_frame;\n\tstd::optional<uint64_t> pending_rtx_frame;\n};\n\nstruct hevc10_decoded_correlation\n{\n\tstd::optional<uint64_t> rtx_exact_frame;\n\tstd::optional<uint64_t> resumed_after_incomplete_frame;\n};\n\ninline std::array<hevc10_probe_state, stream_count> & hevc10_probe_states()\n{\n\tstatic std::array<hevc10_probe_state, stream_count> states;\n\treturn states;\n}\n\ninline hevc10_probe_state & hevc10_probe(uint8_t stream_index)\n{\n\treturn hevc10_probe_states()[std::min<size_t>(stream_index, stream_count - 1)];\n}\n\ninline void hevc10_note_incomplete(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tstate.incomplete_markers++;\n\tstate.pending_incomplete_frame = frame_index;\n}\n\ninline void hevc10_note_rtx_complete(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tstate.rtx_complete_markers++;\n\tstate.pending_rtx_frame = frame_index;\n}\n\ninline hevc10_decoded_correlation hevc10_note_decoded_image(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\thevc10_decoded_correlation result;\n\tif (state.pending_rtx_frame && frame_index == *state.pending_rtx_frame)\n\t{\n\t\tresult.rtx_exact_frame = *state.pending_rtx_frame;\n\t\tstate.pending_rtx_frame.reset();\n\t\tstate.rtx_exact_decoded++;\n\t}\n\tif (state.pending_incomplete_frame && frame_index > *state.pending_incomplete_frame)\n\t{\n\t\tresult.resumed_after_incomplete_frame = *state.pending_incomplete_frame;\n\t\tstate.pending_incomplete_frame.reset();\n\t\tstate.output_resumed_after_incomplete++;\n\t}\n\treturn result;\n}\n\ninline hevc10_probe_snapshot hevc10_probe_snapshot_for(uint8_t stream_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\treturn {\n\t        .incomplete_markers = state.incomplete_markers,\n\t        .rtx_complete_markers = state.rtx_complete_markers,\n\t        .rtx_exact_decoded = state.rtx_exact_decoded,\n\t        .output_resumed_after_incomplete = state.output_resumed_after_incomplete,\n\t        .pending_incomplete_frame = state.pending_incomplete_frame,\n\t        .pending_rtx_frame = state.pending_rtx_frame,\n\t};\n}\n\n"""
    return replace_once(text, anchor, addition, "helix_diagnostics.h HEVC10 probe")


def transform_accumulator(text: str) -> str:
    old = """\tif (frame.empty())\n\t{\n\t\thelix_diag::note_incomplete_frame(shards.feedback.stream_index, 0, true);\n\t\tspdlog::info(\"frame {} was not sent because no shard was received\", shards.frame_index());\n\t\treturn;\n\t}\n"""
    new = """\tif (frame.empty())\n\t{\n\t\thelix_diag::note_incomplete_frame(shards.feedback.stream_index, 0, true);\n\t\thelix_diag::hevc10_note_incomplete(shards.feedback.stream_index, shards.frame_index());\n\t\tspdlog::info(\"frame {} was not sent because no shard was received\", shards.frame_index());\n\t\tspdlog::info(\"HELIX_HEVC10_INCOMPLETE stream={} frame={} missing=0 zero_shards=1\",\n\t\t             shards.feedback.stream_index, shards.frame_index());\n\t\treturn;\n\t}\n"""
    text = replace_once(text, old, new, "shard_accumulator.cpp zero-shard marker")

    old = """\tbool end = frame.back() and frame.back()->timing_info;\n\thelix_diag::note_incomplete_frame(shards.feedback.stream_index, missing, false);\n\tspdlog::info(\"frame {} was not sent with {} data shards, {}{} missing\", frame_idx, data, end ? \"\" : \"at least \", missing);\n"""
    new = """\tbool end = frame.back() and frame.back()->timing_info;\n\thelix_diag::note_incomplete_frame(shards.feedback.stream_index, missing, false);\n\thelix_diag::hevc10_note_incomplete(shards.feedback.stream_index, shards.frame_index());\n\tspdlog::info(\"frame {} was not sent with {} data shards, {}{} missing\", frame_idx, data, end ? \"\" : \"at least \", missing);\n\tspdlog::info(\"HELIX_HEVC10_INCOMPLETE stream={} frame={} missing={} zero_shards=0\",\n\t             shards.feedback.stream_index, shards.frame_index(), missing);\n"""
    text = replace_once(text, old, new, "shard_accumulator.cpp incomplete marker")

    old = """\tif (current.received_retransmission)\n\t{\n\t\tif (auto scene = weak_scene.lock())\n\t\t\tscene->helix_note_rtx_frame_recovered(current.feedback.stream_index);\n\t}\n"""
    new = """\tif (current.received_retransmission)\n\t{\n\t\thelix_diag::hevc10_note_rtx_complete(current.feedback.stream_index, current.feedback.frame_index);\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_ASSEMBLED stream={} frame={}\",\n\t\t             current.feedback.stream_index, current.feedback.frame_index);\n\t\tif (auto scene = weak_scene.lock())\n\t\t\tscene->helix_note_rtx_frame_recovered(current.feedback.stream_index);\n\t}\n"""
    return replace_once(text, old, new, "shard_accumulator.cpp RTX marker")


def transform_android(text: str) -> str:
    old = """\tauto network = wivrn::helix_diag::snapshot(stream_index);\n\tstd::scoped_lock lock(state->mutex);\n"""
    new = """\tauto network = wivrn::helix_diag::snapshot(stream_index);\n\tauto hevc10_probe = wivrn::helix_diag::hevc10_probe_snapshot_for(stream_index);\n\tstd::scoped_lock lock(state->mutex);\n"""
    text = replace_once(text, old, new, "android_decoder.cpp probe snapshot")

    old = """\tspdlog::info(\n\t        \"Helix diagnostic summary stream {}: media_outputs={} submit_to_media(avg/max)={}/{}us output_gap_max={}us complete_interval(avg/last/max)={}/{}/{}us release_to_image(avg/max)={}/{}us image_processing(avg/max)={}/{}us hist_submit_image(<5/10/20/40/80/>80ms)={}/{}/{}/{}/{}/{} hist_submit_media={}/{}/{}/{}/{}/{} hist_output_gap={}/{}/{}/{}/{}/{} hist_complete_interval={}/{}/{}/{}/{}/{} hist_release_image={}/{}/{}/{}/{}/{} hist_image_processing={}/{}/{}/{}/{}/{} network(complete/incomplete/zero/missing/old/jumps/skipped)={}/{}/{}/{}/{}/{}/{} assembly(last/max)={}/{}us hist_assembly={}/{}/{}/{}/{}/{}\",\n"""
    new = """\tspdlog::info(\n\t        \"HELIX_HEVC10_PROBE_SUMMARY stream={} incomplete_markers={} rtx_complete={} rtx_exact_decoded={} output_resumed_after_incomplete={} pending_incomplete={} pending_rtx={}\",\n\t        stream_index,\n\t        hevc10_probe.incomplete_markers,\n\t        hevc10_probe.rtx_complete_markers,\n\t        hevc10_probe.rtx_exact_decoded,\n\t        hevc10_probe.output_resumed_after_incomplete,\n\t        hevc10_probe.pending_incomplete_frame ? std::to_string(*hevc10_probe.pending_incomplete_frame) : std::string(\"none\"),\n\t        hevc10_probe.pending_rtx_frame ? std::to_string(*hevc10_probe.pending_rtx_frame) : std::string(\"none\"));\n\n\tspdlog::info(\n\t        \"Helix diagnostic summary stream {}: media_outputs={} submit_to_media(avg/max)={}/{}us output_gap_max={}us complete_interval(avg/last/max)={}/{}/{}us release_to_image(avg/max)={}/{}us image_processing(avg/max)={}/{}us hist_submit_image(<5/10/20/40/80/>80ms)={}/{}/{}/{}/{}/{} hist_submit_media={}/{}/{}/{}/{}/{} hist_output_gap={}/{}/{}/{}/{}/{} hist_complete_interval={}/{}/{}/{}/{}/{} hist_release_image={}/{}/{}/{}/{}/{} hist_image_processing={}/{}/{}/{}/{}/{} network(complete/incomplete/zero/missing/old/jumps/skipped)={}/{}/{}/{}/{}/{}/{} assembly(last/max)={}/{}us hist_assembly={}/{}/{}/{}/{}/{}\",\n"""
    text = replace_once(text, old, new, "android_decoder.cpp probe summary")

    old = """\tif (recovered && recovery_duration_us)\n\t\tspdlog::info(\"Helix decoder output resumed on stream {} at frame {} after {} us\", stream_index, frame_index, *recovery_duration_us);\n\telse if (recovered)\n\t\tspdlog::info(\"Helix decoder output resumed on stream {} at frame {}\", stream_index, frame_index);\n}\n"""
    new = """\tauto hevc10_correlation = wivrn::helix_diag::hevc10_note_decoded_image(stream_index, frame_index);\n\tif (hevc10_correlation.rtx_exact_frame)\n\t{\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_DECODED stream={} frame={} exact_recovered_frame=1\",\n\t\t             stream_index, frame_index);\n\t}\n\tif (hevc10_correlation.resumed_after_incomplete_frame)\n\t{\n\t\tspdlog::info(\"HELIX_HEVC10_OUTPUT_RESUMED stream={} damaged_frame={} decoded_frame={}\",\n\t\t             stream_index, *hevc10_correlation.resumed_after_incomplete_frame, frame_index);\n\t}\n\n\tif (recovered && recovery_duration_us)\n\t\tspdlog::info(\"Helix decoder output resumed on stream {} at frame {} after {} us\", stream_index, frame_index, *recovery_duration_us);\n\telse if (recovered)\n\t\tspdlog::info(\"Helix decoder output resumed on stream {} at frame {}\", stream_index, frame_index);\n}\n"""
    return replace_once(text, old, new, "android_decoder.cpp decoded correlation")


TRANSFORMS = {
    Path("server/encoder/video_encoder.h"): transform_video_encoder_h,
    Path("server/encoder/video_encoder.cpp"): transform_video_encoder_cpp,
    Path("server/encoder/video_encoder_nvenc.cpp"): transform_nvenc,
    Path("client/decoder/helix_diagnostics.h"): transform_diag,
    Path("client/decoder/shard_accumulator.cpp"): transform_accumulator,
    Path("client/decoder/android/android_decoder.cpp"): transform_android,
}


def validate(outputs: dict[Path, str]) -> None:
    required = {
        Path("server/encoder/video_encoder.cpp"): [
            "HELIX_HEVC10_ENCODER_GATE",
            "HELIX_HEVC10_FAULT_PLAN",
            "HELIX_HEVC10_DROP",
            "HELIX_HEVC10_FAULT_SUMMARY",
            "shard.shard_idx == 0",
        ],
        Path("server/encoder/video_encoder_nvenc.cpp"): [
            "#include <cstdlib>",
            "#include <string_view>",
            "NV_ENC_HEVC_PROFILE_MAIN10_GUID",
            "HELIX_HEVC10_MAIN10_PROFILE",
            "inputBitDepth = bitDepth",
            "outputBitDepth = bitDepth",
        ],
        Path("client/decoder/helix_diagnostics.h"): [
            "hevc10_note_rtx_complete",
            "hevc10_note_decoded_image",
            "rtx_exact_decoded",
            "output_resumed_after_incomplete",
        ],
        Path("client/decoder/shard_accumulator.cpp"): [
            "HELIX_HEVC10_RTX_ASSEMBLED",
            "HELIX_HEVC10_INCOMPLETE",
            "hevc10_note_rtx_complete",
        ],
        Path("client/decoder/android/android_decoder.cpp"): [
            "HELIX_HEVC10_RTX_DECODED",
            "HELIX_HEVC10_OUTPUT_RESUMED",
            "HELIX_HEVC10_PROBE_SUMMARY",
        ],
    }
    for path, markers in required.items():
        for marker in markers:
            if marker not in outputs[path]:
                raise RuntimeError(f"{path}: missing marker {marker}")

    if outputs[Path("server/encoder/video_encoder.cpp")].count("HELIX_HEVC10_DROP") != 1:
        raise RuntimeError("drop marker count is not exactly one source site")
    if "sent_to_decoder == recovery" in "\n".join(outputs.values()):
        raise RuntimeError("forbidden recovery equivalence present")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    head = git("rev-parse", "HEAD")
    if head != BASE:
        raise RuntimeError(f"expected HEAD {BASE}, got {head}")
    if git("status", "--porcelain"):
        raise RuntimeError("working tree must be clean")

    originals = {path: path.read_text() for path in FILES}
    outputs = {path: TRANSFORMS[path](originals[path]) for path in FILES}
    validate(outputs)

    if args.check_only:
        print("CHECK_ONLY=PASS hevc10-decoder-recovery-v1 exact-base transactional")
        print(f"source_commit={BASE}")
        print("fault_contract=one-cached-shard0-withheld-per-eye ordinals=600,900 normal-gap-rtx-only")
        print("decoder_contract=exact-rtx-frame-AImage-plus-output-resume-after-incomplete-separated")
        print("pixel_cleanliness=NOT_ESTABLISHED")
        return 0

    for path, content in outputs.items():
        path.write_text(content)

    print("APPLY=PASS hevc10-decoder-recovery-v1")
    print(f"source_parent={BASE}")
    print("modified_files=" + ",".join(str(p) for p in FILES))
    print("fault_contract=one-cached-shard0-withheld-per-eye ordinals=600,900 normal-gap-rtx-only")
    print("decoder_contract=exact-rtx-frame-AImage-plus-output-resume-after-incomplete-separated")
    print("pixel_cleanliness=NOT_ESTABLISHED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
