#include "helix_synthetic_transport.h"

#include "driver/wivrn_connection.h"
#include "helix_vrchat_trace.h"
#include "util/u_logging.h"
#include "wivrn_packets.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>
#include <span>
#include <stdexcept>
#include <string>
#include <thread>
#include <type_traits>
#include <utility>
#include <vector>

using namespace std::chrono_literals;

namespace wivrn::helix_synthetic_transport
{
namespace
{
constexpr uint16_t width = 256;
constexpr uint16_t height = 160;
constexpr size_t frame_bytes = size_t(width) * size_t(height) * 3 / 2;
constexpr uint16_t shards_per_frame = 64;
static_assert(frame_bytes % shards_per_frame == 0);
constexpr size_t payload_bytes = frame_bytes / shards_per_frame;
static_assert(payload_bytes < to_headset::video_stream_data_shard::max_payload_size);

constexpr auto per_scenario_timeout = 300ms;
constexpr auto setup_delay = 350ms;
constexpr auto send_spacing = 60us;
constexpr size_t random_case_count = 190;
constexpr double promotion_threshold = 0.95;

struct recorded_event
{
	uint8_t id;
	uint8_t stream;
	uint16_t missing;
	double send_span_ms;
	double report_delay_ms;
};

constexpr std::array recorded_events{
        recorded_event{1, 1, 23, 10.254, 28.655},
        recorded_event{2, 0, 38, 12.014, 31.769},
        recorded_event{3, 0, 42, 22.099, 32.998},
        recorded_event{4, 1, 48, 14.480, 39.243},
        recorded_event{5, 1, 29, 14.580, 13.628},
        recorded_event{6, 0, 31, 21.775, 16.707},
        recorded_event{7, 0, 59, 23.420, 56.901},
        recorded_event{8, 1, 47, 12.854, 64.543},
        recorded_event{9, 1, 33, 10.789, 19.825},
        recorded_event{10, 0, 46, 11.959, 14.086},
};

struct observation
{
	std::map<std::pair<uint8_t, uint64_t>, from_headset::feedback> feedback;
	std::vector<from_headset::video_gap_report> gaps;
	std::vector<from_headset::video_retransmission_request> rtx;
};

struct score
{
	uint64_t total = 0;
	uint64_t good = 0;
	uint64_t fallback_total = 0;
	uint64_t fallback_good = 0;
	uint64_t recorded_total = 0;
	uint64_t recorded_good = 0;
	uint64_t envelope_total = 0;
	uint64_t envelope_good = 0;
	uint64_t ordering_total = 0;
	uint64_t ordering_good = 0;
	uint64_t rtx_total = 0;
	uint64_t rtx_good = 0;
	uint64_t catastrophic = 0;
};

struct packet_plan
{
	uint8_t stream;
	uint64_t frame_idx;
	std::set<uint16_t> omitted;
	bool retransmission = false;
};

uint64_t mix64(uint64_t x)
{
	x += 0x9e3779b97f4a7c15ULL;
	x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
	x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
	return x ^ (x >> 31);
}

std::set<uint16_t> contiguous_omission(uint16_t count, uint16_t start)
{
	std::set<uint16_t> result;
	count = std::min<uint16_t>(count, shards_per_frame);
	for (uint16_t i = 0; i < count; ++i)
		result.insert(uint16_t((start + i) % shards_per_frame));
	return result;
}

to_headset::video_stream_data_shard::view_info_t make_view_info()
{
	to_headset::video_stream_data_shard::view_info_t view{};
	// Intentionally expired for ordinary scenarios so the receiver records gaps but
	// does not retain pending RTX requests that would contaminate later cases.
	view.display_time = 0;
	for (auto & pose: view.pose)
		pose.orientation.w = 1.0f;
	for (auto & fov: view.fov)
	{
		fov.angleLeft = -0.8f;
		fov.angleRight = 0.8f;
		fov.angleUp = 0.8f;
		fov.angleDown = -0.8f;
	}
	view.alpha = false;
	return view;
}

class sender
{
	wivrn_connection & connection;
	std::stop_token stop_token;
	std::array<uint64_t, 2> packet_sequence{};
	std::array<uint8_t, payload_bytes> payload{};

public:
	sender(wivrn_connection & connection, std::stop_token stop_token) :
	        connection(connection), stop_token(stop_token)
	{
		for (size_t i = 0; i < payload.size(); ++i)
			payload[i] = uint8_t(i);
	}

