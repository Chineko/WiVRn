#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn git checkout" >&2
    exit 2
fi
cd "${repo_root}"

expected_branch="helix-bounded-time-diverse-recovery"
base_commit="20616b623698e0d761450ad0e906fb35daf17877"

branch="$(git branch --show-current)"
if [[ "${branch}" != "${expected_branch}" ]]; then
    echo "error: expected branch ${expected_branch}, got ${branch:-DETACHED}" >&2
    exit 2
fi

if ! git merge-base --is-ancestor "${base_commit}" HEAD; then
    echo "error: branch is not descended from audited IDR-overlap base ${base_commit}" >&2
    exit 2
fi

tracked_paths=(
    server/encoder/idr_handler.cpp
    server/encoder/video_encoder.h
    server/encoder/video_encoder.cpp
)

if ! git diff --quiet -- "${tracked_paths[@]}" || ! git diff --cached --quiet -- "${tracked_paths[@]}"; then
    echo "error: prototype source paths already contain local changes; refusing to overlap them" >&2
    git status --short -- "${tracked_paths[@]}" >&2
    exit 2
fi

# Exact source identity gate. Do not apply this prototype to a different source state.
declare -A expected_blob=(
    [server/encoder/idr_handler.cpp]="5b72870fd6b97a13e20dfdd65dd1f74cbf20b2c7"
    [server/encoder/video_encoder.h]="eceb0a5a4a76d08ce223d7a0d7e81708f90df3c5"
    [server/encoder/video_encoder.cpp]="a7d3fa4acd26797ca87ab5f50252e67875ef8375"
)
for path in "${tracked_paths[@]}"; do
    actual="$(git hash-object "${path}")"
    if [[ "${actual}" != "${expected_blob[${path}]}" ]]; then
        echo "error: ${path} does not match audited source blob" >&2
        echo "expected ${expected_blob[${path}]}" >&2
        echo "actual   ${actual}" >&2
        exit 2
    fi
done

python3 <<'PY'
from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    p = Path(path)
    text = p.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"error: expected exactly one transform anchor in {path}, found {count}")
    p.write_text(text.replace(old, new, 1))

replace_once(
    "server/encoder/idr_handler.cpp",
    '''\t                   [this, &f](running & r) {\n\t\t                   if (not f.sent_to_decoder and f.frame_index >= r.last_ack and not is_non_ref_frame(f.frame_index))\n\t\t                   {''',
    '''\t                   [this, &f](running & r) {\n\t\t                   const bool is_non_ref =\n\t\t                           non_ref_frames[f.frame_index % non_ref_frames.size()] == f.frame_index;\n\t\t                   if (not f.sent_to_decoder and f.frame_index >= r.last_ack and not is_non_ref)\n\t\t                   {''')

replace_once(
    "server/encoder/idr_handler.cpp",
    '''bool default_idr_handler::is_non_ref_frame(uint64_t frame_index)\n{\n\treturn non_ref_frames[frame_index % non_ref_frames.size()] == frame_index;\n}''',
    '''bool default_idr_handler::is_non_ref_frame(uint64_t frame_index)\n{\n\tstd::unique_lock lock(mutex);\n\treturn non_ref_frames[frame_index % non_ref_frames.size()] == frame_index;\n}''')

replace_once(
    "server/encoder/video_encoder.h",
    '''\tuint64_t helix_gap_report_delay_total_us = 0;\n\tuint64_t helix_gap_report_delay_max_us = 0;\n\n\tbool retransmit_cached(uint64_t packet_sequence);''',
    '''\tuint64_t helix_gap_report_delay_total_us = 0;\n\tuint64_t helix_gap_report_delay_max_us = 0;\n\n\t// Helix bounded time-diverse recovery prototype. Protect complete, bounded\n\t// NVENC reference frames only; never send a partial recovery copy.\n\tstatic constexpr size_t helix_td_max_shards = 48;\n\tstatic constexpr uint64_t helix_td_budget_divisor = 5; // <= 20% fresh payload long-run\n\tstatic constexpr uint64_t helix_td_credit_cap_bytes =\n\t        helix_td_max_shards * to_headset::video_stream_data_shard::max_payload_size * 2;\n\tbool helix_td_enabled = false;\n\tuint64_t helix_td_credit_bytes = 0;\n\tstd::optional<uint64_t> helix_td_pending_frame;\n\tuint64_t helix_td_fresh_bytes = 0;\n\tuint64_t helix_td_replay_bytes = 0;\n\tuint64_t helix_td_reference_frames = 0;\n\tuint64_t helix_td_scheduled_frames = 0;\n\tuint64_t helix_td_replayed_frames = 0;\n\tuint64_t helix_td_replayed_shards = 0;\n\tuint64_t helix_td_skipped_oversize = 0;\n\tuint64_t helix_td_skipped_budget = 0;\n\tuint64_t helix_td_expired = 0;\n\tuint64_t helix_td_send_errors = 0;\n\n\tbool retransmit_cached(uint64_t packet_sequence);\n\tvoid helix_send_time_diverse_replay(uint64_t next_frame_idx);\n\tvoid helix_finish_time_diverse_frame(bool control);''')

