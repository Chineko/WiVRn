#include "helix_synthetic_transport.h"

#include "driver/wivrn_connection.h"
#include "util/u_logging.h"
#include "wivrn_packets.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
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

} // namespace

int run(wivrn_connection & connection, std::stop_token stop_token)
{
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

	for (const auto & event: recorded_events)
	{
		const uint8_t stream = event.stream;
		const uint16_t missing = std::min<uint16_t>(event.missing, shards_per_frame);
		const uint16_t max_start = uint16_t(std::max<int>(1, shards_per_frame - missing));
		const uint16_t start = uint16_t((event.id * 7) % max_start);
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
		const uint16_t max_start = uint16_t(std::max<int>(1, shards_per_frame - missing));
		const uint16_t start = uint16_t((r >> 16) % max_start);
		run_case(tx, connection, s, stream, frame[stream], missing, start, false);
		frame[stream] += 2;
	}

	const double good_ratio = s.total ? double(s.good) / double(s.total) : 0.0;
	const double fallback_ratio = s.fallback_total ? double(s.fallback_good) / double(s.fallback_total) : 0.0;
	const double recorded_ratio = s.recorded_total ? double(s.recorded_good) / double(s.recorded_total) : 0.0;
	const bool pass = good_ratio >= promotion_threshold && fallback_ratio >= promotion_threshold &&
	                  recorded_ratio >= promotion_threshold && s.catastrophic == 0;

	U_LOG_I("HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f catastrophic=%llu",
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
	        static_cast<unsigned long long>(s.catastrophic));

	return pass ? 0 : 1;
}
} // namespace wivrn::helix_synthetic_transport