	uint64_t next_sequence(uint8_t stream) const
	{
		return packet_sequence.at(stream) + 1;
	}

	uint64_t reserve_sequence(uint8_t stream)
	{
		return ++packet_sequence.at(stream);
	}

	void send_explicit_shard(uint8_t stream, uint64_t frame_idx, uint16_t shard_idx, uint64_t sequence, bool retransmission = false)
	{
		if (stop_token.stop_requested())
			throw std::runtime_error("synthetic transport cancelled");

		to_headset::video_stream_data_shard packet{};
		packet.stream_item_idx = stream;
		packet.frame_idx = frame_idx;
		packet.packet_sequence = sequence;
		packet.retransmission = retransmission;
		packet.shard_idx = shard_idx;
		if (shard_idx == 0)
			packet.view_info = make_view_info();
		if (shard_idx == shards_per_frame - 1)
			packet.timing_info = to_headset::video_stream_data_shard::timing_info_t{};
		packet.payload = std::span<uint8_t>{payload};
		connection.send_stream(std::move(packet));
		std::this_thread::sleep_for(send_spacing);
	}

	void send_frame(const packet_plan & plan)
	{
		for (uint16_t shard_idx = 0; shard_idx < shards_per_frame; ++shard_idx)
		{
			if (stop_token.stop_requested())
				throw std::runtime_error("synthetic transport cancelled");

			const uint64_t seq = ++packet_sequence.at(plan.stream);
			if (plan.omitted.contains(shard_idx))
				continue;

			to_headset::video_stream_data_shard packet{};
			packet.stream_item_idx = plan.stream;
			packet.frame_idx = plan.frame_idx;
			packet.packet_sequence = seq;
			packet.retransmission = plan.retransmission;
			packet.shard_idx = shard_idx;
			if (shard_idx == 0)
				packet.view_info = make_view_info();
			if (shard_idx == shards_per_frame - 1)
				packet.timing_info = to_headset::video_stream_data_shard::timing_info_t{};
			packet.payload = std::span<uint8_t>{payload};
			connection.send_stream(std::move(packet));
			std::this_thread::sleep_for(send_spacing);
		}
	}
};

void collect(wivrn_connection & connection, observation & out, std::chrono::milliseconds timeout)
{
	auto deadline = std::chrono::steady_clock::now() + timeout;
	while (std::chrono::steady_clock::now() < deadline)
	{
		connection.poll(
		        [&](auto && packet) {
			        using T = std::remove_cvref_t<decltype(packet)>;
			        if constexpr (std::is_same_v<T, from_headset::feedback>)
				        out.feedback[{packet.stream_index, packet.frame_index}] = packet;
			        else if constexpr (std::is_same_v<T, from_headset::video_gap_report>)
				        out.gaps.push_back(packet);
			        else if constexpr (std::is_same_v<T, from_headset::video_retransmission_request>)
				        out.rtx.push_back(packet);
		        },
		        10);
	}
}

bool feedback_success(const observation & obs, uint8_t stream, uint64_t frame)
{
	auto it = obs.feedback.find({stream, frame});
	return it != obs.feedback.end() && it->second.sent_to_decoder != 0;
}

bool feedback_incomplete(const observation & obs, uint8_t stream, uint64_t frame)
{
	auto it = obs.feedback.find({stream, frame});
	return it != obs.feedback.end() && it->second.sent_to_decoder == 0;
}

bool gap_covers(const observation & obs, uint8_t stream, uint64_t first, uint64_t count)
{
	return std::ranges::any_of(obs.gaps, [&](const auto & gap) {
		return gap.stream_index == stream && gap.first_missing_sequence <= first &&
		       gap.first_missing_sequence + gap.missing_count >= first + count;
	});
}

bool oracle_self_test()
{
	observation obs;
	from_headset::feedback complete{};
	complete.stream_index = 0;
	complete.frame_index = 7;
	complete.sent_to_decoder = 1;
	obs.feedback[{0, 7}] = complete;

	from_headset::feedback incomplete{};
	incomplete.stream_index = 1;
	incomplete.frame_index = 9;
	incomplete.sent_to_decoder = 0;
	obs.feedback[{1, 9}] = incomplete;

	obs.gaps.push_back(from_headset::video_gap_report{
	        .stream_index = 1,
	        .first_missing_sequence = 100,
	        .missing_count = 5,
	        .exposing_sequence = 105,
	        .exposing_frame_idx = 9,
	});

	const bool accepts_expected = feedback_success(obs, 0, 7) && feedback_incomplete(obs, 1, 9) && gap_covers(obs, 1, 101, 3);
	const bool rejects_mutations = !feedback_success(obs, 1, 7) && !feedback_success(obs, 1, 9) &&
	                               !feedback_incomplete(obs, 0, 7) && !gap_covers(obs, 0, 101, 3) &&
	                               !gap_covers(obs, 1, 99, 6) && !gap_covers(obs, 1, 104, 2);
	return accepts_expected && rejects_mutations;
}

void note(score & s, bool good, bool fallback, bool recorded)
{
	++s.total;
	s.good += good;
	if (fallback)
	{
		++s.fallback_total;
		s.fallback_good += good;
	}
	if (recorded)
	{
		++s.recorded_total;
		s.recorded_good += good;
	}
}

bool run_case(sender & tx,
              wivrn_connection & connection,
              score & s,
              uint8_t stream,
              uint64_t base,
              uint16_t missing,
              uint16_t start,
              bool recorded)
{
	observation obs;
	const uint64_t first_missing_sequence = tx.next_sequence(stream) + start;

	packet_plan damaged{
	        .stream = stream,
	        .frame_idx = base,
	        .omitted = contiguous_omission(missing, start),
	};
	packet_plan exposing{
	        .stream = stream,
	        .frame_idx = base + 1,
	};

	tx.send_frame(damaged);
	tx.send_frame(exposing);
	collect(connection, obs, per_scenario_timeout);

	const bool damaged_expected_incomplete = missing > 0;
	const bool damaged_ok = damaged_expected_incomplete ? feedback_incomplete(obs, stream, base) : feedback_success(obs, stream, base);
	const bool exposing_ok = feedback_success(obs, stream, base + 1);
	const bool gap_ok = missing == 0 || gap_covers(obs, stream, first_missing_sequence, missing);
	const bool good = damaged_ok && exposing_ok && gap_ok;

	note(s, good, damaged_expected_incomplete, recorded);
	if (!good)
	{
		U_LOG_W("Helix synthetic transport case failed stream=%u base=%llu missing=%u start=%u damaged_ok=%d exposing_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu",
		        stream,
		        static_cast<unsigned long long>(base),
		        missing,
		        start,
		        damaged_ok,
		        exposing_ok,
		        gap_ok,
		        obs.feedback.size(),
		        obs.gaps.size(),
		        obs.rtx.size());
	}
	return good;
}

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
	        stream,
	        static_cast<unsigned long long>(frame),
	        good,
	        obs.feedback.size(),
	        obs.gaps.size(),
	        obs.rtx.size());
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

// ---------------------------------------------------------------------------------------
// Sustained VRChat-like trace replay (HELIX_SYNTHETIC_TRACE=<file>).
//
// The representative path model remains characterization data. Two deterministic single-
// shard-0 omissions (one per eye) are added as RTX canaries. Shard 0 carries view_info;
// withholding it exercises the same already-proven RTX condition as run_rtx_rescue_case
// without inventing a headset display-time clock. A damaged frame counts as recovered only
// after every modeled omitted sequence for that frame was actually retransmitted.
// ---------------------------------------------------------------------------------------
constexpr size_t trace_max_frame_bytes = frame_bytes;
constexpr auto trace_start_delay = 500ms;
constexpr auto trace_drain_time = 1500ms;

int run_trace(wivrn_connection & connection, std::stop_token stop_token, const char * path)
{
	using clock = std::chrono::steady_clock;

	const helix_vrchat_trace::limits limits{
	        .max_frame_bytes = trace_max_frame_bytes,
	        .max_shard_payload = to_headset::video_stream_data_shard::max_payload_size,
	        .max_shards = 64,
	        .max_rows = 6'000'000,
	        .max_duration_us = 1'800'000'000,
	};
	helix_vrchat_trace::trace tr;
	std::string error;
	if (!helix_vrchat_trace::load(path, limits, tr, error))
	{
		U_LOG_E("HELIX_VRCHAT_TRACE_INVALID path=%s error=%s", path, error.c_str());
		return 2;
	}
	U_LOG_I("HELIX_VRCHAT_TRACE_LOADED path=%s rows=%zu frames=%zu", path, tr.rows.size(), tr.frames.size());

	connection.send_control(to_headset::video_stream_description{
	        .width = width,
	        .height = height,
	        .codec = {video_codec::raw, video_codec::raw, video_codec::raw},
	        .frame_rate = 90.0f,
	        .refresh_rate = 90.0f,
	});
	std::this_thread::sleep_for(setup_delay);

	observation obs;
	auto absorb = [&obs](auto && packet) {
		using T = std::remove_cvref_t<decltype(packet)>;
		if constexpr (std::is_same_v<T, from_headset::feedback>)
			obs.feedback[{packet.stream_index, packet.frame_index}] = packet;
		else if constexpr (std::is_same_v<T, from_headset::video_gap_report>)
			obs.gaps.push_back(packet);
		else if constexpr (std::is_same_v<T, from_headset::video_retransmission_request>)
			obs.rtx.push_back(packet);
	};

	std::array<uint8_t, to_headset::video_stream_data_shard::max_payload_size> filler{};
	for (size_t i = 0; i < filler.size(); ++i)
		filler[i] = uint8_t(i * 31 + 7);

	std::array<uint64_t, 2> sequence{};
	std::map<std::pair<uint8_t, uint64_t>, helix_vrchat_trace::row> dropped_packets;
	std::map<std::pair<uint8_t, uint64_t>, uint64_t> dropped_by_frame;
	std::map<std::pair<uint8_t, uint64_t>, uint64_t> retransmitted_by_frame;
	std::set<std::pair<uint8_t, uint64_t>> dropped_shard0_frames;
	std::set<std::pair<uint8_t, uint64_t>> retransmitted_sequences;
	uint64_t rtx_retransmissions = 0;
	size_t rtx_cursor = 0;

	auto transmit = [&](const helix_vrchat_trace::row & row, uint64_t seq, bool retransmission) {
		to_headset::video_stream_data_shard packet{};
		packet.stream_item_idx = row.stream;
		packet.frame_idx = row.frame;
		packet.packet_sequence = seq;
		packet.retransmission = retransmission;
		packet.shard_idx = row.shard;
		if (row.shard == 0)
			packet.view_info = make_view_info();
		if (row.shard == row.shards - 1)
			packet.timing_info = to_headset::video_stream_data_shard::timing_info_t{};
		const size_t overhead = serialized_size(packet.view_info) + serialized_size(packet.timing_info);
		const size_t limit = to_headset::video_stream_data_shard::max_payload_size > overhead
		                             ? to_headset::video_stream_data_shard::max_payload_size - overhead
		                             : 0;
		if (row.bytes > limit)
		{
			U_LOG_E("HELIX_VRCHAT_TRACE_INVALID payload_would_clamp stream=%u frame=%llu shard=%u bytes=%u limit=%zu retransmission=%d",
			        row.stream,
			        static_cast<unsigned long long>(row.frame),
			        row.shard,
			        row.bytes,
			        limit,
			        retransmission);
			return false;
		}
		packet.payload = std::span<uint8_t>{filler.data(), row.bytes};
		connection.send_stream(std::move(packet));
		return true;
	};

	auto process_rtx = [&]() {
		while (rtx_cursor < obs.rtx.size())
		{
			const auto & request = obs.rtx[rtx_cursor++];
			const auto seq_key = std::pair<uint8_t, uint64_t>{request.stream_index, request.packet_sequence};
			auto it = dropped_packets.find(seq_key);
			if (it == dropped_packets.end() || !retransmitted_sequences.insert(seq_key).second)
				continue;
			const auto & row = it->second;
			if (!transmit(row, request.packet_sequence, true))
				return false;
			++rtx_retransmissions;
			++retransmitted_by_frame[{row.stream, row.frame}];
		}
		return true;
	};

	std::vector<int64_t> lateness_us;
	lateness_us.reserve(tr.rows.size());
	struct send_record
	{
		uint8_t stream;
		uint64_t frame;
		uint16_t shard;
		uint64_t sequence;
		int64_t nominal_us;
		int64_t actual_us;
	};
	std::vector<send_record> send_log;
	const char * send_log_path = std::getenv("HELIX_SYNTHETIC_TRACE_SEND_LOG");
	if (send_log_path && *send_log_path)
		send_log.reserve(tr.rows.size());

	uint64_t sent = 0, path_dropped = 0;
	const auto t0 = clock::now() + trace_start_delay;
	for (const auto & row: tr.rows)
	{
		if (stop_token.stop_requested())
		{
			U_LOG_W("HELIX_VRCHAT_TRACE_CANCELLED sent=%llu", static_cast<unsigned long long>(sent));
			return 3;
		}

		const uint64_t seq = ++sequence[row.stream];
		if (row.drop)
		{
			++path_dropped;
			dropped_packets[{row.stream, seq}] = row;
			++dropped_by_frame[{row.stream, row.frame}];
			if (row.shard == 0)
				dropped_shard0_frames.insert({row.stream, row.frame});
			continue;
		}

		const auto target = t0 + std::chrono::microseconds(row.t_send_us);
		for (;;)
		{
			const auto now = clock::now();
			if (now >= target)
				break;
			const auto left = target - now;
			if (left > 300us)
			{
				connection.poll(absorb, 0);
				if (!process_rtx())
					return 2;
				std::this_thread::sleep_for(left > 1500us ? 500us : 100us);
			}
		}

		if (!transmit(row, seq, false))
			return 2;
		connection.poll(absorb, 0);
		if (!process_rtx())
			return 2;

		const int64_t actual_us = std::chrono::duration_cast<std::chrono::microseconds>(clock::now() - t0).count();
		lateness_us.push_back(actual_us - row.t_send_us);
		if (!send_log.empty() || (send_log_path && *send_log_path))
			send_log.push_back({row.stream, row.frame, row.shard, seq, row.t_send_us, actual_us});
		++sent;
	}

	{
		const auto deadline = clock::now() + trace_drain_time;
		while (clock::now() < deadline)
		{
			connection.poll(absorb, 10);
			if (!process_rtx())
				return 2;
		}
	}

	if (send_log_path && *send_log_path)
	{
		if (FILE * out = std::fopen(send_log_path, "w"))
		{
			std::fprintf(out, "stream,frame,shard,sequence,nominal_us,actual_us\n");
			for (const auto & r: send_log)
				std::fprintf(out, "%u,%llu,%u,%llu,%lld,%lld\n", r.stream, static_cast<unsigned long long>(r.frame), r.shard, static_cast<unsigned long long>(r.sequence), static_cast<long long>(r.nominal_us), static_cast<long long>(r.actual_us));
			std::fclose(out);
		}
		else
			U_LOG_W("HELIX_VRCHAT_TRACE_SEND_LOG_OPEN_FAILED path=%s", send_log_path);
	}

	uint64_t frames_total = 0, clean_complete = 0, clean_failed = 0;
	uint64_t damaged_recovered = 0, damaged_unrecovered = 0, false_complete = 0;
	uint64_t rtx_canary_candidates = 0, rtx_canary_recovered = 0;
	std::vector<double> assembly_ms;
	for (const auto & [key, info]: tr.frames)
	{
		++frames_total;
		const auto it = obs.feedback.find(key);
		const bool complete = it != obs.feedback.end() && it->second.sent_to_decoder != 0;
		if (!info.has_drop)
		{
			if (complete)
				++clean_complete;
			else
				++clean_failed;
		}
		else
		{
			const uint64_t dropped = dropped_by_frame[key];
			const uint64_t resent = retransmitted_by_frame[key];
			const bool canary = dropped == 1 && dropped_shard0_frames.contains(key);
			if (canary)
				++rtx_canary_candidates;
			if (complete && dropped != 0 && resent == dropped)
			{
				++damaged_recovered;
				if (canary)
					++rtx_canary_recovered;
			}
			else if (complete)
				++false_complete;
			else
				++damaged_unrecovered;
		}
		if (complete && it != obs.feedback.end() && it->second.received_first_packet != 0 &&
		    it->second.received_last_packet >= it->second.received_first_packet)
			assembly_ms.push_back(double(it->second.received_last_packet - it->second.received_first_packet) / 1e6);
	}

	auto percentile = [](std::vector<double> v, double q) {
		if (v.empty())
			return 0.0;
		std::sort(v.begin(), v.end());
		return v[std::min(v.size() - 1, size_t(q * double(v.size())))];
	};
	std::vector<double> late_ms;
	late_ms.reserve(lateness_us.size());
	for (auto l: lateness_us)
		late_ms.push_back(double(l) / 1e3);

	// Characterization gate only: no post-hoc damaged-frame recovery percentage.
	// The two single-shard-0 canaries must recover, clean frames must stay complete,
	// and no damaged frame may complete without all modeled omitted sequences resent.
	const bool pass = clean_failed == 0 && false_complete == 0 && rtx_canary_candidates == 2 &&
	                  rtx_canary_recovered == 2 && rtx_retransmissions >= 2 && !obs.rtx.empty();

	U_LOG_I("HELIX_VRCHAT_TRACE_RESULT pass=%d phase=characterization frames=%llu sent=%llu path_dropped=%llu "
	        "clean_complete=%llu clean_failed=%llu damaged_recovered=%llu damaged_unrecovered=%llu false_complete=%llu "
	        "rtx_canary_candidates=%llu rtx_canary_recovered=%llu gap_reports=%zu rtx_requests=%zu rtx_retransmissions=%llu "
	        "assembly_ms(p50/p99/max)=%.3f/%.3f/%.3f send_lateness_ms(p50/p99/max)=%.3f/%.3f/%.3f",
	        pass,
	        static_cast<unsigned long long>(frames_total),
	        static_cast<unsigned long long>(sent),
	        static_cast<unsigned long long>(path_dropped),
	        static_cast<unsigned long long>(clean_complete),
	        static_cast<unsigned long long>(clean_failed),
	        static_cast<unsigned long long>(damaged_recovered),
	        static_cast<unsigned long long>(damaged_unrecovered),
	        static_cast<unsigned long long>(false_complete),
	        static_cast<unsigned long long>(rtx_canary_candidates),
	        static_cast<unsigned long long>(rtx_canary_recovered),
	        obs.gaps.size(),
	        obs.rtx.size(),
	        static_cast<unsigned long long>(rtx_retransmissions),
	        percentile(assembly_ms, 0.5),
	        percentile(assembly_ms, 0.99),
	        percentile(assembly_ms, 1.0),
	        percentile(late_ms, 0.5),
	        percentile(late_ms, 0.99),
	        percentile(late_ms, 1.0));
	return pass ? 0 : 1;
}

} // namespace