replace_once(
    "server/encoder/video_encoder.cpp",
    '''        bitrate_multiplier(settings.bitrate_multiplier),\n        shared_sender(async_send ? sender::get() : nullptr),\n        idr(std::move(idr)),''',
    '''        bitrate_multiplier(settings.bitrate_multiplier),\n        shared_sender(async_send ? sender::get() : nullptr),\n        helix_td_enabled(settings.encoder_name == encoder_nvenc),\n        idr(std::move(idr)),''')

replace_once(
    "server/encoder/video_encoder.cpp",
    '''\t        static_cast<unsigned long long>(gap_report_delay_avg_us),\n\t        static_cast<unsigned long long>(helix_gap_report_delay_max_us));\n\n\thelix_log_pacing_summary(this);''',
    '''\t        static_cast<unsigned long long>(gap_report_delay_avg_us),\n\t        static_cast<unsigned long long>(helix_gap_report_delay_max_us));\n\n\tU_LOG_I(\n\t        "Helix time-diverse summary stream=%u enabled=%d fresh_bytes=%llu replay_bytes=%llu reference_frames=%llu scheduled=%llu replayed=%llu replayed_shards=%llu skipped_oversize=%llu skipped_budget=%llu expired=%llu send_errors=%llu credit=%llu",\n\t        stream_idx,\n\t        helix_td_enabled,\n\t        static_cast<unsigned long long>(helix_td_fresh_bytes),\n\t        static_cast<unsigned long long>(helix_td_replay_bytes),\n\t        static_cast<unsigned long long>(helix_td_reference_frames),\n\t        static_cast<unsigned long long>(helix_td_scheduled_frames),\n\t        static_cast<unsigned long long>(helix_td_replayed_frames),\n\t        static_cast<unsigned long long>(helix_td_replayed_shards),\n\t        static_cast<unsigned long long>(helix_td_skipped_oversize),\n\t        static_cast<unsigned long long>(helix_td_skipped_budget),\n\t        static_cast<unsigned long long>(helix_td_expired),\n\t        static_cast<unsigned long long>(helix_td_send_errors),\n\t        static_cast<unsigned long long>(helix_td_credit_bytes));\n\n\thelix_log_pacing_summary(this);''')

