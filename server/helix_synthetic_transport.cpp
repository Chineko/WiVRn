#include "helix_synthetic_transport.h"

#include "driver/wivrn_connection.h"
#include "util/u_logging.h"
#include "wivrn_packets.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <map>
#include <set>
#include <span>
#include <stdexcept>
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
	// A single region is valid foveation metadata and represents a 1:1 mapping.
	// The Quest renderer derives its swapchain extent from these vectors, so the
	// synthetic raw stream must describe the actual per-eye frame dimensions.
	for (auto & foveation: view.foveation)
	{
		foveation.x = {width};
		foveation.y = {height};
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
		std::fprintf(stderr,
		             "HELIX_SYNTHETIC_TRANSPORT_CASE_FAILED stream=%u base=%llu missing=%u start=%u damaged_ok=%d exposing_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu\n",
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
		std::fflush(stderr);
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

enum class boundary_class
{
	clean_success,
	clean_recovery,
	degraded,
	hard_failure,
};

const char * boundary_name(boundary_class c)
{
	switch (c)
	{
		case boundary_class::clean_success:
			return "clean_success";
		case boundary_class::clean_recovery:
			return "clean_recovery";
		case boundary_class::degraded:
			return "degraded";
		case boundary_class::hard_failure:
			return "hard_failure";
	}
	return "unknown";
}

struct boundary_score
{
	uint64_t cases = 0;
	uint64_t clean_success = 0;
	uint64_t clean_recovery = 0;
	uint64_t degraded = 0;
	uint64_t hard = 0;
	bool terminal = false;
};

void note_boundary(boundary_score & score,
                   const char * axis,
                   uint64_t level,
                   uint8_t stream,
                   boundary_class classification,
                   bool primary_ok,
                   bool recovery_ok,
                   bool gap_ok,
                   size_t feedback,
                   size_t gaps,
                   size_t rtx,
                   const char * mode)
{
	++score.cases;
	switch (classification)
	{
		case boundary_class::clean_success:
			++score.clean_success;
			break;
		case boundary_class::clean_recovery:
			++score.clean_recovery;
			break;
		case boundary_class::degraded:
			++score.degraded;
			break;
		case boundary_class::hard_failure:
			++score.hard;
			break;
	}
	std::fprintf(stderr,
	             "HELIX_BOUNDARY axis=%s level=%llu stream=%u class=%s mode=%s primary_ok=%d recovery_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu\n",
	             axis,
	             static_cast<unsigned long long>(level),
	             stream,
	             boundary_name(classification),
	             mode,
	             primary_ok,
	             recovery_ok,
	             gap_ok,
	             feedback,
	             gaps,
	             rtx);
	std::fflush(stderr);
}

bool resync(sender & tx, wivrn_connection & connection, uint8_t stream, uint64_t & frame, const char * axis)
{
	observation obs;
	frame += 4;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = frame});
	collect(connection, obs, per_scenario_timeout);
	const bool ok = feedback_success(obs, stream, frame);
	std::fprintf(stderr,
	             "HELIX_BOUNDARY_RESYNC axis=%s stream=%u frame=%llu pass=%d feedback=%zu gaps=%zu rtx=%zu\n",
	             axis,
	             stream,
	             static_cast<unsigned long long>(frame),
	             ok,
	             obs.feedback.size(),
	             obs.gaps.size(),
	             obs.rtx.size());
	std::fflush(stderr);
	++frame;
	return ok;
}

boundary_class boundary_loss_depth(sender & tx,
                                   wivrn_connection & connection,
                                   uint8_t stream,
                                   uint64_t & frame,
                                   uint16_t missing,
                                   boundary_score & score)
{
	observation obs;
	const uint16_t start = missing == shards_per_frame ? 0 : (missing ? 1 : 0);
	const uint64_t first_missing = tx.next_sequence(stream) + start;
	const uint64_t base = frame;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base, .omitted = contiguous_omission(missing, start)});
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + 1});
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = missing ? feedback_incomplete(obs, stream, base) : feedback_success(obs, stream, base);
	const bool recovery_ok = feedback_success(obs, stream, base + 1);
	const bool gap_ok = missing == 0 || gap_covers(obs, stream, first_missing, missing);
	boundary_class c;
	if (missing == 0 && primary_ok && recovery_ok)
		c = boundary_class::clean_success;
	else if (missing > 0 && primary_ok && recovery_ok && gap_ok)
		c = boundary_class::clean_recovery;
	else if (recovery_ok)
		c = boundary_class::degraded;
	else
		c = boundary_class::hard_failure;
	frame = base + 2;
	note_boundary(score, "loss_depth", missing, stream, c, primary_ok, recovery_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), missing ? "next_frame" : "none");
	return c;
}

