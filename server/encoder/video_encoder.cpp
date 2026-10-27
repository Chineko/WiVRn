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
#include <string>
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
constexpr const char * helix_pacing_telemetry_version = "unpaced-v1";
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
        idr(std::move(idr)),
        extent{
                .width = settings.width,
                .height = settings.height,
        }
{
	assert(this->idr);
	U_LOG_I("Helix pacing telemetry %s stream=%u", helix_pacing_telemetry_version, stream_idx);
}

video_encoder::~video_encoder()
{
	if (shared_sender)
		shared_sender->wait_idle(this);
	helix_log_pacing_summary(this);
}

void video_encoder::on_feedback(const from_headset::feedback & feedback)
{
	assert(feedback.stream_index == stream_idx);
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

void video_encoder::SendData(std::span<uint8_t> data, bool end_of_frame, bool control)
{
	std::lock_guard lock(mutex);
	if (shard.shard_idx == 0)
	{
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
	if (end_of_frame)
	{
		timing_info.send_end = clock.to_headset(os_monotonic_get_ns());
		if (not timing_info.encode_end)
			timing_info.encode_end = timing_info.send_end;
	}
	if (video_dump)
		video_dump.write((char *)data.data(), data.size());

	ssize_t max_payload_size = (cnx->has_stream() and not control) ? to_headset::video_stream_data_shard::max_payload_size : std::numeric_limits<uint32_t>::max();

	auto begin = data.begin();
	auto end = data.end();
	while (begin != end)
	{
		const size_t payload_size = std::max(0z, max_payload_size - ssize_t(serialized_size(shard.view_info)));
		auto next = std::min(end, begin + payload_size);
		if (next == end)
		{
			if (end_of_frame)
			{
				if (serialized_size(timing_info) + std::distance(begin, next) <= max_payload_size)
					shard.timing_info = timing_info;
				else
					--next;
			}
		}
		shard.payload = {begin, next};
		helix_current_frame_bytes += std::distance(begin, next);
		helix_current_frame_shards++;
		try
		{
			if (control)
				cnx->send_control(to_headset::video_stream_data_shard{shard});
			else
				cnx->send_stream(to_headset::video_stream_data_shard{shard});
		}
		catch (...)
		{
			// Ignore network errors
		}
		++shard.shard_idx;
		shard.view_info.reset();
		begin = next;
	}
	if (end_of_frame)
	{
		auto send_span_us = helix_duration_us(helix_pacing_clock::now(), helix_frame_send_started_at);
		helix_note_frame_sent(this, shard.frame_idx, helix_current_frame_bytes, helix_current_frame_shards, send_span_us);
		wivrn::trace::cpu_end(wivrn::trace::cpu_track::network, stream_idx, shard.frame_idx, "SendData");
	}
}

} // namespace wivrn