int run(wivrn_connection & connection, std::stop_token stop_token)
{
	const bool oracle_ok = oracle_self_test();
	U_LOG_I("HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d", oracle_ok);
	if (!oracle_ok)
		return 2;

	if (const char * trace_path = std::getenv("HELIX_SYNTHETIC_TRACE"); trace_path && *trace_path)
		return run_trace(connection, stop_token, trace_path);

	U_LOG_I("Helix synthetic transport: starting bounded Quest receiver battery");

	connection.send_control(to_headset::video_stream_description{
	        .width = width,
	        .height = height,
	        .codec = {video_codec::raw, video_codec::raw, video_codec::raw},
	        .frame_rate = 90.0f,
	        .refresh_rate = 90.0f,
	});
	std::this_thread::sleep_for(setup_delay);

	sender tx{connection, stop_token};
	score s;
	std::array<uint64_t, 2> frame{};

	// Warm-up establishes independent receiver packet-sequence state for both color streams.
	for (uint8_t stream = 0; stream < 2; ++stream)
	{
		if (!run_case(tx, connection, s, stream, frame[stream], 0, 0, false))
			++s.catastrophic;
		frame[stream] += 2;
	}

	// Dominant historical failure class: the entire encoded frame disappears before
	// Quest wlan0. Exercise a literal 64/64-shard erasure on both production streams.
	for (uint8_t stream = 0; stream < 2; ++stream)
	{
		run_case(tx, connection, s, stream, frame[stream], shards_per_frame, 0, false);
		frame[stream] += 2;
	}

	for (const auto & event: recorded_events)
	{
		const uint8_t stream = event.stream;
		const uint16_t missing = std::min<uint16_t>(event.missing, shards_per_frame);
		const uint16_t start = missing == shards_per_frame
		                               ? 0
		                               : uint16_t(1 + (event.id * 7) % (shards_per_frame - missing));
		U_LOG_I("Helix synthetic recorded event=%u stream=%u missing=%u span_ms=%.3f report_ms=%.3f",
		        event.id,
		        stream,
		        missing,
		        event.send_span_ms,
		        event.report_delay_ms);
		run_case(tx, connection, s, stream, frame[stream], missing, start, true);
		frame[stream] += 2;
	}

	for (size_t i = 0; i < random_case_count; ++i)
	{
		const uint64_t r = mix64(0x48454c4958ULL + i);
		const uint8_t stream = uint8_t((r >> 32) & 1);
		const uint16_t missing = uint16_t(r % 61); // 0..60; keeps at least a few shards in most cases
		const uint16_t start = missing == 0
		                               ? 0
		                               : uint16_t(1 + (r >> 16) % (shards_per_frame - missing));
		run_case(tx, connection, s, stream, frame[stream], missing, start, false);
		frame[stream] += 2;
	}

	// Real receiver loss staircase: every contiguous omission size on both production streams.
	for (uint16_t missing = 1; missing <= shards_per_frame; ++missing)
	{
		for (uint8_t stream = 0; stream < 2; ++stream)
		{
			const uint16_t start = missing == shards_per_frame ? 0 : 1;
			const bool good = run_case(tx, connection, s, stream, frame[stream], missing, start, false);
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

	const double good_ratio = s.total ? double(s.good) / double(s.total) : 0.0;
	const double fallback_ratio = s.fallback_total ? double(s.fallback_good) / double(s.fallback_total) : 0.0;
	const double recorded_ratio = s.recorded_total ? double(s.recorded_good) / double(s.recorded_total) : 0.0;
	const double envelope_ratio = s.envelope_total ? double(s.envelope_good) / double(s.envelope_total) : 0.0;
	const double ordering_ratio = s.ordering_total ? double(s.ordering_good) / double(s.ordering_total) : 0.0;
	const double rtx_ratio = s.rtx_total ? double(s.rtx_good) / double(s.rtx_total) : 0.0;
	const bool pass = good_ratio >= promotion_threshold && fallback_ratio >= promotion_threshold &&
	                  recorded_ratio >= promotion_threshold && envelope_ratio >= promotion_threshold &&
	                  ordering_ratio >= promotion_threshold && rtx_ratio >= promotion_threshold &&
	                  s.catastrophic == 0;

	U_LOG_I("HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f envelope_total=%llu envelope_good=%llu envelope_ratio=%.6f ordering_total=%llu ordering_good=%llu ordering_ratio=%.6f rtx_total=%llu rtx_good=%llu rtx_ratio=%.6f catastrophic=%llu",
	        pass,
	        static_cast<unsigned long long>(s.total),
	        static_cast<unsigned long long>(s.good),
	        good_ratio,
	        static_cast<unsigned long long>(s.fallback_total),
	        static_cast<unsigned long long>(s.fallback_good),
	        fallback_ratio,
	        static_cast<unsigned long long>(s.recorded_total),
	        static_cast<unsigned long long>(s.recorded_good),
	        recorded_ratio,
	        static_cast<unsigned long long>(s.envelope_total),
	        static_cast<unsigned long long>(s.envelope_good),
	        envelope_ratio,
	        static_cast<unsigned long long>(s.ordering_total),
	        static_cast<unsigned long long>(s.ordering_good),
	        ordering_ratio,
	        static_cast<unsigned long long>(s.rtx_total),
	        static_cast<unsigned long long>(s.rtx_good),
	        rtx_ratio,
	        static_cast<unsigned long long>(s.catastrophic));

	return pass ? 0 : 1;
}
} // namespace wivrn::helix_synthetic_transport