boundary_class boundary_full_frame_run(sender & tx,
                                       wivrn_connection & connection,
                                       uint8_t stream,
                                       uint64_t & frame,
                                       uint16_t count,
                                       boundary_score & score)
{
	observation obs;
	const uint64_t first_missing = tx.next_sequence(stream);
	const uint64_t base = frame;
	for (uint16_t i = 0; i < count; ++i)
		tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + i, .omitted = contiguous_omission(shards_per_frame, 0)});
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + count});
	collect(connection, obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(obs, stream, base + count);
	const bool gap_ok = gap_covers(obs, stream, first_missing, uint64_t(count) * shards_per_frame);
	const bool primary_ok = recovery_ok;
	const boundary_class c = recovery_ok && gap_ok ? boundary_class::clean_recovery : recovery_ok ? boundary_class::degraded
	                                                                                              : boundary_class::hard_failure;
	frame = base + count + 1;
	note_boundary(score, "full_frame_run", count, stream, c, primary_ok, recovery_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "frame_jump_recovery");
	return c;
}

boundary_class boundary_reorder_distance(sender & tx,
                                         wivrn_connection & connection,
                                         uint8_t stream,
                                         uint64_t & frame,
                                         uint16_t distance,
                                         boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	tx.send_explicit_shard(stream, base, 0, tx.reserve_sequence(stream));
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 2; shard < 2 + distance; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	tx.send_explicit_shard(stream, base, 1, held_sequence);
	for (uint16_t shard = uint16_t(2 + distance); shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const bool gap_ok = gap_covers(obs, stream, held_sequence, 1);
	const boundary_class c = primary_ok && gap_ok ? boundary_class::clean_success : primary_ok ? boundary_class::degraded
	                                                                                           : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "reorder_distance", distance, stream, c, primary_ok, primary_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "late_same_frame");
	return c;
}

boundary_class boundary_lateness_ms(sender & tx,
                                    wivrn_connection & connection,
                                    uint8_t stream,
                                    uint64_t & frame,
                                    uint16_t delay_ms,
                                    boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	tx.send_explicit_shard(stream, base, 0, tx.reserve_sequence(stream));
	const uint64_t held_sequence = tx.reserve_sequence(stream);
	for (uint16_t shard = 2; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	std::this_thread::sleep_for(std::chrono::milliseconds(delay_ms));
	tx.send_explicit_shard(stream, base, 1, held_sequence);
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const bool gap_ok = gap_covers(obs, stream, held_sequence, 1);
	const boundary_class c = primary_ok && gap_ok ? boundary_class::clean_success : primary_ok ? boundary_class::degraded
	                                                                                           : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "lateness_ms", delay_ms, stream, c, primary_ok, primary_ok, gap_ok, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "held_shard");
	return c;
}

boundary_class boundary_frame_jump(sender & tx,
                                   wivrn_connection & connection,
                                   uint8_t stream,
                                   uint64_t & frame,
                                   uint16_t jump,
                                   boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	const uint64_t target = base + jump;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = target});
	collect(connection, obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(obs, stream, target);
	const bool primary_ok = jump == 0 ? recovery_ok : feedback_incomplete(obs, stream, base);
	const boundary_class c = recovery_ok && (jump == 0 || primary_ok) ? (jump == 0 ? boundary_class::clean_success : boundary_class::clean_recovery) : recovery_ok ? boundary_class::degraded
	                                                                                                                                                               : boundary_class::hard_failure;
	frame = target + 1;
	note_boundary(score, "frame_jump", jump, stream, c, primary_ok, recovery_ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), jump ? "jump_recovery" : "none");
	return c;
}