replace_once(
    "server/encoder/video_encoder.cpp",
    '''void video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)\n{''',
    '''void video_encoder::helix_send_time_diverse_replay(uint64_t next_frame_idx)\n{\n\tif (not helix_td_enabled or not helix_td_pending_frame)\n\t\treturn;\n\n\tconst uint64_t frame_idx = *helix_td_pending_frame;\n\thelix_td_pending_frame.reset();\n\tif (next_frame_idx != frame_idx + 1)\n\t{\n\t\t++helix_td_expired;\n\t\treturn;\n\t}\n\tif (not cnx or not cnx->has_stream())\n\t{\n\t\t++helix_td_expired;\n\t\treturn;\n\t}\n\n\tauto replay_started_at = helix_pacing_clock::now();\n\tuint64_t replayed_shards = 0;\n\tuint64_t replayed_bytes = 0;\n\tfor (const auto & entry: helix_rtx_cache)\n\t{\n\t\tif (entry.frame_idx < frame_idx)\n\t\t\tcontinue;\n\t\tif (entry.frame_idx > frame_idx)\n\t\t\tbreak;\n\n\t\tif (replayed_shards > 0)\n\t\t{\n\t\t\tauto target_send_time = replay_started_at + helix_shard_spacing * replayed_shards;\n\t\t\tstd::this_thread::sleep_until(target_send_time);\n\t\t}\n\n\t\tto_headset::video_stream_data_shard packet{};\n\t\tpacket.stream_item_idx = stream_idx;\n\t\tpacket.frame_idx = entry.frame_idx;\n\t\tpacket.packet_sequence = entry.packet_sequence;\n\t\tpacket.retransmission = true;\n\t\tpacket.shard_idx = entry.shard_idx;\n\t\tpacket.view_info = entry.view_info;\n\t\tpacket.timing_info = entry.timing_info;\n\t\tpacket.payload = entry.payload;\n\n\t\ttry\n\t\t{\n\t\t\tcnx->send_stream(std::move(packet));\n\t\t\t++replayed_shards;\n\t\t\treplayed_bytes += entry.payload.size();\n\t\t}\n\t\tcatch (...)\n\t\t{\n\t\t\t++helix_td_send_errors;\n\t\t}\n\t}\n\n\tif (replayed_shards == 0)\n\t{\n\t\t++helix_td_expired;\n\t\treturn;\n\t}\n\n\t++helix_td_replayed_frames;\n\thelix_td_replayed_shards += replayed_shards;\n\thelix_td_replay_bytes += replayed_bytes;\n\tU_LOG_I(\n\t        "Helix time-diverse replay stream=%u frame=%llu before_frame=%llu shards=%llu bytes=%llu span=%lluus",\n\t        stream_idx,\n\t        static_cast<unsigned long long>(frame_idx),\n\t        static_cast<unsigned long long>(next_frame_idx),\n\t        static_cast<unsigned long long>(replayed_shards),\n\t        static_cast<unsigned long long>(replayed_bytes),\n\t        static_cast<unsigned long long>(helix_duration_us(helix_pacing_clock::now(), replay_started_at)));\n}\n\nvoid video_encoder::helix_finish_time_diverse_frame(bool control)\n{\n\tif (not helix_td_enabled or control)\n\t\treturn;\n\n\thelix_td_fresh_bytes += helix_current_frame_bytes;\n\thelix_td_credit_bytes = std::min<uint64_t>(\n\t        helix_td_credit_cap_bytes,\n\t        helix_td_credit_bytes + helix_current_frame_bytes / helix_td_budget_divisor);\n\n\tauto * handler = dynamic_cast<default_idr_handler *>(idr.get());\n\tif (not handler or handler->is_non_ref_frame(shard.frame_idx))\n\t\treturn;\n\n\t++helix_td_reference_frames;\n\tif (helix_current_frame_shards > helix_td_max_shards)\n\t{\n\t\t++helix_td_skipped_oversize;\n\t\treturn;\n\t}\n\tif (helix_current_frame_bytes > helix_td_credit_bytes)\n\t{\n\t\t++helix_td_skipped_budget;\n\t\treturn;\n\t}\n\n\thelix_td_credit_bytes -= helix_current_frame_bytes;\n\thelix_td_pending_frame = shard.frame_idx;\n\t++helix_td_scheduled_frames;\n}\n\nvoid video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)\n{''')

replace_once(
    "server/encoder/video_encoder.cpp",
    '''\tstd::lock_guard lock(mutex);\n\tif (shard.shard_idx == 0)\n\t{\n\t\t// One SendData call per NAL; span the whole frame, not each call.''',
    '''\tstd::lock_guard lock(mutex);\n\tif (shard.shard_idx == 0)\n\t{\n\t\tif (control)\n\t\t{\n\t\t\tif (helix_td_pending_frame)\n\t\t\t\t++helix_td_expired;\n\t\t\thelix_td_pending_frame.reset();\n\t\t}\n\t\telse\n\t\t{\n\t\t\thelix_send_time_diverse_replay(shard.frame_idx);\n\t\t}\n\n\t\t// One SendData call per NAL; span the whole frame, not each call.''')

replace_once(
    "server/encoder/video_encoder.cpp",
    '''\t\tauto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);\n\t\thelix_note_frame_sent(this, shard.frame_idx, helix_current_frame_bytes, helix_current_frame_shards, send_span_us);\n\t\twivrn::trace::cpu_end''',
    '''\t\tauto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);\n\t\thelix_note_frame_sent(this, shard.frame_idx, helix_current_frame_bytes, helix_current_frame_shards, send_span_us);\n\t\thelix_finish_time_diverse_frame(control);\n\t\twivrn::trace::cpu_end''')
PY

echo "Applied exact bounded time-diverse recovery source transforms."

git diff --check -- "${tracked_paths[@]}"

if command -v clang-format >/dev/null 2>&1; then
    clang-format --dry-run --Werror "${tracked_paths[@]}"
else
    echo "note: clang-format not found; compile gate will still run" >&2
fi

# CMakePresets.json defines the server preset and build-server binary directory.
if [[ ! -f build-server/build.ninja ]]; then
    cmake --preset server
fi

cmake --build build-server --target wivrn-server -j

echo
echo "PASS: bounded recovery source transformed and wivrn-server compiled."
echo "No headset/runtime validation has been performed."
echo "Working tree intentionally contains the audited prototype source diff for inspection/commit."
git status --short -- "${tracked_paths[@]}"
