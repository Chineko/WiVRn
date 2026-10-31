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
    new = """\tuint64_t helix_rtx_send_errors = 0;\n\tuint64_t helix_initial_send_errors = 0;\n\n\t// Deterministic HEVC10 recovery canary. One fresh shard-0 is withheld once\n\t// per eye after warmup, but retained in the ordinary RTX cache.\n\tbool helix_hevc10_fault_enabled = false;\n\tuint64_t helix_hevc10_frame_ordinal = 0;\n\tuint64_t helix_hevc10_fault_target_ordinal = 0;\n\tbool helix_hevc10_fault_current_frame = false;\n\tbool helix_hevc10_fault_dropped = false;\n\tuint64_t helix_hevc10_faults_injected = 0;\n\tstd::optional<uint64_t> helix_hevc10_fault_packet_sequence;\n\tstd::optional<uint64_t> helix_hevc10_fault_frame_index;\n\tuint64_t helix_hevc10_exact_rtx_sent = 0;\n\n\tuint64_t helix_gap_reports = 0;\n"""
    return replace_once(text, old, new, "video_encoder.h HEVC10 state")


def transform_video_encoder_cpp(text: str) -> str:
    text = replace_once(
        text,
        "#include <array>\n#include <chrono>\n#include <string>\n",
        "#include <array>\n#include <chrono>\n#include <cstdlib>\n#include <cstring>\n#include <string>\n",
        "video_encoder.cpp includes",
    )

    old = """std::unique_ptr<video_encoder> video_encoder::create(\n        wivrn::vk_bundle & wivrn_vk,\n        const encoder_settings & settings,\n        uint8_t stream_idx)\n{\n\tusing namespace std::string_literals;\n\tstd::unique_ptr<video_encoder> res;\n"""
    new = old + """\n\tconst char * helix_hevc10 = std::getenv(\"HELIX_HEVC10_RECOVERY\");\n\tconst bool helix_hevc10_enabled = helix_hevc10 && std::strcmp(helix_hevc10, \"1\") == 0;\n\tif (helix_hevc10_enabled && stream_idx < 2)\n\t{\n\t\tif (settings.encoder_name != encoder_nvenc || settings.codec != video_codec::h265 || settings.bit_depth != 10)\n\t\t\tthrow std::runtime_error(\"HELIX_HEVC10_RECOVERY requires NVENC H.265 Main10 on both eye streams\");\n\t\tU_LOG_I(\"HELIX_HEVC10_ENCODER_GATE stream=%u encoder=nvenc codec=h265 bit_depth=10\", stream_idx);\n\t}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp encoder gate")

    old = """\tU_LOG_I(\"Helix pacing telemetry %s stream=%u shard_spacing=%lluus\", helix_pacing_telemetry_version, stream_idx, static_cast<unsigned long long>(helix_shard_spacing.count()));\n}\n"""
    new = """\tU_LOG_I(\"Helix pacing telemetry %s stream=%u shard_spacing=%lluus\", helix_pacing_telemetry_version, stream_idx, static_cast<unsigned long long>(helix_shard_spacing.count()));\n\n\tconst char * helix_hevc10 = std::getenv(\"HELIX_HEVC10_RECOVERY\");\n\thelix_hevc10_fault_enabled = helix_hevc10 && std::strcmp(helix_hevc10, \"1\") == 0 && stream_idx < 2;\n\tif (helix_hevc10_fault_enabled)\n\t{\n\t\thelix_hevc10_fault_target_ordinal = stream_idx == 0 ? 600 : 900;\n\t\tU_LOG_I(\"HELIX_HEVC10_FAULT_PLAN stream=%u target_ordinal=%llu shard=0\",\n\t\t        stream_idx,\n\t\t        static_cast<unsigned long long>(helix_hevc10_fault_target_ordinal));\n\t}\n}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp fault plan")

    old = """\tU_LOG_I(\n\t        \"Helix time-diverse summary stream=%u enabled=%d fresh_bytes=%llu replay_bytes=%llu reference_frames=%llu scheduled=%llu replayed=%llu replayed_shards=%llu skipped_oversize=%llu skipped_budget=%llu expired=%llu send_errors=%llu credit=%llu\",\n"""
    new = """\tif (helix_hevc10_fault_enabled)\n\t{\n\t\tU_LOG_I(\"HELIX_HEVC10_FAULT_SUMMARY stream=%u target_ordinal=%llu injected=%llu exact_rtx_sent=%llu pending_sequence=%s\",\n\t\t        stream_idx,\n\t\t        static_cast<unsigned long long>(helix_hevc10_fault_target_ordinal),\n\t\t        static_cast<unsigned long long>(helix_hevc10_faults_injected),\n\t\t        static_cast<unsigned long long>(helix_hevc10_exact_rtx_sent),\n\t\t        helix_hevc10_fault_packet_sequence ? \"yes\" : \"no\");\n\t}\n\n""" + old
    text = replace_once(text, old, new, "video_encoder.cpp fault summary")

    old = """\tif (shard.shard_idx == 0)\n\t{\n\t\tif (control)\n"""
    new = """\tif (shard.shard_idx == 0)\n\t{\n\t\tif (helix_hevc10_fault_enabled && !control)\n\t\t{\n\t\t\t++helix_hevc10_frame_ordinal;\n\t\t\thelix_hevc10_fault_current_frame = helix_hevc10_frame_ordinal == helix_hevc10_fault_target_ordinal;\n\t\t\thelix_hevc10_fault_dropped = false;\n\t\t}\n\n\t\tif (control)\n"""
    text = replace_once(text, old, new, "video_encoder.cpp frame ordinal")

    old = """\t\thelix_current_frame_bytes += std::distance(begin, next);\n\t\thelix_current_frame_shards++;\n\t\ttry\n\t\t{\n\t\t\tif (control)\n\t\t\t\tcnx->send_control(to_headset::video_stream_data_shard{shard});\n\t\t\telse\n\t\t\t\tcnx->send_stream(to_headset::video_stream_data_shard{shard});\n\t\t}\n\t\tcatch (...)\n\t\t{\n\t\t\t++helix_initial_send_errors;\n\t\t\t// Ignore network errors\n\t\t}\n"""
    new = """\t\thelix_current_frame_bytes += std::distance(begin, next);\n\t\thelix_current_frame_shards++;\n\n\t\tconst bool helix_hevc10_drop =\n\t\t        helix_hevc10_fault_enabled && helix_hevc10_fault_current_frame &&\n\t\t        !helix_hevc10_fault_dropped && !control &&\n\t\t        shard.packet_sequence != 0 && shard.shard_idx == 0;\n\t\tif (helix_hevc10_drop)\n\t\t{\n\t\t\thelix_hevc10_fault_dropped = true;\n\t\t\t++helix_hevc10_faults_injected;\n\t\t\thelix_hevc10_fault_packet_sequence = shard.packet_sequence;\n\t\t\thelix_hevc10_fault_frame_index = shard.frame_idx;\n\t\t\tU_LOG_W(\"HELIX_HEVC10_DROP stream=%u ordinal=%llu frame=%llu shard=0 packet_sequence=%llu cached=1\",\n\t\t\t        stream_idx,\n\t\t\t        static_cast<unsigned long long>(helix_hevc10_frame_ordinal),\n\t\t\t        static_cast<unsigned long long>(shard.frame_idx),\n\t\t\t        static_cast<unsigned long long>(shard.packet_sequence));\n\t\t}\n\t\telse\n\t\t{\n\t\t\ttry\n\t\t\t{\n\t\t\t\tif (control)\n\t\t\t\t\tcnx->send_control(to_headset::video_stream_data_shard{shard});\n\t\t\t\telse\n\t\t\t\t\tcnx->send_stream(to_headset::video_stream_data_shard{shard});\n\t\t\t}\n\t\t\tcatch (...)\n\t\t\t{\n\t\t\t\t++helix_initial_send_errors;\n\t\t\t\t// Ignore network errors\n\t\t\t}\n\t\t}\n"""
    text = replace_once(text, old, new, "video_encoder.cpp deterministic drop")

    old = """\t\t++helix_rtx_sent;\n\t\thelix_rtx_bytes += payload_bytes;\n\t\thelix_rtx_send_time_total_us += send_us;\n\t\thelix_rtx_send_time_max_us = std::max(helix_rtx_send_time_max_us, send_us);\n\t\treturn true;\n"""
    new = """\t\t++helix_rtx_sent;\n\t\thelix_rtx_bytes += payload_bytes;\n\t\thelix_rtx_send_time_total_us += send_us;\n\t\thelix_rtx_send_time_max_us = std::max(helix_rtx_send_time_max_us, send_us);\n\t\tif (helix_hevc10_fault_enabled && helix_hevc10_fault_packet_sequence &&\n\t\t    packet_sequence == *helix_hevc10_fault_packet_sequence)\n\t\t{\n\t\t\t++helix_hevc10_exact_rtx_sent;\n\t\t\tU_LOG_I(\"HELIX_HEVC10_RTX_SENT stream=%u frame=%llu packet_sequence=%llu exact_canary=1\",\n\t\t\t        stream_idx,\n\t\t\t        static_cast<unsigned long long>(helix_hevc10_fault_frame_index.value_or(0)),\n\t\t\t        static_cast<unsigned long long>(packet_sequence));\n\t\t\thelix_hevc10_fault_packet_sequence.reset();\n\t\t}\n\t\treturn true;\n"""
    return replace_once(text, old, new, "video_encoder.cpp exact RTX marker")


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
    anchor = """inline network_snapshot snapshot(uint8_t stream_index)\n{\n\tauto & state = network(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tauto now = clock::now();\n\treturn {\n\t        .completed_frames = state.completed_frames,\n\t        .incomplete_frames = state.incomplete_frames,\n\t        .zero_shard_frames = state.zero_shard_frames,\n\t        .missing_shards = state.missing_shards,\n\t        .old_shards = state.old_shards,\n\t        .frame_jump_events = state.frame_jump_events,\n\t        .skipped_frames = state.skipped_frames,\n\t        .last_assembly_us = state.last_assembly_us,\n\t        .max_assembly_us = state.max_assembly_us,\n\t        .since_incomplete_us = age_us(now, state.last_incomplete),\n\t        .since_old_shard_us = age_us(now, state.last_old_shard),\n\t        .since_frame_jump_us = age_us(now, state.last_frame_jump),\n\t        .assembly_hist = state.assembly_hist,\n\t};\n}\n\n"""
    addition = anchor + """constexpr size_t hevc10_probe_slots = 8;\n\nstruct hevc10_probe_snapshot\n{\n\tuint64_t rtx_assembled = 0;\n\tuint64_t rtx_media_output = 0;\n\tuint64_t image_after_rtx = 0;\n\tuint64_t overflow = 0;\n\tsize_t pending_media = 0;\n\tsize_t pending_image = 0;\n};\n\nstruct hevc10_probe_state\n{\n\tstd::mutex mutex;\n\tstd::array<std::optional<uint64_t>, hevc10_probe_slots> pending_media{};\n\tstd::array<std::optional<uint64_t>, hevc10_probe_slots> pending_image{};\n\tuint64_t rtx_assembled = 0;\n\tuint64_t rtx_media_output = 0;\n\tuint64_t image_after_rtx = 0;\n\tuint64_t overflow = 0;\n};\n\ninline std::array<hevc10_probe_state, stream_count> & hevc10_probe_states()\n{\n\tstatic std::array<hevc10_probe_state, stream_count> states;\n\treturn states;\n}\n\ninline hevc10_probe_state & hevc10_probe(uint8_t stream_index)\n{\n\treturn hevc10_probe_states()[std::min<size_t>(stream_index, stream_count - 1)];\n}\n\ntemplate <size_t N>\ninline bool hevc10_insert_unique(std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)\n{\n\tfor (const auto & slot: slots)\n\t\tif (slot && *slot == frame_index)\n\t\t\treturn true;\n\tfor (auto & slot: slots)\n\t{\n\t\tif (!slot)\n\t\t{\n\t\t\tslot = frame_index;\n\t\t\treturn true;\n\t\t}\n\t}\n\treturn false;\n}\n\ntemplate <size_t N>\ninline bool hevc10_erase_exact(std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)\n{\n\tfor (auto & slot: slots)\n\t{\n\t\tif (slot && *slot == frame_index)\n\t\t{\n\t\t\tslot.reset();\n\t\t\treturn true;\n\t\t}\n\t}\n\treturn false;\n}\n\ntemplate <size_t N>\ninline std::optional<uint64_t> hevc10_erase_oldest_leq(\n        std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)\n{\n\tstd::optional<size_t> best;\n\tfor (size_t i = 0; i < N; ++i)\n\t{\n\t\tif (!slots[i] || *slots[i] > frame_index)\n\t\t\tcontinue;\n\t\tif (!best || *slots[i] < *slots[*best])\n\t\t\tbest = i;\n\t}\n\tif (!best)\n\t\treturn {};\n\tauto recovered = slots[*best];\n\tslots[*best].reset();\n\treturn recovered;\n}\n\ninline void hevc10_note_rtx_assembled(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tstate.rtx_assembled++;\n\tif (!hevc10_insert_unique(state.pending_media, frame_index))\n\t\tstate.overflow++;\n}\n\ninline bool hevc10_note_media_output(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tif (!hevc10_erase_exact(state.pending_media, frame_index))\n\t\treturn false;\n\tstate.rtx_media_output++;\n\tif (!hevc10_insert_unique(state.pending_image, frame_index))\n\t\tstate.overflow++;\n\treturn true;\n}\n\ninline std::optional<uint64_t> hevc10_note_image(uint8_t stream_index, uint64_t frame_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tauto recovered = hevc10_erase_oldest_leq(state.pending_image, frame_index);\n\tif (recovered)\n\t\tstate.image_after_rtx++;\n\treturn recovered;\n}\n\ninline hevc10_probe_snapshot hevc10_probe_snapshot_for(uint8_t stream_index)\n{\n\tauto & state = hevc10_probe(stream_index);\n\tstd::scoped_lock lock(state.mutex);\n\tsize_t pending_media = 0;\n\tsize_t pending_image = 0;\n\tfor (const auto & slot: state.pending_media)\n\t\tpending_media += bool(slot);\n\tfor (const auto & slot: state.pending_image)\n\t\tpending_image += bool(slot);\n\treturn {\n\t        .rtx_assembled = state.rtx_assembled,\n\t        .rtx_media_output = state.rtx_media_output,\n\t        .image_after_rtx = state.image_after_rtx,\n\t        .overflow = state.overflow,\n\t        .pending_media = pending_media,\n\t        .pending_image = pending_image,\n\t};\n}\n\n"""
    return replace_once(text, anchor, addition, "helix_diagnostics.h bounded HEVC10 ledger")


def transform_accumulator(text: str) -> str:
    old = """\t// Try to extract a frame\n\tdecoder_->frame_completed(current.feedback, *data_shards.front()->view_info);\n\n\tif (current.received_retransmission)\n\t{\n\t\tif (auto scene = weak_scene.lock())\n\t\t\tscene->helix_note_rtx_frame_recovered(current.feedback.stream_index);\n\t}\n"""
    new = """\t// Record retransmission completion before handing the frame to MediaCodec,\n\t// so an asynchronous output callback cannot race ahead of the probe.\n\tif (current.received_retransmission)\n\t{\n\t\thelix_diag::hevc10_note_rtx_assembled(current.feedback.stream_index, current.feedback.frame_index);\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_ASSEMBLED stream={} frame={}\",\n\t\t             current.feedback.stream_index, current.feedback.frame_index);\n\t}\n\n\t// Try to extract a frame\n\tdecoder_->frame_completed(current.feedback, *data_shards.front()->view_info);\n\n\tif (current.received_retransmission)\n\t{\n\t\tif (auto scene = weak_scene.lock())\n\t\t\tscene->helix_note_rtx_frame_recovered(current.feedback.stream_index);\n\t}\n"""
    return replace_once(text, old, new, "shard_accumulator.cpp pre-decode RTX marker")


def transform_android(text: str) -> str:
    old = """\tauto network = wivrn::helix_diag::snapshot(stream_index);\n\tstd::scoped_lock lock(state->mutex);\n"""
    new = """\tauto network = wivrn::helix_diag::snapshot(stream_index);\n\tauto hevc10_probe = wivrn::helix_diag::hevc10_probe_snapshot_for(stream_index);\n\tstd::scoped_lock lock(state->mutex);\n"""
    text = replace_once(text, old, new, "android_decoder.cpp probe snapshot")

    old = """\tspdlog::info(\n\t        \"Helix diagnostic summary stream {}: media_outputs={} submit_to_media(avg/max)={}/{}us output_gap_max={}us complete_interval(avg/last/max)={}/{}/{}us release_to_image(avg/max)={}/{}us image_processing(avg/max)={}/{}us hist_submit_image(<5/10/20/40/80/>80ms)={}/{}/{}/{}/{}/{} hist_submit_media={}/{}/{}/{}/{}/{} hist_output_gap={}/{}/{}/{}/{}/{} hist_complete_interval={}/{}/{}/{}/{}/{} hist_release_image={}/{}/{}/{}/{}/{} hist_image_processing={}/{}/{}/{}/{}/{} network(complete/incomplete/zero/missing/old/jumps/skipped)={}/{}/{}/{}/{}/{}/{} assembly(last/max)={}/{}us hist_assembly={}/{}/{}/{}/{}/{}\",\n"""
    new = """\tspdlog::info(\n\t        \"HELIX_HEVC10_PROBE_SUMMARY stream={} rtx_assembled={} media_exact={} image_after={} overflow={} pending_media={} pending_image={}\",\n\t        stream_index,\n\t        hevc10_probe.rtx_assembled,\n\t        hevc10_probe.rtx_media_output,\n\t        hevc10_probe.image_after_rtx,\n\t        hevc10_probe.overflow,\n\t        hevc10_probe.pending_media,\n\t        hevc10_probe.pending_image);\n\n""" + old
    text = replace_once(text, old, new, "android_decoder.cpp probe summary")

    old = """\t\tassert(info->feedback.frame_index == frame_index);\n\t\thelix_note_decoded(this, stream_index, frame_index);\n\n\t\tauto vk_data = map_hardware_buffer(image.get());\n"""
    new = """\t\tassert(info->feedback.frame_index == frame_index);\n\t\thelix_note_decoded(this, stream_index, frame_index);\n\t\tif (auto recovered = wivrn::helix_diag::hevc10_note_image(stream_index, frame_index))\n\t\t{\n\t\t\tspdlog::info(\"HELIX_HEVC10_IMAGE_AFTER_RTX stream={} recovered_frame={} image_frame={} exact={}\",\n\t\t\t             stream_index, *recovered, frame_index, frame_index == *recovered);\n\t\t}\n\n\t\tauto vk_data = map_hardware_buffer(image.get());\n"""
    text = replace_once(text, old, new, "android_decoder.cpp AImage marker")

    old = """\tuint64_t frame_index = bufferInfo && bufferInfo->presentationTimeUs >= 0 ? static_cast<uint64_t>(bufferInfo->presentationTimeUs) / 10'000 : 0;\n\thelix_note_media_output(self, frame_index);\n\tself->jobs.push([=]() {\n"""
    new = """\tuint64_t frame_index = bufferInfo && bufferInfo->presentationTimeUs >= 0 ? static_cast<uint64_t>(bufferInfo->presentationTimeUs) / 10'000 : 0;\n\thelix_note_media_output(self, frame_index);\n\tif (wivrn::helix_diag::hevc10_note_media_output(self->stream_index, frame_index))\n\t\tspdlog::info(\"HELIX_HEVC10_RTX_MEDIA_OUTPUT stream={} frame={} exact_recovered_frame=1\", self->stream_index, frame_index);\n\tself->jobs.push([=]() {\n"""
    return replace_once(text, old, new, "android_decoder.cpp exact MediaCodec marker")


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
            "HELIX_HEVC10_RTX_SENT",
            "HELIX_HEVC10_FAULT_SUMMARY",
            "shard.shard_idx == 0",
            "helix_hevc10_fault_packet_sequence = shard.packet_sequence",
        ],
        Path("server/encoder/video_encoder_nvenc.cpp"): [
            "NV_ENC_HEVC_PROFILE_MAIN10_GUID",
            "HELIX_HEVC10_MAIN10_PROFILE",
            "inputBitDepth = bitDepth",
            "outputBitDepth = bitDepth",
            "#include <cstdlib>",
            "#include <string_view>",
        ],
        Path("client/decoder/helix_diagnostics.h"): [
            "hevc10_probe_slots = 8",
            "pending_media",
            "pending_image",
            "hevc10_note_rtx_assembled",
            "hevc10_note_media_output",
            "hevc10_note_image",
        ],
        Path("client/decoder/shard_accumulator.cpp"): [
            "HELIX_HEVC10_RTX_ASSEMBLED",
            "hevc10_note_rtx_assembled",
            "before handing the frame to MediaCodec",
        ],
        Path("client/decoder/android/android_decoder.cpp"): [
            "HELIX_HEVC10_RTX_MEDIA_OUTPUT",
            "HELIX_HEVC10_IMAGE_AFTER_RTX",
            "HELIX_HEVC10_PROBE_SUMMARY",
            "hevc10_note_media_output(self->stream_index, frame_index)",
        ],
    }
    for path, markers in required.items():
        for marker in markers:
            if marker not in outputs[path]:
                raise RuntimeError(f"{path}: missing marker {marker}")

    joined = "\n".join(outputs.values())
    for forbidden in [
        "HELIX_HEVC10_RTX_DECODED",
        "sent_to_decoder == recovery",
        "pixel_cleanliness=PASS",
    ]:
        if forbidden in joined:
            raise RuntimeError(f"forbidden stale/overclaim marker present: {forbidden}")

    if outputs[Path("server/encoder/video_encoder.cpp")].count("HELIX_HEVC10_DROP") != 1:
        raise RuntimeError("HEVC10 drop source-site count is not exactly one")
    if outputs[Path("client/decoder/shard_accumulator.cpp")].find("hevc10_note_rtx_assembled") > outputs[Path("client/decoder/shard_accumulator.cpp")].find("decoder_->frame_completed"):
        raise RuntimeError("RTX probe is not ordered before decoder frame_completed")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()

    if git("rev-parse", "HEAD") != BASE:
        raise RuntimeError(f"expected HEAD {BASE}, got {git('rev-parse', 'HEAD')}")
    if git("status", "--porcelain"):
        raise RuntimeError("working tree must be clean")

    originals = {path: path.read_text() for path in FILES}
    outputs = {path: TRANSFORMS[path](originals[path]) for path in FILES}
    validate(outputs)

    if args.check_only:
        print("CHECK_ONLY=PASS hevc10-decoder-recovery-v2 exact-base transactional")
        print(f"source_commit={BASE}")
        print("fault_contract=one-cached-shard0-withheld-per-eye ordinals=600,900 exact-rtx-send-bound")
        print("decoder_contract=rtx-assembled-before-submit exact-MediaCodec-output bounded-AImage-after-ledger")
        print("probe_slots=8 overflow-must-remain-zero")
        print("pixel_cleanliness=NOT_ESTABLISHED")
        return 0

    for path, content in outputs.items():
        path.write_text(content)

    print("APPLY=PASS hevc10-decoder-recovery-v2")
    print(f"source_parent={BASE}")
    print("modified_files=" + ",".join(str(p) for p in FILES))
    print("fault_contract=one-cached-shard0-withheld-per-eye ordinals=600,900 exact-rtx-send-bound")
    print("decoder_contract=rtx-assembled-before-submit exact-MediaCodec-output bounded-AImage-after-ledger")
    print("probe_slots=8 overflow-must-remain-zero")
    print("pixel_cleanliness=NOT_ESTABLISHED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