boundary_class boundary_rtx_pressure(sender & tx,
                                     wivrn_connection & connection,
                                     uint8_t stream,
                                     uint64_t & frame,
                                     uint16_t missing,
                                     boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	std::vector<std::pair<uint16_t, uint64_t>> held;
	held.reserve(missing);
	for (uint16_t shard = 0; shard < missing; ++shard)
		held.emplace_back(shard, tx.reserve_sequence(stream));
	for (uint16_t shard = missing; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, 150ms);
	std::set<uint64_t> requested;
	for (const auto & request: obs.rtx)
		if (request.stream_index == stream)
			requested.insert(request.packet_sequence);
	for (const auto & [shard, sequence]: held)
		if (requested.contains(sequence))
			tx.send_explicit_shard(stream, base, shard, sequence, true);
	collect(connection, obs, per_scenario_timeout);
	const bool target_ok = feedback_success(obs, stream, base);
	const bool exact_rtx = requested.size() == missing;
	const bool over_cap = missing > 8;
	if (target_ok && exact_rtx)
	{
		++frame;
		note_boundary(score, "rtx_pressure", missing, stream, boundary_class::clean_recovery, true, true, true, obs.feedback.size(), obs.gaps.size(), requested.size(), "rtx");
		return boundary_class::clean_recovery;
	}

	observation recovery_obs = obs;
	tx.send_frame(packet_plan{.stream = stream, .frame_idx = base + 1});
	collect(connection, recovery_obs, per_scenario_timeout);
	const bool recovery_ok = feedback_success(recovery_obs, stream, base + 1);
	const bool primary_ok = feedback_incomplete(recovery_obs, stream, base);
	boundary_class c;
	const char * mode;
	if (over_cap && requested.empty() && primary_ok && recovery_ok)
	{
		c = boundary_class::clean_recovery;
		mode = "gap_cap_next_frame";
	}
	else if (recovery_ok)
	{
		c = boundary_class::degraded;
		mode = "unexpected_next_frame";
	}
	else
	{
		c = boundary_class::hard_failure;
		mode = "unrecovered";
	}
	frame = base + 2;
	note_boundary(score, "rtx_pressure", missing, stream, c, primary_ok, recovery_ok, true, recovery_obs.feedback.size(), recovery_obs.gaps.size(), requested.size(), mode);
	return c;
}

boundary_class boundary_duplicate_density(sender & tx,
                                          wivrn_connection & connection,
                                          uint8_t stream,
                                          uint64_t & frame,
                                          uint16_t duplicates,
                                          boundary_score & score)
{
	observation obs;
	const uint64_t base = frame;
	const uint64_t first_sequence = tx.reserve_sequence(stream);
	tx.send_explicit_shard(stream, base, 0, first_sequence);
	for (uint16_t i = 0; i < duplicates; ++i)
		tx.send_explicit_shard(stream, base, 0, first_sequence);
	for (uint16_t shard = 1; shard < shards_per_frame; ++shard)
		tx.send_explicit_shard(stream, base, shard, tx.reserve_sequence(stream));
	collect(connection, obs, per_scenario_timeout);
	const bool primary_ok = feedback_success(obs, stream, base);
	const boundary_class c = primary_ok ? boundary_class::clean_success : boundary_class::hard_failure;
	++frame;
	note_boundary(score, "duplicate_density", duplicates, stream, c, primary_ok, primary_ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "same_sequence");
	return c;
}

} // namespace

