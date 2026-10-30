#!/usr/bin/env python3
from pathlib import Path
import subprocess
import sys

PATH = "server/helix_synthetic_transport.cpp"
EXPECTED_BLOB = "ce1294eb26d6fbef01d13cebe0345d8ac22be6d3"


def blob(path: str) -> str:
    return subprocess.check_output(["git", "hash-object", path], text=True).strip()


def replace_once(text: str, old: str, new: str) -> str:
    count = text.count(old)
    if count != 1:
        raise RuntimeError(f"expected one anchor, found {count}: {old[:80]!r}")
    return text.replace(old, new, 1)


def main() -> int:
    actual = blob(PATH)
    if actual != EXPECTED_BLOB:
        raise RuntimeError(f"{PATH}: blob mismatch: expected {EXPECTED_BLOB}, got {actual}")

    original = Path(PATH).read_text()
    text = original

    text = replace_once(
        text,
        "\tuint64_t recorded_good = 0;\n\tuint64_t catastrophic = 0;",
        "\tuint64_t recorded_good = 0;\n"
        "\tuint64_t envelope_total = 0;\n"
        "\tuint64_t envelope_good = 0;\n"
        "\tuint64_t ordering_total = 0;\n"
        "\tuint64_t ordering_good = 0;\n"
        "\tuint64_t rtx_total = 0;\n"
        "\tuint64_t rtx_good = 0;\n"
        "\tuint64_t catastrophic = 0;",
    )

    text = replace_once(
        text,
        "\tvoid send_frame(const packet_plan & plan)\n\t{",
        "\tuint64_t reserve_sequence(uint8_t stream)\n"
        "\t{\n"
        "\t\treturn ++packet_sequence.at(stream);\n"
        "\t}\n\n"
        "\tvoid send_explicit_shard(uint8_t stream, uint64_t frame_idx, uint16_t shard_idx, uint64_t sequence, bool retransmission = false)\n"
        "\t{\n"
        "\t\tif (stop_token.stop_requested())\n"
        "\t\t\tthrow std::runtime_error(\"synthetic transport cancelled\");\n\n"
        "\t\tto_headset::video_stream_data_shard packet{};\n"
        "\t\tpacket.stream_item_idx = stream;\n"
        "\t\tpacket.frame_idx = frame_idx;\n"
        "\t\tpacket.packet_sequence = sequence;\n"
        "\t\tpacket.retransmission = retransmission;\n"
        "\t\tpacket.shard_idx = shard_idx;\n"
        "\t\tif (shard_idx == 0)\n"
        "\t\t\tpacket.view_info = make_view_info();\n"
        "\t\tif (shard_idx == shards_per_frame - 1)\n"
        "\t\t\tpacket.timing_info = to_headset::video_stream_data_shard::timing_info_t{};\n"
        "\t\tpacket.payload = std::span<uint8_t>{payload};\n"
        "\t\tconnection.send_stream(std::move(packet));\n"
        "\t\tstd::this_thread::sleep_for(send_spacing);\n"
        "\t}\n\n"
        "\tvoid send_frame(const packet_plan & plan)\n\t{",
    )

    helper_anchor = "\n} // namespace\n\nint run(wivrn_connection & connection, std::stop_token stop_token)"
    helpers = r'''

bool run_duplicate_case(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t frame)
{
	observation obs;
	const uint64_t duplicate_sequence = tx.reserve_sequence(stream);
	tx.send_explicit_shard(stream, frame, 0, duplicate_sequence);
	tx.send_explicit_shard(stream, frame, 0, duplicate_sequence);
	for (uint16_t shard = 1; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool good = feedback_success(obs, stream, frame);
	U_LOG_I("HELIX_TRANSPORT_TORTURE case=duplicate stream=%u frame=%llu pass=%d feedback=%zu gaps=%zu rtx=%zu",
	        stream, static_cast<unsigned long long>(frame), good, obs.feedback.size(), obs.gaps.size(), obs.rtx.size());
	return good;
}

bool run_reorder_case(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t frame)
{
	observation obs;
	for (uint16_t shard = 0; shard < 10; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));
	const uint64_t delayed_sequence = tx.reserve_sequence(stream);
	const uint64_t exposing_sequence = tx.reserve_sequence(stream);
	tx.send_explicit_shard(stream, frame, 11, exposing_sequence);
	tx.send_explicit_shard(stream, frame, 10, delayed_sequence);
	for (uint16_t shard = 12; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool good = feedback_success(obs, stream, frame) && gap_covers(obs, stream, delayed_sequence, 1);
	U_LOG_I("HELIX_TRANSPORT_TORTURE case=reorder stream=%u frame=%llu pass=%d delayed_sequence=%llu feedback=%zu gaps=%zu rtx=%zu",
	        stream,
	        static_cast<unsigned long long>(frame),
	        good,
	        static_cast<unsigned long long>(delayed_sequence),
	        obs.feedback.size(),
	        obs.gaps.size(),
	        obs.rtx.size());
	return good;
}

bool run_late_old_case(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t frame)
{
	observation obs;
	for (uint16_t shard = 0; shard < 5; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 6; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));

	tx.send_frame(packet_plan{.stream = stream, .frame_idx = frame + 1});
	collect(connection, obs, per_scenario_timeout);

	// Deliver the missing shard only after the receiver has advanced past this frame.
	tx.send_explicit_shard(stream, frame, 5, held_sequence);
	collect(connection, obs, 50ms);

	const bool no_rtx_request = std::ranges::none_of(obs.rtx, [&](const auto & request) {
		return request.stream_index == stream && request.packet_sequence == held_sequence;
	});
	const bool good = feedback_incomplete(obs, stream, frame) && feedback_success(obs, stream, frame + 1) &&
	                  gap_covers(obs, stream, held_sequence, 1) && no_rtx_request;
	U_LOG_I("HELIX_TRANSPORT_TORTURE case=late_old stream=%u frame=%llu pass=%d held_sequence=%llu no_rtx=%d feedback=%zu gaps=%zu rtx=%zu",
	        stream,
	        static_cast<unsigned long long>(frame),
	        good,
	        static_cast<unsigned long long>(held_sequence),
	        no_rtx_request,
	        obs.feedback.size(),
	        obs.gaps.size(),
	        obs.rtx.size());
	return good;
}

bool run_frame_jump_case(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t frame)
{
	observation obs;
	const uint64_t jumped = frame + 3;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = jumped});
	collect(connection, obs, per_scenario_timeout);
	const bool good = feedback_incomplete(obs, stream, frame) && feedback_incomplete(obs, stream, frame + 1) &&
	                  feedback_success(obs, stream, jumped);
	U_LOG_I("HELIX_TRANSPORT_TORTURE case=frame_jump stream=%u current=%llu jumped=%llu pass=%d feedback=%zu gaps=%zu rtx=%zu",
	        stream,
	        static_cast<unsigned long long>(frame),
	        static_cast<unsigned long long>(jumped),
	        good,
	        obs.feedback.size(),
	        obs.gaps.size(),
	        obs.rtx.size());
	return good;
}

bool run_rtx_rescue_case(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t frame)
{
	observation obs;
	// Hold shard 0. Because no view_info for this frame has arrived yet, production
	// RTX logic treats the one-shard same-frame gap as deadline-eligible.
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 1; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, frame, shard, tx.reserve_sequence(stream));
	collect(connection, obs, 150ms);

	const bool requested = std::ranges::any_of(obs.rtx, [&](const auto & request) {
		return request.stream_index == stream && request.packet_sequence == held_sequence;
	});
	if (requested)
	{
		tx.send_explicit_shard(stream, frame, 0, held_sequence, true);
		collect(connection, obs, per_scenario_timeout);
	}

	const bool good = requested && feedback_success(obs, stream, frame);
	U_LOG_I("HELIX_TRANSPORT_TORTURE case=rtx_rescue stream=%u frame=%llu pass=%d requested=%d held_sequence=%llu feedback=%zu gaps=%zu rtx=%zu",
	        stream,
	        static_cast<unsigned long long>(frame),
	        good,
	        requested,
	        static_cast<unsigned long long>(held_sequence),
	        obs.feedback.size(),
	        obs.gaps.size(),
	        obs.rtx.size());
	return good;
}
'''
    text = replace_once(text, helper_anchor, helpers + helper_anchor)

    loop_anchor = "\tfor (size_t i = 0; i < random_case_count; ++i)\n\t{\n"
    # Keep the existing random corpus, then insert the explicit envelope/torture sweep
    # immediately before result reduction.
    result_anchor = "\n\tconst double good_ratio = s.total ? double(s.good) / double(s.total) : 0.0;"
    extra_run = r'''

	// Real receiver loss staircase: every contiguous omission size on both production streams.
	for (uint16_t missing = 1; missing <= shards_per_frame; ++missing)
	{
		for (uint8_t stream = 0; stream < 2; ++stream)
		{
			const bool good = run_case(tx, connection, s, stream, frame[stream], missing, 0, false);
			++s.envelope_total;
			s.envelope_good += good;
			frame[stream] += 2;
		}
	}

	for (uint8_t stream = 0; stream < 2; ++stream)
	{
		bool good = run_duplicate_case(tx, connection, stream, frame[stream]);
		++s.ordering_total;
		s.ordering_good += good;
		frame[stream] += 1;

		good = run_reorder_case(tx, connection, stream, frame[stream]);
		++s.ordering_total;
		s.ordering_good += good;
		frame[stream] += 1;

		good = run_late_old_case(tx, connection, stream, frame[stream]);
		++s.ordering_total;
		s.ordering_good += good;
		frame[stream] += 2;

		good = run_rtx_rescue_case(tx, connection, stream, frame[stream]);
		++s.rtx_total;
		s.rtx_good += good;
		frame[stream] += 1;

		good = run_frame_jump_case(tx, connection, stream, frame[stream]);
		++s.ordering_total;
		s.ordering_good += good;
		frame[stream] += 4;
	}
'''
    text = replace_once(text, result_anchor, extra_run + result_anchor)

    text = replace_once(
        text,
        "\tconst double recorded_ratio = s.recorded_total ? double(s.recorded_good) / double(s.recorded_total) : 0.0;\n"
        "\tconst bool pass = good_ratio >= promotion_threshold && fallback_ratio >= promotion_threshold &&\n"
        "\t                  recorded_ratio >= promotion_threshold && s.catastrophic == 0;",
        "\tconst double recorded_ratio = s.recorded_total ? double(s.recorded_good) / double(s.recorded_total) : 0.0;\n"
        "\tconst double envelope_ratio = s.envelope_total ? double(s.envelope_good) / double(s.envelope_total) : 0.0;\n"
        "\tconst double ordering_ratio = s.ordering_total ? double(s.ordering_good) / double(s.ordering_total) : 0.0;\n"
        "\tconst double rtx_ratio = s.rtx_total ? double(s.rtx_good) / double(s.rtx_total) : 0.0;\n"
        "\tconst bool pass = good_ratio >= promotion_threshold && fallback_ratio >= promotion_threshold &&\n"
        "\t                  recorded_ratio >= promotion_threshold && envelope_ratio >= promotion_threshold &&\n"
        "\t                  ordering_ratio >= promotion_threshold && rtx_ratio >= promotion_threshold &&\n"
        "\t                  s.catastrophic == 0;",
    )

    old_log = (
        '\tU_LOG_I("HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f catastrophic=%llu",\n'
        '\t        pass,\n'
        '\t        static_cast<unsigned long long>(s.total),\n'
        '\t        static_cast<unsigned long long>(s.good),\n'
        '\t        good_ratio,\n'
        '\t        static_cast<unsigned long long>(s.fallback_total),\n'
        '\t        static_cast<unsigned long long>(s.fallback_good),\n'
        '\t        fallback_ratio,\n'
        '\t        static_cast<unsigned long long>(s.recorded_total),\n'
        '\t        static_cast<unsigned long long>(s.recorded_good),\n'
        '\t        recorded_ratio,\n'
        '\t        static_cast<unsigned long long>(s.catastrophic));'
    )
    new_log = (
        '\tU_LOG_I("HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f envelope_total=%llu envelope_good=%llu envelope_ratio=%.6f ordering_total=%llu ordering_good=%llu ordering_ratio=%.6f rtx_total=%llu rtx_good=%llu rtx_ratio=%.6f catastrophic=%llu",\n'
        '\t        pass,\n'
        '\t        static_cast<unsigned long long>(s.total),\n'
        '\t        static_cast<unsigned long long>(s.good),\n'
        '\t        good_ratio,\n'
        '\t        static_cast<unsigned long long>(s.fallback_total),\n'
        '\t        static_cast<unsigned long long>(s.fallback_good),\n'
        '\t        fallback_ratio,\n'
        '\t        static_cast<unsigned long long>(s.recorded_total),\n'
        '\t        static_cast<unsigned long long>(s.recorded_good),\n'
        '\t        recorded_ratio,\n'
        '\t        static_cast<unsigned long long>(s.envelope_total),\n'
        '\t        static_cast<unsigned long long>(s.envelope_good),\n'
        '\t        envelope_ratio,\n'
        '\t        static_cast<unsigned long long>(s.ordering_total),\n'
        '\t        static_cast<unsigned long long>(s.ordering_good),\n'
        '\t        ordering_ratio,\n'
        '\t        static_cast<unsigned long long>(s.rtx_total),\n'
        '\t        static_cast<unsigned long long>(s.rtx_good),\n'
        '\t        rtx_ratio,\n'
        '\t        static_cast<unsigned long long>(s.catastrophic));'
    )
    text = replace_once(text, old_log, new_log)

    Path(PATH).write_text(text)
    try:
        subprocess.run(["git", "diff", "--check", "--", PATH], check=True)
        changed = subprocess.check_output(["git", "diff", "--name-only", "--", PATH], text=True).splitlines()
        if changed != [PATH]:
            raise RuntimeError(f"unexpected changed paths: {changed}")
        for marker in (
            "run_duplicate_case",
            "run_reorder_case",
            "run_late_old_case",
            "run_frame_jump_case",
            "run_rtx_rescue_case",
            "envelope_ratio",
            "ordering_ratio",
            "rtx_ratio",
            "HELIX_TRANSPORT_TORTURE",
        ):
            if marker not in text:
                raise RuntimeError(f"required marker missing: {marker}")
    except Exception:
        Path(PATH).write_text(original)
        raise

    print("PASS: Quest transport torture slice applied")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(2)
