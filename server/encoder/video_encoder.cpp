/*
 * WiVRn VR streaming
 * Copyright (C) 2022  Guillaume Meunier <guillaume.meunier@centraliens.net>
 * Copyright (C) 2022  Patrick Nicolas <patricknicolas@laposte.net>
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 */

// Include first because of incompatibility between Eigen and X includes
#include "driver/wivrn_session.h"

#include "video_encoder.h"

#include "encoder_settings.h"
#include "os/os_time.h"
#include "util/u_logging.h"
#include "utils/wivrn_trace.h"
#include "wivrn_config.h"

#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <string>
#include <thread>
#include <unordered_map>

#if WIVRN_USE_NVENC
#include "video_encoder_nvenc.h"
#endif
#if WIVRN_USE_VAAPI
#include "ffmpeg/video_encoder_va.h"
#endif
#if WIVRN_USE_X264
#include "video_encoder_x264.h"
#endif
#if WIVRN_USE_VULKAN_ENCODE
#include "video_encoder_vulkan_h264.h"
#include "video_encoder_vulkan_h265.h"
#endif
#include "video_encoder_raw.h"

namespace wivrn
{
namespace
{
using helix_pacing_clock = std::chrono::steady_clock;
constexpr const char * helix_pacing_telemetry_version = "fixed-50us-v1";
constexpr auto helix_shard_spacing = std::chrono::microseconds(50);
constexpr size_t helix_pacing_bucket_count = 6;

size_t helix_send_span_bucket(uint64_t us)
{
	for (size_t i = 0; auto threshold: {250u, 500u, 1'000u, 2'000u, 4'000u})
	{
		if (us < threshold)
			return i;
		++i;
	}
	return helix_pacing_bucket_count - 1;
}

size_t helix_queue_delay_bucket(uint64_t us)
{
	for (size_t i = 0; auto threshold: {100u, 500u, 1'000u, 2'000u, 5'000u})
	{
		if (us < threshold)
			return i;
		++i;
	}
	return helix_pacing_bucket_count - 1;
}

struct helix_pacing_stats
{
	uint64_t frames = 0;
	uint64_t payload_bytes = 0;
	uint64_t shards = 0;
	uint64_t frame_bytes_max = 0;
	uint64_t frame_shards_max = 0;
	uint64_t send_span_total_us = 0;
	uint64_t send_span_max_us = 0;
	uint64_t payload_rate_max_kbps = 0;
	std::array<uint64_t, helix_pacing_bucket_count> send_span_hist{};

	uint64_t enqueue_events = 0;
	uint64_t sender_queue_depth_max = 0;
	uint64_t sender_queue_delay_samples = 0;
	uint64_t sender_queue_delay_total_us = 0;
	uint64_t sender_queue_delay_max_us = 0;
	std::array<uint64_t, helix_pacing_bucket_count> sender_queue_delay_hist{};

	uint64_t inter_frame_gap_samples = 0;
	uint64_t inter_frame_gap_total_us = 0;
	uint64_t inter_frame_gap_max_us = 0;
};

std::mutex helix_pacing_stats_mutex;
std::unordered_map<video_encoder *, helix_pacing_stats> helix_pacing_stats_by_encoder;

std::mutex helix_rtx_registry_mutex;
std::array<video_encoder *, 3> helix_rtx_encoder_registry{};

enum class helix_encoded_case : uint8_t
{
	none,
	rtx8,
	gap9,
	full_reference,
};

const char * helix_encoded_case_name(helix_encoded_case c)
{
	switch (c)
	{
		case helix_encoded_case::none:
			return "none";
		case helix_encoded_case::rtx8:
			return "rtx8";
		case helix_encoded_case::gap9:
			return "gap9";
		case helix_encoded_case::full_reference:
			return "full_reference";
	}
	return "unknown";
}

struct helix_encoded_record
{
	helix_encoded_case scenario = helix_encoded_case::none;
	uint64_t frame = 0;
	uint64_t encoded_bytes = 0;
	uint64_t dropped = 0;
	uint64_t total_shards = 0;
	bool feedback_seen = false;
	bool sent_to_decoder = false;
	bool incomplete_seen = false;
	bool recovered = false;
	uint64_t recovery_frame = 0;
};

struct helix_encoded_state
{
	std::mutex mutex;
	uint8_t next_case = 0;
	uint64_t last_injected_frame = 0;
	std::unordered_map<uint64_t, helix_encoded_record> records;
	std::optional<uint64_t> awaiting_recovery;
};

helix_encoded_state helix_encoded_torture;

bool helix_encoded_torture_enabled()
{
	static const bool enabled = [] {
		const char * value = std::getenv("HELIX_ENCODED_TORTURE");
		return value && std::string_view(value) == "1";
	}();
	return enabled;
}

void helix_encoded_note_feedback(const from_headset::feedback & feedback)
{
	if (!helix_encoded_torture_enabled() || feedback.stream_index != 0)
		return;

	std::scoped_lock lock(helix_encoded_torture.mutex);
	auto it = helix_encoded_torture.records.find(feedback.frame_index);
	if (it != helix_encoded_torture.records.end() && !it->second.feedback_seen)
	{
		auto & record = it->second;
		record.feedback_seen = true;
		record.sent_to_decoder = feedback.sent_to_decoder != 0;
		record.incomplete_seen = feedback.sent_to_decoder == 0;
		std::fprintf(stderr,
		             "HELIX_ENCODED_FEEDBACK scenario=%s stream=0 frame=%llu sent_to_decoder=%d\n",
		             helix_encoded_case_name(record.scenario),
		             static_cast<unsigned long long>(record.frame),
		             record.sent_to_decoder);
		std::fflush(stderr);
		if (record.sent_to_decoder)
		{
			record.recovered = true;
			record.recovery_frame = record.frame;
			std::fprintf(stderr,
			             "HELIX_ENCODED_RECOVERY scenario=%s stream=0 lost_frame=%llu recovered_frame=%llu delta=0 mode=same_frame\n",
			             helix_encoded_case_name(record.scenario),
			             static_cast<unsigned long long>(record.frame),
			             static_cast<unsigned long long>(record.frame));
			std::fflush(stderr);
		}
		else
		{
			helix_encoded_torture.awaiting_recovery = record.frame;
		}
	}

	if (feedback.sent_to_decoder && helix_encoded_torture.awaiting_recovery &&
	    feedback.frame_index > *helix_encoded_torture.awaiting_recovery)
	{
		auto lost = *helix_encoded_torture.awaiting_recovery;
		auto lost_it = helix_encoded_torture.records.find(lost);
		if (lost_it != helix_encoded_torture.records.end() && !lost_it->second.recovered)
		{
			auto & record = lost_it->second;
			record.recovered = true;
			record.recovery_frame = feedback.frame_index;
			std::fprintf(stderr,
			             "HELIX_ENCODED_RECOVERY scenario=%s stream=0 lost_frame=%llu recovered_frame=%llu delta=%llu mode=fresh_frame\n",
			             helix_encoded_case_name(record.scenario),
			             static_cast<unsigned long long>(lost),
			             static_cast<unsigned long long>(feedback.frame_index),
			             static_cast<unsigned long long>(feedback.frame_index - lost));
			std::fflush(stderr);
		}
		helix_encoded_torture.awaiting_recovery.reset();
	}
}

void helix_encoded_log_summary()
{
	if (!helix_encoded_torture_enabled())
		return;
	std::scoped_lock lock(helix_encoded_torture.mutex);
	uint64_t feedback = 0;
	uint64_t recovered = 0;
	uint64_t dirty = 0;
	for (const auto & [frame, record]: helix_encoded_torture.records)
	{
		feedback += record.feedback_seen;
		recovered += record.recovered;
		if (!record.feedback_seen || !record.recovered)
			++dirty;
		else if (record.scenario == helix_encoded_case::rtx8 && !record.sent_to_decoder)
			++dirty;
		else if (record.scenario != helix_encoded_case::rtx8 && !record.incomplete_seen)
			++dirty;
		else if (record.recovery_frame < record.frame || record.recovery_frame - record.frame > 3)
			++dirty;
	}
	std::fprintf(stderr,
	             "HELIX_ENCODED_TORTURE_SUMMARY injected=%zu feedback=%llu recovered=%llu dirty=%llu next_case=%u\n",
	             helix_encoded_torture.records.size(),
	             static_cast<unsigned long long>(feedback),
	             static_cast<unsigned long long>(recovered),
	             static_cast<unsigned long long>(dirty),
	             helix_encoded_torture.next_case);
	std::fflush(stderr);
}

uint64_t helix_duration_us(helix_pacing_clock::time_point newer, helix_pacing_clock::time_point older)
{
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(newer - older).count());
}

void helix_note_enqueue(video_encoder * encoder, size_t queue_depth)
{
	std::scoped_lock lock(helix_pacing_stats_mutex);
	auto & stats = helix_pacing_stats_by_encoder[encoder];
	stats.enqueue_events++;
	stats.sender_queue_depth_max = std::max<uint64_t>(stats.sender_queue_depth_max, queue_depth);
}

void helix_note_sender_queue_delay(video_encoder * encoder, uint64_t queue_delay_us)
{
	{
		std::scoped_lock lock(helix_pacing_stats_mutex);
		auto & stats = helix_pacing_stats_by_encoder[encoder];
		stats.sender_queue_delay_samples++;
		stats.sender_queue_delay_total_us += queue_delay_us;
		stats.sender_queue_delay_max_us = std::max(stats.sender_queue_delay_max_us, queue_delay_us);
		stats.sender_queue_delay_hist[helix_queue_delay_bucket(queue_delay_us)]++;
	}
	if (queue_delay_us >= 5'000)
		U_LOG_W("Helix pacing sender queue delay stream=%u delay=%lluus", encoder->stream_idx, static_cast<unsigned long long>(queue_delay_us));
}

void helix_note_frame_gap(video_encoder * encoder, uint64_t frame_index, uint64_t gap_us)
{
	if (gap_us == 0)
		return;
	{
		std::scoped_lock lock(helix_pacing_stats_mutex);
		auto & stats = helix_pacing_stats_by_encoder[encoder];
		stats.inter_frame_gap_samples++;
		stats.inter_frame_gap_total_us += gap_us;
		stats.inter_frame_gap_max_us = std::max(stats.inter_frame_gap_max_us, gap_us);
	}
	if (gap_us >= 40'000)
		U_LOG_W("Helix pacing frame gap stream=%u frame=%llu gap=%lluus", encoder->stream_idx, static_cast<unsigned long long>(frame_index), static_cast<unsigned long long>(gap_us));
}

void helix_note_frame_sent(video_encoder * encoder, uint64_t frame_index, uint64_t bytes, uint64_t shards, uint64_t send_span_us)
{
	uint64_t payload_rate_kbps = send_span_us ? bytes * 8'000 / send_span_us : 0;
	{
		std::scoped_lock lock(helix_pacing_stats_mutex);
		auto & stats = helix_pacing_stats_by_encoder[encoder];
		stats.frames++;
		stats.payload_bytes += bytes;
		stats.shards += shards;
		stats.frame_bytes_max = std::max(stats.frame_bytes_max, bytes);
		stats.frame_shards_max = std::max(stats.frame_shards_max, shards);
		stats.send_span_total_us += send_span_us;
		stats.send_span_max_us = std::max(stats.send_span_max_us, send_span_us);
		stats.payload_rate_max_kbps = std::max(stats.payload_rate_max_kbps, payload_rate_kbps);
		stats.send_span_hist[helix_send_span_bucket(send_span_us)]++;
	}
	if (send_span_us >= 4'000)
		U_LOG_W(
		        "Helix pacing slow send stream=%u frame=%llu payload=%lluB shards=%llu span=%lluus payload_rate=%llukbps",
		        encoder->stream_idx,
		        static_cast<unsigned long long>(frame_index),
		        static_cast<unsigned long long>(bytes),
		        static_cast<unsigned long long>(shards),
		        static_cast<unsigned long long>(send_span_us),
		        static_cast<unsigned long long>(payload_rate_kbps));
}

void helix_log_pacing_summary(video_encoder * encoder)
{
	helix_pacing_stats stats;
	{
		std::scoped_lock lock(helix_pacing_stats_mutex);
		auto it = helix_pacing_stats_by_encoder.find(encoder);
		if (it == helix_pacing_stats_by_encoder.end())
			return;
		stats = it->second;
		helix_pacing_stats_by_encoder.erase(it);
	}

	uint64_t frame_bytes_avg = stats.frames ? stats.payload_bytes / stats.frames : 0;
	uint64_t frame_shards_avg = stats.frames ? stats.shards / stats.frames : 0;
	uint64_t send_span_avg_us = stats.frames ? stats.send_span_total_us / stats.frames : 0;
	uint64_t queue_delay_avg_us = stats.sender_queue_delay_samples ? stats.sender_queue_delay_total_us / stats.sender_queue_delay_samples : 0;
	uint64_t inter_frame_gap_avg_us = stats.inter_frame_gap_samples ? stats.inter_frame_gap_total_us / stats.inter_frame_gap_samples : 0;

	U_LOG_I(
	        "Helix pacing baseline stream %u: version=%s frames=%llu payload_bytes=%llu shards=%llu frame_bytes(avg/max)=%llu/%llu frame_shards(avg/max)=%llu/%llu send_span(avg/max)=%llu/%lluus payload_rate_max=%llukbps sender_queue(events/depth_max)=%llu/%llu sender_queue_delay(avg/max)=%llu/%lluus inter_frame_gap(avg/max)=%llu/%lluus hist_send_span(<0.25/0.5/1/2/4/>4ms)=%llu/%llu/%llu/%llu/%llu/%llu hist_queue_delay(<0.1/0.5/1/2/5/>5ms)=%llu/%llu/%llu/%llu/%llu/%llu",
	        encoder->stream_idx,
	        helix_pacing_telemetry_version,
	        static_cast<unsigned long long>(stats.frames),
	        static_cast<unsigned long long>(stats.payload_bytes),
	        static_cast<unsigned long long>(stats.shards),
	        static_cast<unsigned long long>(frame_bytes_avg),
	        static_cast<unsigned long long>(stats.frame_bytes_max),
	        static_cast<unsigned long long>(frame_shards_avg),
	        static_cast<unsigned long long>(stats.frame_shards_max),
	        static_cast<unsigned long long>(send_span_avg_us),
	        static_cast<unsigned long long>(stats.send_span_max_us),
	        static_cast<unsigned long long>(stats.payload_rate_max_kbps),
	        static_cast<unsigned long long>(stats.enqueue_events),
	        static_cast<unsigned long long>(stats.sender_queue_depth_max),
	        static_cast<unsigned long long>(queue_delay_avg_us),
	        static_cast<unsigned long long>(stats.sender_queue_delay_max_us),
	        static_cast<unsigned long long>(inter_frame_gap_avg_us),
	        static_cast<unsigned long long>(stats.inter_frame_gap_max_us),
	        static_cast<unsigned long long>(stats.send_span_hist[0]),
	        static_cast<unsigned long long>(stats.send_span_hist[1]),
	        static_cast<unsigned long long>(stats.send_span_hist[2]),
	        static_cast<unsigned long long>(stats.send_span_hist[3]),
	        static_cast<unsigned long long>(stats.send_span_hist[4]),
	        static_cast<unsigned long long>(stats.send_span_hist[5]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[0]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[1]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[2]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[3]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[4]),
	        static_cast<unsigned long long>(stats.sender_queue_delay_hist[5]));
}
} // namespace

video_encoder::sender::sender() :
        thread([this](std::stop_token t) {
	        while (not t.stop_requested())
	        {
		        queued_data * queued = nullptr;
		        {
			        std::unique_lock lock(mutex);
			        if (pending.empty())
				        cv.wait_for(lock, std::chrono::milliseconds(100));
			        else
				        queued = &pending.front();
		        }
		        if (queued and not queued->payload.span.empty())
		        {
			        auto queue_delay_us = helix_duration_us(helix_pacing_clock::now(), queued->enqueued_at);
			        helix_note_sender_queue_delay(queued->payload.encoder, queue_delay_us);
			        queued->payload.encoder->SendData(queued->payload.span, true, queued->payload.prefer_control);
			        std::unique_lock lock(mutex);
			        pending.pop_front();
			        cv.notify_all();
		        }
	        }
	        std::unique_lock lock(mutex);
	        pending.clear();
	        cv.notify_all();
        })
{
}

void video_encoder::sender::push(data && d)
{
	video_encoder * encoder = d.encoder;
	std::unique_lock lock(mutex);
	pending.push_back(queued_data{
	        .payload = std::move(d),
	        .enqueued_at = helix_pacing_clock::now(),
	});
	helix_note_enqueue(encoder, pending.size());
	cv.notify_all();
}

void video_encoder::sender::wait_idle(video_encoder * encoder)
{
	std::unique_lock lock(mutex);
	while (std::ranges::any_of(pending, [=](auto & queued) { return queued.payload.encoder == encoder; }))
		cv.wait_for(lock, std::chrono::milliseconds(100));
}

std::shared_ptr<video_encoder::sender> video_encoder::sender::get()
{
	static std::weak_ptr<video_encoder::sender> instance;
	static std::mutex m;
	std::unique_lock lock(m);
	auto s = instance.lock();
	if (s)
		return s;
	s.reset(new video_encoder::sender());
	instance = s;
	return s;
}

std::unique_ptr<video_encoder> video_encoder::create(
        wivrn::vk_bundle & wivrn_vk,
        const encoder_settings & settings,
        uint8_t stream_idx)
{
	using namespace std::string_literals;
	std::unique_ptr<video_encoder> res;
	if (settings.encoder_name == encoder_vulkan)
	{
#if WIVRN_USE_VULKAN_ENCODE
		switch (settings.codec)
		{
			case video_codec::h264:
				res = video_encoder_vulkan_h264::create(wivrn_vk, settings, stream_idx);
				break;
			case video_codec::h265:
				res = video_encoder_vulkan_h265::create(wivrn_vk, settings, stream_idx);
				break;
			case video_codec::av1:
				throw std::runtime_error("av1 not supported for vulkan video encode");
			case video_codec::raw:
				throw std::runtime_error("raw codec only supported on raw encoder");
		}
#else
		throw std::runtime_error("Vulkan video encode not enabled");
#endif
	}
	if (settings.encoder_name == encoder_x264)
	{
#if WIVRN_USE_X264
		res = std::make_unique<video_encoder_x264>(wivrn_vk, settings, stream_idx);
#else
		throw std::runtime_error("x264 encoder not enabled");
#endif
	}
	if (settings.encoder_name == encoder_nvenc)
	{
#if WIVRN_USE_NVENC
		res = std::make_unique<video_encoder_nvenc>(wivrn_vk, settings, stream_idx);
#else
		throw std::runtime_error("nvenc support not enabled");
#endif
	}
	if (settings.encoder_name == encoder_vaapi)
	{
#if WIVRN_USE_VAAPI
		res = std::make_unique<video_encoder_va>(wivrn_vk, settings, stream_idx);
#else
		throw std::runtime_error("vaapi support not enabled");
#endif
	}

	if (settings.encoder_name == encoder_raw)
	{
		res = std::make_unique<video_encoder_raw>(wivrn_vk, settings, stream_idx);
	}

	if (not res)
		throw std::runtime_error("Failed to create encoder " + settings.encoder_name);

	auto wivrn_dump_video = std::getenv("WIVRN_DUMP_VIDEO");
	if (wivrn_dump_video)
	{
		std::string file(wivrn_dump_video);
		file += "-" + std::to_string(stream_idx);
		switch (settings.codec)
		{
			case h264:
				file += ".h264";
				break;
			case h265:
				file += ".h265";
				break;
			case av1:
				file += ".av1";
				break;
			case raw:
				file += ".yuv";
				break;
		}
		res->video_dump.open(file);
	}
	return res;
}

video_encoder::video_encoder(vk_bundle & vk,
                             uint8_t stream_idx,
                             uint32_t target_queue,
                             const encoder_settings & settings,
                             std::unique_ptr<idr_handler> idr,
                             bool async_send) :
        stream_idx(stream_idx),
        target_queue(target_queue),
        need_transfer(not vk.optimal_transfer(vk.queue.family_index, target_queue)),
        bitrate_multiplier(settings.bitrate_multiplier),
        shared_sender(async_send ? sender::get() : nullptr),
        helix_td_enabled(false),
        idr(std::move(idr)),
        extent{
                .width = settings.width,
                .height = settings.height,
        }
{
	assert(this->idr);
	{
		std::scoped_lock lock(helix_rtx_registry_mutex);
		if (stream_idx < helix_rtx_encoder_registry.size())
			helix_rtx_encoder_registry[stream_idx] = this;
	}
	U_LOG_I("Helix pacing telemetry %s stream=%u shard_spacing=%lluus", helix_pacing_telemetry_version, stream_idx, static_cast<unsigned long long>(helix_shard_spacing.count()));
}

video_encoder::~video_encoder()
{
	{
		std::scoped_lock lock(helix_rtx_registry_mutex);
		if (stream_idx < helix_rtx_encoder_registry.size() && helix_rtx_encoder_registry[stream_idx] == this)
			helix_rtx_encoder_registry[stream_idx] = nullptr;
	}
	if (shared_sender)
		shared_sender->wait_idle(this);
	uint64_t final_packet_sequence = helix_packet_sequence > 0 ? helix_packet_sequence - 1 : 0;
	uint64_t rtx_send_time_avg_us = helix_rtx_sent ? helix_rtx_send_time_total_us / helix_rtx_sent : 0;
	U_LOG_I(
	        "Helix RTX server summary stream=%u final_packet_sequence=%llu requests=%llu cache_hits=%llu cache_misses=%llu sent=%llu rtx_bytes=%llu rtx_send_time(avg/max)=%llu/%lluus rtx_send_errors=%llu initial_send_errors=%llu cache_entries=%zu",
	        stream_idx,
	        static_cast<unsigned long long>(final_packet_sequence),
	        static_cast<unsigned long long>(helix_rtx_requests),
	        static_cast<unsigned long long>(helix_rtx_cache_hits),
	        static_cast<unsigned long long>(helix_rtx_cache_misses),
	        static_cast<unsigned long long>(helix_rtx_sent),
	        static_cast<unsigned long long>(helix_rtx_bytes),
	        static_cast<unsigned long long>(rtx_send_time_avg_us),
	        static_cast<unsigned long long>(helix_rtx_send_time_max_us),
	        static_cast<unsigned long long>(helix_rtx_send_errors),
	        static_cast<unsigned long long>(helix_initial_send_errors),
	        helix_rtx_cache.size());

	uint64_t gap_report_delay_avg_us =
	        helix_gap_report_delay_samples
	                ? helix_gap_report_delay_total_us / helix_gap_report_delay_samples
	                : 0;

	U_LOG_I(
	        "Helix gap timing summary stream=%u reports=%llu positions=%llu mapped(full/partial/none)=%llu/%llu/%llu send_span_hist(<1/2/5/10/20/>=20ms)=%llu/%llu/%llu/%llu/%llu/%llu frame_span_hist(1/2/3/4/>4)=%llu/%llu/%llu/%llu/%llu report_delay(avg/max)=%llu/%lluus",
	        stream_idx,
	        static_cast<unsigned long long>(helix_gap_reports),
	        static_cast<unsigned long long>(helix_gap_positions),
	        static_cast<unsigned long long>(helix_gap_fully_mapped),
	        static_cast<unsigned long long>(helix_gap_partially_mapped),
	        static_cast<unsigned long long>(helix_gap_unmapped),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[0]),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[1]),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[2]),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[3]),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[4]),
	        static_cast<unsigned long long>(helix_gap_send_span_hist[5]),
	        static_cast<unsigned long long>(helix_gap_frame_span_hist[0]),
	        static_cast<unsigned long long>(helix_gap_frame_span_hist[1]),
	        static_cast<unsigned long long>(helix_gap_frame_span_hist[2]),
	        static_cast<unsigned long long>(helix_gap_frame_span_hist[3]),
	        static_cast<unsigned long long>(helix_gap_frame_span_hist[4]),
	        static_cast<unsigned long long>(gap_report_delay_avg_us),
	        static_cast<unsigned long long>(helix_gap_report_delay_max_us));

	U_LOG_I(
	        "Helix time-diverse summary stream=%u enabled=%d fresh_bytes=%llu replay_bytes=%llu reference_frames=%llu scheduled=%llu replayed=%llu replayed_shards=%llu skipped_oversize=%llu skipped_budget=%llu expired=%llu send_errors=%llu credit=%llu",
	        stream_idx,
	        helix_td_enabled,
	        static_cast<unsigned long long>(helix_td_fresh_bytes),
	        static_cast<unsigned long long>(helix_td_replay_bytes),
	        static_cast<unsigned long long>(helix_td_reference_frames),
	        static_cast<unsigned long long>(helix_td_scheduled_frames),
	        static_cast<unsigned long long>(helix_td_replayed_frames),
	        static_cast<unsigned long long>(helix_td_replayed_shards),
	        static_cast<unsigned long long>(helix_td_skipped_oversize),
	        static_cast<unsigned long long>(helix_td_skipped_budget),
	        static_cast<unsigned long long>(helix_td_expired),
	        static_cast<unsigned long long>(helix_td_send_errors),
	        static_cast<unsigned long long>(helix_td_credit_bytes));

	helix_log_pacing_summary(this);
	if (stream_idx == 0)
		helix_encoded_log_summary();
}

bool video_encoder::request_retransmission(uint8_t stream_index, uint64_t packet_sequence)
{
	std::scoped_lock registry_lock(helix_rtx_registry_mutex);
	if (stream_index >= helix_rtx_encoder_registry.size())
		return false;
	auto * encoder = helix_rtx_encoder_registry[stream_index];
	if (!encoder)
		return false;
	return encoder->retransmit_cached(packet_sequence);
}

void video_encoder::report_gap(const from_headset::video_gap_report & report)
{
	const uint64_t report_received_ns = os_monotonic_get_ns();

	struct event_info
	{
		uint64_t mapped = 0;
		uint64_t send_span_us = 0;
		uint64_t distinct_frames = 0;
		uint64_t report_delay_us = 0;
		const char * mapping = "none";
	} event;

	{
		std::scoped_lock registry_lock(helix_rtx_registry_mutex);

		if (report.stream_index >= helix_rtx_encoder_registry.size())
			return;

		auto * encoder = helix_rtx_encoder_registry[report.stream_index];
		if (!encoder)
			return;

		std::lock_guard encoder_lock(encoder->mutex);

		++encoder->helix_gap_reports;
		encoder->helix_gap_positions += report.missing_count;

		if (report.missing_count == 0 ||
		    report.first_missing_sequence >
		            std::numeric_limits<uint64_t>::max() - (report.missing_count - 1))
		{
			++encoder->helix_gap_unmapped;
		}
		else
		{
			const uint64_t last_missing_sequence =
			        report.first_missing_sequence + report.missing_count - 1;

			const helix_rtx_cache_entry * first = nullptr;
			const helix_rtx_cache_entry * last = nullptr;
			std::optional<uint64_t> previous_frame;

			for (const auto & entry: encoder->helix_rtx_cache)
			{
				if (entry.packet_sequence < report.first_missing_sequence)
					continue;

				if (entry.packet_sequence > last_missing_sequence)
					break;

				if (!first)
					first = &entry;

				last = &entry;
				++event.mapped;

				if (!previous_frame || *previous_frame != entry.frame_idx)
				{
					++event.distinct_frames;
					previous_frame = entry.frame_idx;
				}
			}

			if (event.mapped == report.missing_count)
			{
				event.mapping = "full";
				++encoder->helix_gap_fully_mapped;
			}
			else if (event.mapped > 0)
			{
				event.mapping = "partial";
				++encoder->helix_gap_partially_mapped;
			}
			else
			{
				++encoder->helix_gap_unmapped;
			}

			if (first && last)
			{
				if (last->send_attempt_ns >= first->send_attempt_ns)
					event.send_span_us =
					        (last->send_attempt_ns - first->send_attempt_ns) / 1000;

				if (report_received_ns >= last->send_attempt_ns)
					event.report_delay_us =
					        (report_received_ns - last->send_attempt_ns) / 1000;

				++encoder->helix_gap_report_delay_samples;
				encoder->helix_gap_report_delay_total_us += event.report_delay_us;
				encoder->helix_gap_report_delay_max_us =
				        std::max(
				                encoder->helix_gap_report_delay_max_us,
				                event.report_delay_us);

				if (event.mapped == report.missing_count)
				{
					size_t send_bucket = 0;

					if (event.send_span_us >= 20000)
						send_bucket = 5;
					else if (event.send_span_us >= 10000)
						send_bucket = 4;
					else if (event.send_span_us >= 5000)
						send_bucket = 3;
					else if (event.send_span_us >= 2000)
						send_bucket = 2;
					else if (event.send_span_us >= 1000)
						send_bucket = 1;

					++encoder->helix_gap_send_span_hist[send_bucket];

					size_t frame_bucket =
					        event.distinct_frames >= 5
					                ? 4
					                : static_cast<size_t>(event.distinct_frames - 1);

					++encoder->helix_gap_frame_span_hist[frame_bucket];
				}
			}
		}
	}

	U_LOG_I(
	        "Helix gap timing event stream=%u first=%llu count=%llu exposing_sequence=%llu exposing_frame=%llu mapping=%s mapped=%llu send_span=%lluus distinct_frames=%llu report_delay=%lluus",
	        report.stream_index,
	        static_cast<unsigned long long>(report.first_missing_sequence),
	        static_cast<unsigned long long>(report.missing_count),
	        static_cast<unsigned long long>(report.exposing_sequence),
	        static_cast<unsigned long long>(report.exposing_frame_idx),
	        event.mapping,
	        static_cast<unsigned long long>(event.mapped),
	        static_cast<unsigned long long>(event.send_span_us),
	        static_cast<unsigned long long>(event.distinct_frames),
	        static_cast<unsigned long long>(event.report_delay_us));
}

bool video_encoder::retransmit_cached(uint64_t packet_sequence)
{
	std::lock_guard lock(mutex);
	++helix_rtx_requests;

	auto it = std::ranges::find(helix_rtx_cache, packet_sequence, &helix_rtx_cache_entry::packet_sequence);
	if (it == helix_rtx_cache.end())
	{
		++helix_rtx_cache_misses;
		return false;
	}
	++helix_rtx_cache_hits;
	if (!cnx || !cnx->has_stream())
	{
		++helix_rtx_send_errors;
		return false;
	}

	// RTX bypasses the fresh-frame 50us shard pacer intentionally so recovery is not
	// delayed behind a frame burst. Account for this traffic separately so validation
	// can detect whether urgent RTX sends disturb fresh-frame delivery.
	to_headset::video_stream_data_shard packet{};
	packet.stream_item_idx = stream_idx;
	packet.frame_idx = it->frame_idx;
	packet.packet_sequence = it->packet_sequence;
	packet.retransmission = true;
	packet.shard_idx = it->shard_idx;
	packet.view_info = it->view_info;
	packet.timing_info = it->timing_info;
	packet.payload = it->payload;

	auto rtx_send_begin = helix_pacing_clock::now();
	try
	{
		auto payload_bytes = packet.payload.size();
		cnx->send_stream(std::move(packet));
		auto send_us = helix_duration_us(helix_pacing_clock::now(), rtx_send_begin);
		++helix_rtx_sent;
		helix_rtx_bytes += payload_bytes;
		helix_rtx_send_time_total_us += send_us;
		helix_rtx_send_time_max_us = std::max(helix_rtx_send_time_max_us, send_us);
		return true;
	}
	catch (...)
	{
		++helix_rtx_send_errors;
		return false;
	}
}

void video_encoder::on_feedback(const from_headset::feedback & feedback)
{
	assert(feedback.stream_index == stream_idx);
	helix_encoded_note_feedback(feedback);
	idr->on_feedback(feedback);
}

void video_encoder::reset()
{
	idr->reset();
}

void video_encoder::set_bitrate(uint32_t bitrate_bps)
{
	pending_bitrate = bitrate_bps * bitrate_multiplier;
}

void video_encoder::set_framerate(float framerate)
{
	pending_framerate = framerate;
}

void video_encoder::present_image(vk::Image y_cbcr, vk::SemaphoreSubmitInfo info, uint64_t frame_index)
{
	wivrn::trace::scope trace_present(wivrn::trace::cpu_track::encoder, stream_idx, frame_index, "present_image");
	// Wait for encoder to be done
	present_slot = (present_slot + 1) % num_slots;
	state[present_slot].wait(busy);
	if (idr->should_skip(frame_index, stream_idx))
	{
		state[present_slot] = skip;
		return;
	}
	state[present_slot] = busy;
	return present_image(y_cbcr, info, present_slot, frame_index);
}

void video_encoder::encode(wivrn_session & cnx,
                           const to_headset::video_stream_data_shard::view_info_t & view_info,
                           uint64_t frame_index)
{
	encode_slot = (encode_slot + 1) % num_slots;

	struct idle_setter
	{
		std::atomic_unsigned_lock_free & state;
		~idle_setter()
		{
			state = idle;
			state.notify_all();
		}
	};
	idle_setter i{state[encode_slot]};

	if (state[encode_slot] == skip)
		return;

	if (shared_sender)
		shared_sender->wait_idle(this);
	this->cnx = &cnx;
	clock = cnx.get_offset();

	wivrn::trace::scope trace_encode(wivrn::trace::cpu_track::encoder, stream_idx, frame_index, "encode");
	auto encode_begin = os_monotonic_get_ns();
	timing_info = {
	        .encode_begin = clock.to_headset(encode_begin),
	};

	// Prepare the video shard template
	shard.stream_item_idx = stream_idx;
	shard.frame_idx = frame_index;
	shard.shard_idx = 0;
	shard.view_info = view_info;
	shard.timing_info.reset();

	auto data = encode(encode_slot, frame_index);
	if (data)
	{
		timing_info.encode_end = clock.to_headset(os_monotonic_get_ns());
		assert(shared_sender);
		shared_sender->push(std::move(*data));
	}
}

void video_encoder::helix_send_time_diverse_replay(uint64_t next_frame_idx)
{
	if (not helix_td_enabled or not helix_td_pending_frame)
		return;

	const uint64_t frame_idx = *helix_td_pending_frame;
	helix_td_pending_frame.reset();
	if (next_frame_idx != frame_idx + 1)
	{
		++helix_td_expired;
		return;
	}
	if (not cnx or not cnx->has_stream())
	{
		++helix_td_expired;
		return;
	}

	auto replay_started_at = helix_pacing_clock::now();
	uint64_t replayed_shards = 0;
	uint64_t replayed_bytes = 0;
	for (auto & entry: helix_rtx_cache)
	{
		if (entry.frame_idx < frame_idx)
			continue;
		if (entry.frame_idx > frame_idx)
			break;

		if (replayed_shards > 0)
		{
			auto target_send_time = replay_started_at + helix_shard_spacing * replayed_shards;
			std::this_thread::sleep_until(target_send_time);
		}

		to_headset::video_stream_data_shard packet{};
		packet.stream_item_idx = stream_idx;
		packet.frame_idx = entry.frame_idx;
		packet.packet_sequence = entry.packet_sequence;
		packet.retransmission = true;
		packet.shard_idx = entry.shard_idx;
		packet.view_info = entry.view_info;
		packet.timing_info = entry.timing_info;
		packet.payload = std::span<uint8_t>{entry.payload.data(), entry.payload.size()};

		try
		{
			cnx->send_stream(std::move(packet));
			++replayed_shards;
			replayed_bytes += entry.payload.size();
		}
		catch (...)
		{
			++helix_td_send_errors;
		}
	}

	if (replayed_shards == 0)
	{
		++helix_td_expired;
		return;
	}

	++helix_td_replayed_frames;
	helix_td_replayed_shards += replayed_shards;
	helix_td_replay_bytes += replayed_bytes;
	U_LOG_I(
	        "Helix time-diverse replay stream=%u frame=%llu before_frame=%llu shards=%llu bytes=%llu span=%lluus",
	        stream_idx,
	        static_cast<unsigned long long>(frame_idx),
	        static_cast<unsigned long long>(next_frame_idx),
	        static_cast<unsigned long long>(replayed_shards),
	        static_cast<unsigned long long>(replayed_bytes),
	        static_cast<unsigned long long>(helix_duration_us(helix_pacing_clock::now(), replay_started_at)));
}

void video_encoder::helix_finish_time_diverse_frame(bool control)
{
	if (not helix_td_enabled or control)
		return;

	helix_td_fresh_bytes += helix_current_frame_bytes;
	helix_td_credit_bytes = std::min<uint64_t>(
	        helix_td_credit_cap_bytes,
	        helix_td_credit_bytes + helix_current_frame_bytes / helix_td_budget_divisor);

	auto * handler = dynamic_cast<default_idr_handler *>(idr.get());
	if (not handler or handler->is_non_ref_frame(shard.frame_idx))
		return;

	++helix_td_reference_frames;
	if (helix_current_frame_shards > helix_td_max_shards)
	{
		++helix_td_skipped_oversize;
		return;
	}
	if (helix_current_frame_bytes > helix_td_credit_bytes)
	{
		++helix_td_skipped_budget;
		return;
	}

	helix_td_credit_bytes -= helix_current_frame_bytes;
	helix_td_pending_frame = shard.frame_idx;
	++helix_td_scheduled_frames;
}

void video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)
{
	std::lock_guard lock(mutex);

	helix_encoded_case encoded_case = helix_encoded_case::none;
	if (helix_encoded_torture_enabled() && stream_idx == 0)
	{
		std::scoped_lock torture_lock(helix_encoded_torture.mutex);
		if (auto existing = helix_encoded_torture.records.find(shard.frame_idx); existing != helix_encoded_torture.records.end())
		{
			encoded_case = existing->second.scenario;
		}
		else if (shard.shard_idx == 0 && !control && helix_encoded_torture.next_case < 3)
		{
			auto * handler = dynamic_cast<default_idr_handler *>(idr.get());
			const bool reference_p = handler && !handler->is_non_ref_frame(shard.frame_idx);
			const bool previous_done = helix_encoded_torture.next_case == 0 ||
			                           (helix_encoded_torture.records.contains(helix_encoded_torture.last_injected_frame) &&
			                            helix_encoded_torture.records.at(helix_encoded_torture.last_injected_frame).recovered);
			const bool spacing_ok = helix_encoded_torture.last_injected_frame == 0 ||
			                        shard.frame_idx >= helix_encoded_torture.last_injected_frame + 20;
			if (reference_p && previous_done && spacing_ok && shard.frame_idx >= 30)
			{
				helix_encoded_case candidate = helix_encoded_case::none;
				switch (helix_encoded_torture.next_case)
				{
					case 0:
						candidate = helix_encoded_case::rtx8;
						break;
					case 1:
						candidate = helix_encoded_case::gap9;
						break;
					case 2:
						candidate = helix_encoded_case::full_reference;
						break;
				}
				const size_t minimum_bytes = candidate == helix_encoded_case::full_reference
				                                     ? 1
				                                     : 16 * to_headset::video_stream_data_shard::max_payload_size;
				if (data.size() >= minimum_bytes)
				{
					encoded_case = candidate;
					helix_encoded_torture.records.emplace(
					        shard.frame_idx,
					        helix_encoded_record{
					                .scenario = candidate,
					                .frame = shard.frame_idx,
					                .encoded_bytes = data.size(),
					        });
					helix_encoded_torture.last_injected_frame = shard.frame_idx;
					++helix_encoded_torture.next_case;
					const unsigned drop_count = candidate == helix_encoded_case::rtx8 ? 8 : candidate == helix_encoded_case::gap9 ? 9
					                                                                                                              : 0;
					std::fprintf(stderr,
					             "HELIX_ENCODED_INJECT scenario=%s stream=0 frame=%llu encoded_bytes=%zu drop_first=%u drop_count=%u\n",
					             helix_encoded_case_name(candidate),
					             static_cast<unsigned long long>(shard.frame_idx),
					             data.size(),
					             candidate == helix_encoded_case::full_reference ? 0u : 2u,
					             drop_count);
					std::fflush(stderr);
				}
			}
		}
	}
	if (shard.shard_idx == 0)
	{
		if (control)
		{
			if (helix_td_pending_frame)
				++helix_td_expired;
			helix_td_pending_frame.reset();
		}
		else
		{
			helix_send_time_diverse_replay(shard.frame_idx);
		}

		// One SendData call per NAL; span the whole frame, not each call.
		wivrn::trace::cpu_begin(wivrn::trace::cpu_track::network, stream_idx, shard.frame_idx, "SendData");
		timing_info.send_begin = clock.to_headset(os_monotonic_get_ns());

		auto now = helix_pacing_clock::now();
		uint64_t gap_us = 0;
		if (helix_last_frame_send_started_at)
			gap_us = helix_duration_us(now, *helix_last_frame_send_started_at);
		helix_last_frame_send_started_at = now;
		helix_frame_send_started_at = now;
		helix_current_frame_bytes = 0;
		helix_current_frame_shards = 0;
		helix_note_frame_gap(this, shard.frame_idx, gap_us);
	}
	if (video_dump)
		video_dump.write((char *)data.data(), data.size());

	ssize_t max_payload_size = (cnx->has_stream() and not control) ? to_headset::video_stream_data_shard::max_payload_size : std::numeric_limits<uint32_t>::max();

	auto begin = data.begin();
	auto end = data.end();
	while (begin != end)
	{
		if (cnx->has_stream() and not control and shard.shard_idx > 0)
		{
			auto target_send_time = helix_frame_send_started_at + helix_shard_spacing * shard.shard_idx;
			std::this_thread::sleep_until(target_send_time);
		}

		const size_t payload_size = std::max(0z, max_payload_size - ssize_t(serialized_size(shard.view_info)));
		auto next = std::min(end, begin + payload_size);
		if (next == end)
		{
			if (end_of_frame)
			{
				timing_info.send_end = clock.to_headset(os_monotonic_get_ns());
				if (not timing_info.encode_end)
					timing_info.encode_end = timing_info.send_end;
				if (serialized_size(timing_info) + std::distance(begin, next) <= max_payload_size)
					shard.timing_info = timing_info;
				else
					--next;
			}
		}
		shard.payload = {begin, next};
		if (cnx->has_stream() and not control)
			shard.packet_sequence = helix_packet_sequence++;
		else
			shard.packet_sequence = 0;
		shard.retransmission = false;

		if (shard.packet_sequence != 0)
		{
			helix_rtx_cache.push_back(helix_rtx_cache_entry{
			        .packet_sequence = shard.packet_sequence,
			        .frame_idx = shard.frame_idx,
			        .shard_idx = shard.shard_idx,
			        .send_attempt_ns = static_cast<uint64_t>(os_monotonic_get_ns()),
			        .view_info = shard.view_info,
			        .timing_info = shard.timing_info,
			        .payload = std::vector<uint8_t>(begin, next),
			});
			while (helix_rtx_cache.size() > helix_rtx_cache_limit)
				helix_rtx_cache.pop_front();
		}

		helix_current_frame_bytes += std::distance(begin, next);
		helix_current_frame_shards++;
		bool helix_drop = false;
		if (encoded_case == helix_encoded_case::full_reference)
			helix_drop = !control;
		else if (encoded_case == helix_encoded_case::rtx8)
			helix_drop = !control && shard.shard_idx >= 2 && shard.shard_idx < 10;
		else if (encoded_case == helix_encoded_case::gap9)
			helix_drop = !control && shard.shard_idx >= 2 && shard.shard_idx < 11;

		if (helix_drop)
		{
			std::scoped_lock torture_lock(helix_encoded_torture.mutex);
			if (auto record = helix_encoded_torture.records.find(shard.frame_idx); record != helix_encoded_torture.records.end())
				++record->second.dropped;
		}
		else
		{
			try
			{
				if (control)
					cnx->send_control(to_headset::video_stream_data_shard{shard});
				else
					cnx->send_stream(to_headset::video_stream_data_shard{shard});
			}
			catch (...)
			{
				++helix_initial_send_errors;
				// Ignore network errors
			}
		}
		++shard.shard_idx;
		shard.view_info.reset();
		begin = next;
	}
	if (end_of_frame)
	{
		if (encoded_case != helix_encoded_case::none)
		{
			std::scoped_lock torture_lock(helix_encoded_torture.mutex);
			if (auto record = helix_encoded_torture.records.find(shard.frame_idx); record != helix_encoded_torture.records.end())
			{
				record->second.total_shards = helix_current_frame_shards;
				std::fprintf(stderr,
				             "HELIX_ENCODED_INJECT_DONE scenario=%s stream=0 frame=%llu dropped=%llu total_shards=%llu\n",
				             helix_encoded_case_name(record->second.scenario),
				             static_cast<unsigned long long>(record->second.frame),
				             static_cast<unsigned long long>(record->second.dropped),
				             static_cast<unsigned long long>(record->second.total_shards));
				std::fflush(stderr);
			}
		}
		auto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);
		helix_note_frame_sent(this, shard.frame_idx, helix_current_frame_bytes, helix_current_frame_shards, send_span_us);
		helix_finish_time_diverse_frame(control);
		wivrn::trace::cpu_end(wivrn::trace::cpu_track::network, stream_idx, shard.frame_idx, "SendData");
	}
}

} // namespace wivrn