int run(wivrn_connection & connection, std::stop_token stop_token)
{
	const bool oracle_ok = oracle_self_test();
	std::fprintf(stderr, "HELIX_BOUNDARY_ORACLE pass=%d\n", oracle_ok);
	std::fflush(stderr);
	if (!oracle_ok)
		return 2;

	connection.send_control(to_headset::video_stream_description{
	        .width = width,
	        .height = height,
	        .codec = {video_codec::raw, video_codec::raw, video_codec::raw},
	        .frame_rate = 90.0f,
	        .refresh_rate = 90.0f,
	});
	std::this_thread::sleep_for(setup_delay);

	sender tx{connection, stop_token};
	boundary_score score;
	std::array<uint64_t, 2> frame{};

	for (uint8_t stream = 0; stream < 2; ++stream)
	{
		observation obs;
		tx.send_frame(packet_plan{.stream = stream, .frame_idx = frame[stream]});
		collect(connection, obs, per_scenario_timeout);
		const bool ok = feedback_success(obs, stream, frame[stream]);
		note_boundary(score, "baseline", 0, stream, ok ? boundary_class::clean_success : boundary_class::hard_failure, ok, ok, true, obs.feedback.size(), obs.gaps.size(), obs.rtx.size(), "none");
		++frame[stream];
		if (!ok)
		{
			score.terminal = true;
			std::fprintf(stderr, "HELIX_BOUNDARY_RESULT completed=0 cases=%llu clean_success=%llu clean_recovery=%llu degraded=%llu hard=%llu terminal=1\n", static_cast<unsigned long long>(score.cases), static_cast<unsigned long long>(score.clean_success), static_cast<unsigned long long>(score.clean_recovery), static_cast<unsigned long long>(score.degraded), static_cast<unsigned long long>(score.hard));
			std::fflush(stderr);
			return 3;
		}
	}

	const std::array<uint16_t, 10> loss_levels{0, 1, 2, 4, 8, 16, 24, 32, 48, 64};
	const std::array<uint16_t, 7> full_run_levels{1, 2, 4, 8, 16, 32, 64};
	const std::array<uint16_t, 8> reorder_levels{1, 2, 4, 8, 16, 32, 48, 62};
	const std::array<uint16_t, 11> lateness_levels{0, 1, 2, 5, 10, 20, 40, 80, 160, 320, 640};
	const std::array<uint16_t, 10> jump_levels{1, 2, 3, 4, 8, 16, 32, 64, 128, 256};
	const std::array<uint16_t, 8> rtx_levels{1, 2, 4, 8, 9, 12, 16, 24};
	const std::array<uint16_t, 8> duplicate_levels{0, 1, 2, 4, 8, 16, 32, 64};

	auto handle_hard = [&](boundary_class c, uint8_t stream, const char * axis) {
		if (c != boundary_class::hard_failure)
			return true;
		if (resync(tx, connection, stream, frame[stream], axis))
			return true;
		score.terminal = true;
		return false;
	};

	for (auto level: loss_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_loss_depth(tx, connection, stream, frame[stream], level, score), stream, "loss_depth"))
				goto done;

	for (auto level: full_run_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_full_frame_run(tx, connection, stream, frame[stream], level, score), stream, "full_frame_run"))
				goto done;

	for (auto level: reorder_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_reorder_distance(tx, connection, stream, frame[stream], level, score), stream, "reorder_distance"))
				goto done;

	for (auto level: lateness_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_lateness_ms(tx, connection, stream, frame[stream], level, score), stream, "lateness_ms"))
				goto done;

	for (auto level: jump_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_frame_jump(tx, connection, stream, frame[stream], level, score), stream, "frame_jump"))
				goto done;

	for (auto level: rtx_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_rtx_pressure(tx, connection, stream, frame[stream], level, score), stream, "rtx_pressure"))
				goto done;

	for (auto level: duplicate_levels)
		for (uint8_t stream = 0; stream < 2; ++stream)
			if (!handle_hard(boundary_duplicate_density(tx, connection, stream, frame[stream], level, score), stream, "duplicate_density"))
				goto done;

done:
	std::fprintf(stderr,
	             "HELIX_BOUNDARY_RESULT completed=%d cases=%llu clean_success=%llu clean_recovery=%llu degraded=%llu hard=%llu terminal=%d\n",
	             score.terminal ? 0 : 1,
	             static_cast<unsigned long long>(score.cases),
	             static_cast<unsigned long long>(score.clean_success),
	             static_cast<unsigned long long>(score.clean_recovery),
	             static_cast<unsigned long long>(score.degraded),
	             static_cast<unsigned long long>(score.hard),
	             score.terminal ? 1 : 0);
	std::fflush(stderr);
	return score.terminal ? 3 : 0;
}

} // namespace wivrn::helix_synthetic_transport
