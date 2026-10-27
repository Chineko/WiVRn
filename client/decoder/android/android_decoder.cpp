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

#include "android_decoder.h"
#include "application.h"
#include "../helix_diagnostics.h"
#include "scenes/stream.h"
#include "utils/named_thread.h"
#include "version.h"
#include <algorithm>
#include <android/hardware_buffer.h>
#include <array>
#include <cassert>
#include <chrono>
#include <deque>
#include <future>
#include <limits>
#include <magic_enum.hpp>
#include <media/NdkImage.h>
#include <media/NdkImageReader.h>
#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <mutex>
#include <optional>
#include <ranges>
#include <spdlog/spdlog.h>
#include <thread>
#include <unordered_map>
#include <vulkan/vulkan.hpp>
#include <vulkan/vulkan_android.h>
#include <vulkan/vulkan_raii.hpp>

DEUGLIFY(AMediaFormat)

struct wivrn::android::decoder::mapped_hardware_buffer
{
	vk::raii::DeviceMemory memory = nullptr;
	vk::raii::Image vimage = nullptr;
	vk::Extent2D extent{};
	vk::raii::ImageView image_view = nullptr;
	vk::ImageLayout layout = vk::ImageLayout::eUndefined;
};

namespace
{
const char * mime(wivrn::video_codec codec)
{
	using c = wivrn::video_codec;
	switch (codec)
	{
		case c::h264:
			return "video/avc";
		case c::h265:
			return "video/hevc";
		case c::av1:
			return "video/av01";
		case c::raw:
			break;
	}
	assert(false);
	__builtin_unreachable();
}

void check(media_status_t status, const char * msg)
{
	if (status != AMEDIA_OK)
	{
		spdlog::error("{}: MediaCodec error {}", msg, (int)status);
		throw std::runtime_error("MediaCodec error");
	}
}

struct android_blit_handle : public decoder::blit_handle
{
	std::shared_ptr<wivrn::android::decoder::mapped_hardware_buffer> vk_data;
	std::shared_ptr<AImageReader> image_reader;
	AImage_ptr aimage;
	android_blit_handle(
	        const wivrn::from_headset::feedback & feedback,
	        const wivrn::to_headset::video_stream_data_shard::view_info_t & view_info,
	        vk::ImageView image_view,
	        vk::Image image,
	        vk::Extent2D extent,
	        vk::ImageLayout & current_layout,
	        decltype(vk_data) vk_data,
	        decltype(image_reader) image_reader,
	        decltype(aimage) aimage) :
	        decoder::blit_handle(feedback, view_info, image_view, image, extent, current_layout),
	        vk_data(vk_data),
	        image_reader(image_reader),
	        aimage(std::move(aimage)) {}
};

using helix_clock = std::chrono::steady_clock;
constexpr size_t helix_submit_history_limit = 64;
constexpr uint64_t helix_watchdog_pending_threshold = 5;
constexpr uint64_t helix_watchdog_age_threshold_us = 35'000;
constexpr const char * helix_diagnostics_version = "time-aware-v1";

enum class helix_decoder_failure
{
	input_buffer_overflow,
	input_submission,
	async_codec,
	output_release,
	image_output,
};

struct helix_decoder_health
{
	std::mutex mutex;
	std::optional<wivrn::from_headset::feedback> last_complete_feedback;
	std::optional<uint64_t> first_submitted_frame;
	std::optional<uint64_t> last_decoded_frame;
	std::unordered_map<uint64_t, helix_clock::time_point> submitted_at;
	std::deque<uint64_t> submit_order;
	std::unordered_map<uint64_t, helix_clock::time_point> released_at;
	std::deque<uint64_t> release_order;
	std::optional<helix_clock::time_point> recovery_started_at;
	std::optional<helix_clock::time_point> last_media_output_at;
	std::optional<helix_clock::time_point> last_image_at;
	std::optional<helix_clock::time_point> last_complete_submission_at;
	uint64_t last_recovery_request_frame = 0;
	uint64_t codec_generation = 0;
	uint64_t complete_submissions_without_output = 0;
	uint64_t complete_submissions_since_recovery_request = 0;
	unsigned recovery_requests = 0;
	bool recovery_pending = false;
	bool flush_attempted = false;
	bool stall_active = false;
	bool watchdog_candidate_active = false;

	uint64_t submitted_frames = 0;
	uint64_t decoded_outputs = 0;
	uint64_t media_output_callbacks = 0;
	uint64_t watchdog_candidates = 0;
	uint64_t watchdog_deferred = 0;
	uint64_t stalls_detected = 0;
	uint64_t recovery_requests_sent = 0;
	uint64_t recovery_requests_suppressed = 0;
	uint64_t async_codec_errors = 0;
	uint64_t input_submission_failures = 0;
	uint64_t input_buffer_overflows = 0;
	uint64_t output_release_failures = 0;
	uint64_t image_output_failures = 0;
	uint64_t flush_attempts = 0;
	uint64_t flush_successes = 0;
	uint64_t flush_failures = 0;
	uint64_t successful_recoveries = 0;
	uint64_t latency_samples = 0;
	uint64_t latency_total_us = 0;
	uint64_t latency_last_us = 0;
	uint64_t latency_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> latency_hist{};
	uint64_t submit_to_media_samples = 0;
	uint64_t submit_to_media_total_us = 0;
	uint64_t submit_to_media_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> submit_to_media_hist{};
	uint64_t media_output_gap_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> media_output_gap_hist{};
	uint64_t complete_interval_samples = 0;
	uint64_t complete_interval_total_us = 0;
	uint64_t complete_interval_last_us = 0;
	uint64_t complete_interval_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> complete_interval_hist{};
	uint64_t release_to_image_samples = 0;
	uint64_t release_to_image_total_us = 0;
	uint64_t release_to_image_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> release_to_image_hist{};
	uint64_t image_processing_samples = 0;
	uint64_t image_processing_total_us = 0;
	uint64_t image_processing_max_us = 0;
	std::array<uint64_t, wivrn::helix_diag::latency_bucket_count> image_processing_hist{};
};

std::mutex helix_health_map_mutex;
std::unordered_map<wivrn::android::decoder *, std::shared_ptr<helix_decoder_health>> helix_health_map;

std::shared_ptr<helix_decoder_health> helix_health(wivrn::android::decoder * decoder)
{
	std::scoped_lock lock(helix_health_map_mutex);
	auto & state = helix_health_map[decoder];
	if (!state)
		state = std::make_shared<helix_decoder_health>();
	return state;
}

uint64_t helix_duration_us(helix_clock::time_point newer, helix_clock::time_point older)
{
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(newer - older).count());
}

void helix_remove_health(wivrn::android::decoder * decoder, uint8_t stream_index)
{
	std::shared_ptr<helix_decoder_health> state;
	{
		std::scoped_lock lock(helix_health_map_mutex);
		auto it = helix_health_map.find(decoder);
		if (it == helix_health_map.end())
			return;
		state = std::move(it->second);
		helix_health_map.erase(it);
	}

	auto network = wivrn::helix_diag::snapshot(stream_index);
	std::scoped_lock lock(state->mutex);
	uint64_t latency_average_us = state->latency_samples ? state->latency_total_us / state->latency_samples : 0;
	uint64_t submit_to_media_average_us = state->submit_to_media_samples ? state->submit_to_media_total_us / state->submit_to_media_samples : 0;
	uint64_t complete_interval_average_us = state->complete_interval_samples ? state->complete_interval_total_us / state->complete_interval_samples : 0;
	uint64_t release_to_image_average_us = state->release_to_image_samples ? state->release_to_image_total_us / state->release_to_image_samples : 0;
	uint64_t image_processing_average_us = state->image_processing_samples ? state->image_processing_total_us / state->image_processing_samples : 0;
	spdlog::info(
	        "Helix decoder summary stream {}: submitted={} decoded={} watchdog_candidates={} deferred={} stalls={} recovery_sent={} recovery_suppressed={} recoveries={} flush={}/{}/{} latency_avg={}us latency_max={}us errors(async/input/overflow/output/image)={}/{}/{}/{}/{}",
	        stream_index,
	        state->submitted_frames,
	        state->decoded_outputs,
	        state->watchdog_candidates,
	        state->watchdog_deferred,
	        state->stalls_detected,
	        state->recovery_requests_sent,
	        state->recovery_requests_suppressed,
	        state->successful_recoveries,
	        state->flush_attempts,
	        state->flush_successes,
	        state->flush_failures,
	        latency_average_us,
	        state->latency_max_us,
	        state->async_codec_errors,
	        state->input_submission_failures,
	        state->input_buffer_overflows,
	        state->output_release_failures,
	        state->image_output_failures);
	spdlog::info(
	        "Helix diagnostic summary stream {}: media_outputs={} submit_to_media(avg/max)={}/{}us output_gap_max={}us complete_interval(avg/last/max)={}/{}/{}us release_to_image(avg/max)={}/{}us image_processing(avg/max)={}/{}us hist_submit_image(<5/10/20/40/80/>80ms)={}/{}/{}/{}/{}/{} hist_submit_media={}/{}/{}/{}/{}/{} hist_output_gap={}/{}/{}/{}/{}/{} hist_complete_interval={}/{}/{}/{}/{}/{} hist_release_image={}/{}/{}/{}/{}/{} hist_image_processing={}/{}/{}/{}/{}/{} network(complete/incomplete/zero/missing/old/jumps/skipped)={}/{}/{}/{}/{}/{}/{} assembly(last/max)={}/{}us hist_assembly={}/{}/{}/{}/{}/{}",
	        stream_index,
	        state->media_output_callbacks,
	        submit_to_media_average_us,
	        state->submit_to_media_max_us,
	        state->media_output_gap_max_us,
	        complete_interval_average_us,
	        state->complete_interval_last_us,
	        state->complete_interval_max_us,
	        release_to_image_average_us,
	        state->release_to_image_max_us,
	        image_processing_average_us,
	        state->image_processing_max_us,
	        state->latency_hist[0], state->latency_hist[1], state->latency_hist[2], state->latency_hist[3], state->latency_hist[4], state->latency_hist[5],
	        state->submit_to_media_hist[0], state->submit_to_media_hist[1], state->submit_to_media_hist[2], state->submit_to_media_hist[3], state->submit_to_media_hist[4], state->submit_to_media_hist[5],
	        state->media_output_gap_hist[0], state->media_output_gap_hist[1], state->media_output_gap_hist[2], state->media_output_gap_hist[3], state->media_output_gap_hist[4], state->media_output_gap_hist[5],
	        state->complete_interval_hist[0], state->complete_interval_hist[1], state->complete_interval_hist[2], state->complete_interval_hist[3], state->complete_interval_hist[4], state->complete_interval_hist[5],
	        state->release_to_image_hist[0], state->release_to_image_hist[1], state->release_to_image_hist[2], state->release_to_image_hist[3], state->release_to_image_hist[4], state->release_to_image_hist[5],
	        state->image_processing_hist[0], state->image_processing_hist[1], state->image_processing_hist[2], state->image_processing_hist[3], state->image_processing_hist[4], state->image_processing_hist[5],
	        network.completed_frames, network.incomplete_frames, network.zero_shard_frames, network.missing_shards, network.old_shards, network.frame_jump_events, network.skipped_frames,
	        network.last_assembly_us, network.max_assembly_us,
	        network.assembly_hist[0], network.assembly_hist[1], network.assembly_hist[2], network.assembly_hist[3], network.assembly_hist[4], network.assembly_hist[5]);
}

void helix_note_failure(wivrn::android::decoder * decoder, helix_decoder_failure failure)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	switch (failure)
	{
		case helix_decoder_failure::input_buffer_overflow:
			state->input_buffer_overflows++;
			break;
		case helix_decoder_failure::input_submission:
			state->input_submission_failures++;
			break;
		case helix_decoder_failure::async_codec:
			state->async_codec_errors++;
			break;
		case helix_decoder_failure::output_release:
			state->output_release_failures++;
			break;
		case helix_decoder_failure::image_output:
			state->image_output_failures++;
			break;
	}
}

uint64_t helix_codec_generation(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	return state->codec_generation;
}

bool helix_codec_generation_matches(wivrn::android::decoder * decoder, uint64_t generation)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	return state->codec_generation == generation;
}

void helix_note_media_output(wivrn::android::decoder * decoder, uint64_t frame_index)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	auto now = helix_clock::now();
	state->media_output_callbacks++;
	state->complete_submissions_without_output = 0;
	state->watchdog_candidate_active = false;
	state->stall_active = false;
	if (state->last_media_output_at)
	{
		auto gap_us = helix_duration_us(now, *state->last_media_output_at);
		state->media_output_gap_max_us = std::max(state->media_output_gap_max_us, gap_us);
		state->media_output_gap_hist[wivrn::helix_diag::latency_bucket(gap_us)]++;
	}
	state->last_media_output_at = now;
	if (auto it = state->submitted_at.find(frame_index); it != state->submitted_at.end())
	{
		auto latency_us = helix_duration_us(now, it->second);
		state->submit_to_media_samples++;
		state->submit_to_media_total_us += latency_us;
		state->submit_to_media_max_us = std::max(state->submit_to_media_max_us, latency_us);
		state->submit_to_media_hist[wivrn::helix_diag::latency_bucket(latency_us)]++;
	}
}

void helix_note_output_released(wivrn::android::decoder * decoder, uint64_t frame_index)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->released_at[frame_index] = helix_clock::now();
	state->release_order.push_back(frame_index);
	while (state->release_order.size() > helix_submit_history_limit)
	{
		state->released_at.erase(state->release_order.front());
		state->release_order.pop_front();
	}
}

void helix_note_image_processing(wivrn::android::decoder * decoder, uint64_t duration_us)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->image_processing_samples++;
	state->image_processing_total_us += duration_us;
	state->image_processing_max_us = std::max(state->image_processing_max_us, duration_us);
	state->image_processing_hist[wivrn::helix_diag::latency_bucket(duration_us)]++;
}

void helix_note_decoded(wivrn::android::decoder * decoder, uint8_t stream_index, uint64_t frame_index)
{
	auto state = helix_health(decoder);
	bool recovered = false;
	std::optional<uint64_t> recovery_duration_us;
	{
		std::scoped_lock lock(state->mutex);
		auto now = helix_clock::now();
		state->decoded_outputs++;
		state->complete_submissions_without_output = 0;
		state->watchdog_candidate_active = false;
		state->stall_active = false;
		state->last_image_at = now;

		if (auto it = state->released_at.find(frame_index); it != state->released_at.end())
		{
			auto latency_us = helix_duration_us(now, it->second);
			state->release_to_image_samples++;
			state->release_to_image_total_us += latency_us;
			state->release_to_image_max_us = std::max(state->release_to_image_max_us, latency_us);
			state->release_to_image_hist[wivrn::helix_diag::latency_bucket(latency_us)]++;
			state->released_at.erase(it);
		}

		if (auto it = state->submitted_at.find(frame_index); it != state->submitted_at.end())
		{
			auto latency_us = helix_duration_us(now, it->second);
			state->latency_last_us = latency_us;
			state->latency_max_us = std::max(state->latency_max_us, latency_us);
			state->latency_total_us += latency_us;
			state->latency_samples++;
			state->latency_hist[wivrn::helix_diag::latency_bucket(latency_us)]++;
			state->submitted_at.erase(it);
		}

		if (!state->last_decoded_frame || frame_index > *state->last_decoded_frame)
			state->last_decoded_frame = frame_index;
		if (state->recovery_pending && frame_index > state->last_recovery_request_frame)
		{
			if (state->recovery_started_at)
				recovery_duration_us = helix_duration_us(now, *state->recovery_started_at);
			state->successful_recoveries++;
			state->recovery_pending = false;
			state->recovery_requests = 0;
			state->complete_submissions_since_recovery_request = 0;
			state->flush_attempted = false;
			state->recovery_started_at.reset();
			recovered = true;
		}
	}

	if (recovered && recovery_duration_us)
		spdlog::info("Helix decoder output resumed on stream {} at frame {} after {} us", stream_index, frame_index, *recovery_duration_us);
	else if (recovered)
		spdlog::info("Helix decoder output resumed on stream {} at frame {}", stream_index, frame_index);
}

void helix_request_recovery(
        wivrn::android::decoder * decoder,
        const std::weak_ptr<scenes::stream> & weak_scene,
        uint8_t stream_index,
        const char * reason,
        std::optional<uint64_t> preferred_frame = {})
{
	auto state = helix_health(decoder);
	std::optional<wivrn::from_headset::feedback> recovery_feedback;
	{
		std::scoped_lock lock(state->mutex);
		if (!state->last_complete_feedback)
		{
			spdlog::warn("Helix decoder recovery requested before any complete frame (stream {}): {}", stream_index, reason);
			return;
		}

		uint64_t frame_index = preferred_frame.value_or(state->last_complete_feedback->frame_index);
		if (state->recovery_pending && state->complete_submissions_since_recovery_request <= 8)
		{
			state->recovery_requests_suppressed++;
			spdlog::info(
			        "Helix diagnostic recovery action stream={} frame={} action=idr_suppressed complete_submissions_since_request={} reason={}",
			        stream_index, frame_index, state->complete_submissions_since_recovery_request, reason);
			return;
		}

		recovery_feedback = *state->last_complete_feedback;
		recovery_feedback->frame_index = frame_index;
		recovery_feedback->sent_to_decoder = 0;
		recovery_feedback->received_from_decoder = 0;
		recovery_feedback->blitted = 0;
		state->recovery_pending = true;
		state->last_recovery_request_frame = frame_index;
		state->recovery_requests++;
		state->complete_submissions_since_recovery_request = 0;
	}

	spdlog::warn("Helix requesting IDR for stream {} at frame {}: {}", stream_index, recovery_feedback->frame_index, reason);
	if (auto scene = weak_scene.lock())
	{
		{
			std::scoped_lock lock(state->mutex);
			state->recovery_requests_sent++;
			if (!state->recovery_started_at)
				state->recovery_started_at = helix_clock::now();
		}
		spdlog::info("Helix diagnostic recovery action stream={} frame={} action=idr_sent reason={}",
		             stream_index, recovery_feedback->frame_index, reason);
		scene->send_feedback(*recovery_feedback);
	}
	else
	{
		spdlog::warn("Helix diagnostic recovery action stream={} frame={} action=idr_not_sent_scene_unavailable reason={}",
		             stream_index, recovery_feedback->frame_index, reason);
	}
}

bool helix_should_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	if (!state->recovery_pending || state->recovery_requests < 2 || state->flush_attempted)
		return false;

	state->flush_attempted = true;
	state->flush_attempts++;
	return true;
}

void helix_begin_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->codec_generation++;
}

void helix_note_flush_result(wivrn::android::decoder * decoder, bool success)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	if (success)
		state->flush_successes++;
	else
		state->flush_failures++;
}

void helix_reset_after_flush(wivrn::android::decoder * decoder)
{
	auto state = helix_health(decoder);
	std::scoped_lock lock(state->mutex);
	state->first_submitted_frame.reset();
	state->last_decoded_frame.reset();
	state->submitted_at.clear();
	state->submit_order.clear();
	state->released_at.clear();
	state->release_order.clear();
	state->complete_submissions_without_output = 0;
	state->complete_submissions_since_recovery_request = 0;
	state->watchdog_candidate_active = false;
	state->stall_active = false;
	state->recovery_pending = false;
	state->recovery_requests = 0;
}

void helix_note_submitted(
        wivrn::android::decoder * decoder,
        const std::weak_ptr<scenes::stream> & weak_scene,
        uint8_t stream_index,
        const wivrn::from_headset::feedback & feedback)
{
	auto state = helix_health(decoder);
	bool candidate = false;
	bool new_candidate = false;
	bool recovery_qualified = false;
	bool new_stall = false;
	uint64_t complete_frames_without_output = 0;
	uint64_t frame_index_gap = 0;
	uint64_t oldest_pending_us = 0;
	uint64_t newest_pending_us = 0;
	uint64_t since_media_output_us = std::numeric_limits<uint64_t>::max();
	uint64_t since_image_us = std::numeric_limits<uint64_t>::max();
	uint64_t burst_5ms = 0;
	uint64_t burst_10ms = 0;
	uint64_t burst_20ms = 0;
	uint64_t complete_interval_last_us = 0;
	uint64_t complete_interval_max_us = 0;
	{
		std::scoped_lock lock(state->mutex);
		auto now = helix_clock::now();
		state->submitted_frames++;
		state->complete_submissions_without_output++;
		if (state->recovery_pending)
			state->complete_submissions_since_recovery_request++;
		if (state->last_complete_submission_at)
		{
			complete_interval_last_us = helix_duration_us(now, *state->last_complete_submission_at);
			state->complete_interval_last_us = complete_interval_last_us;
			state->complete_interval_max_us = std::max(state->complete_interval_max_us, complete_interval_last_us);
			state->complete_interval_total_us += complete_interval_last_us;
			state->complete_interval_samples++;
			state->complete_interval_hist[wivrn::helix_diag::latency_bucket(complete_interval_last_us)]++;
		}
		state->last_complete_submission_at = now;
		complete_interval_max_us = state->complete_interval_max_us;
		state->last_complete_feedback = feedback;
		state->submitted_at[feedback.frame_index] = now;
		state->submit_order.push_back(feedback.frame_index);
		while (state->submit_order.size() > helix_submit_history_limit)
		{
			state->submitted_at.erase(state->submit_order.front());
			state->submit_order.pop_front();
		}

		if (!state->first_submitted_frame)
			state->first_submitted_frame = feedback.frame_index;

		if (state->last_decoded_frame && feedback.frame_index > *state->last_decoded_frame)
			frame_index_gap = feedback.frame_index - *state->last_decoded_frame;
		else if (state->first_submitted_frame)
			frame_index_gap = feedback.frame_index - *state->first_submitted_frame + 1;

		complete_frames_without_output = state->complete_submissions_without_output;
		candidate = complete_frames_without_output >= helix_watchdog_pending_threshold;
		if (candidate)
		{
			bool first_pending = true;
			for (const auto & [frame, submitted]: state->submitted_at)
			{
				(void)frame;
				auto age = helix_duration_us(now, submitted);
				if (first_pending)
				{
					oldest_pending_us = newest_pending_us = age;
					first_pending = false;
				}
				else
				{
					oldest_pending_us = std::max(oldest_pending_us, age);
					newest_pending_us = std::min(newest_pending_us, age);
				}
				if (age <= 5'000)
					burst_5ms++;
				if (age <= 10'000)
					burst_10ms++;
				if (age <= 20'000)
					burst_20ms++;
			}
			if (state->last_media_output_at)
				since_media_output_us = helix_duration_us(now, *state->last_media_output_at);
			if (state->last_image_at)
				since_image_us = helix_duration_us(now, *state->last_image_at);

			if (!state->watchdog_candidate_active)
			{
				state->watchdog_candidate_active = true;
				state->watchdog_candidates++;
				new_candidate = true;
			}

			recovery_qualified = oldest_pending_us >= helix_watchdog_age_threshold_us
			                     && since_media_output_us >= helix_watchdog_age_threshold_us;
			if (recovery_qualified && !state->stall_active)
			{
				state->stall_active = true;
				state->stalls_detected++;
				new_stall = true;
			}
			else if (new_candidate && !recovery_qualified)
			{
				state->watchdog_deferred++;
			}
		}
	}

	if (new_candidate || new_stall)
	{
		auto network = wivrn::helix_diag::snapshot(stream_index);
		auto peer = wivrn::helix_diag::note_stall(stream_index);
		const char * action = new_stall ? "recovery_candidate" : "diagnostic_only_wait";
		if (new_stall)
		{
			spdlog::warn(
			        "Helix decoder output stall qualified on stream {} with {} complete frames pending, oldest {} us (frame index gap {})",
			        stream_index, complete_frames_without_output, oldest_pending_us, frame_index_gap);
		}
		spdlog::warn(
		        "Helix diagnostic incident stream={} frame={} action={} pending={} oldest_pending={}us newest_pending={}us burst(5/10/20ms)={}/{}/{} since_media_output={}us since_image={}us complete_interval(last/max)={}/{}us threshold={}us peer_stall_age={}us peer_within(5/10/20/50ms)={}/{}/{}/{} network(complete/incomplete/zero/missing/old/jumps/skipped)={}/{}/{}/{}/{}/{}/{} assembly(last/max)={}/{}us network_age(incomplete/old/jump)={}/{}/{}us",
		        stream_index, feedback.frame_index, action, complete_frames_without_output, oldest_pending_us, newest_pending_us,
		        burst_5ms, burst_10ms, burst_20ms, since_media_output_us, since_image_us,
		        complete_interval_last_us, complete_interval_max_us, helix_watchdog_age_threshold_us, peer.peer_age_us,
		        peer.within_5ms, peer.within_10ms, peer.within_20ms, peer.within_50ms,
		        network.completed_frames, network.incomplete_frames, network.zero_shard_frames, network.missing_shards,
		        network.old_shards, network.frame_jump_events, network.skipped_frames,
		        network.last_assembly_us, network.max_assembly_us,
		        network.since_incomplete_us, network.since_old_shard_us, network.since_frame_jump_us);
	}
	if (recovery_qualified)
		helix_request_recovery(decoder, weak_scene, stream_index, "decoder output stalled beyond time threshold", feedback.frame_index);
}

} // namespace

namespace wivrn::android
{
decoder::decoder(
        vk::raii::Device & device,
        vk::raii::PhysicalDevice & physical_device,
        const wivrn::to_headset::video_stream_description & description,
        uint8_t stream_index,
        std::weak_ptr<scenes::stream> weak_scene,
        shard_accumulator * accumulator) :
        stream_index(stream_index), device(device), weak_scene(weak_scene), accumulator(accumulator)
{
	spdlog::info("hbm_mutex.native_handle() = {}", (void *)hbm_mutex.native_handle());

	auto width = description.width;
	auto height = description.height / (stream_index == 2 ? 2 : 1);
	spdlog::info("Helix diagnostics {} commit={} stream={} codec={} size={}x{} target_fps={}",
	             helix_diagnostics_version, wivrn::git_commit, stream_index,
	             mime(description.codec[stream_index]), width, height, description.frame_rate);

	AImageReader * ir;
	check(AImageReader_newWithUsage(
	              width,
	              height,
	              AIMAGE_FORMAT_PRIVATE,
	              AHARDWAREBUFFER_USAGE_CPU_READ_NEVER | AHARDWAREBUFFER_USAGE_CPU_WRITE_NEVER | AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE,
	              scenes::stream::image_buffer_size + 4 /* maxImages */,
	              &ir),
	      "AImageReader_newWithUsage");
	image_reader.reset(ir, AImageReader_deleter{});

	AImageReader_ImageListener listener{this, on_image_available};
	check(AImageReader_setImageListener(ir, &listener), "AImageReader_setImageListener");

	vkGetAndroidHardwareBufferPropertiesANDROID =
	        application::get_vulkan_proc<PFN_vkGetAndroidHardwareBufferPropertiesANDROID>(
	                "vkGetAndroidHardwareBufferPropertiesANDROID");
	{
		AMediaFormat_ptr format(AMediaFormat_new());
		AMediaFormat_setString(format.get(), AMEDIAFORMAT_KEY_MIME, mime(description.codec[stream_index]));
		// AMediaFormat_setInt32(format.get(), "vendor.qti-ext-dec-low-latency.enable", 1); // Qualcomm low
		// latency mode
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_WIDTH, width);
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_HEIGHT, height);
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_OPERATING_RATE, std::ceil(description.frame_rate));
		AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_PRIORITY, 0);

		media_codec.reset(AMediaCodec_createDecoderByType(mime(description.codec[stream_index])));

		if (not media_codec)
			throw std::runtime_error(std::string("Cannot create decoder for MIME type ") + mime(description.codec[stream_index]));

		char * codec_name;
		check(AMediaCodec_getName(media_codec.get(), &codec_name), "AMediaCodec_getName");
		spdlog::info("Created MediaCodec decoder \"{}\"", codec_name);
		AMediaCodec_releaseName(media_codec.get(), codec_name);

		ANativeWindow * window;

		check(AImageReader_getWindow(image_reader.get(), &window), "AImageReader_getWindow");

		AMediaCodecOnAsyncNotifyCallback callback{
		        .onAsyncInputAvailable = decoder::on_media_input_available,
		        .onAsyncOutputAvailable = decoder::on_media_output_available,
		        .onAsyncFormatChanged = decoder::on_media_format_changed,
		        .onAsyncError = decoder::on_media_error,
		};
		check(AMediaCodec_setAsyncNotifyCallback(media_codec.get(), callback, this),
		      "AMediaCodec_setAsyncNotifyCallback");

		check(AMediaCodec_configure(media_codec.get(), format.get(), window, nullptr /* crypto */, 0 /* flags */),
		      "AMediaCodec_configure");

		check(AMediaCodec_start(media_codec.get()), "AMediaCodec_start");
	}
	worker = utils::named_thread(
	        "decoder-" + std::to_string(stream_index),
	        [this]() {
		        while (true)
		        {
			        try
			        {
				        if (jobs.pop()())
					        return;
			        }
			        catch (const utils::sync_queue_closed & e)
			        {
				        return;
			        }
			        catch (const std::exception & e)
			        {
				        spdlog::error("error in decoder thread: {}", e.what());
			        }
		        }
	        });
}

decoder::~decoder()
{
	if (image_reader)
		AImageReader_setImageListener(image_reader.get(), nullptr);
	if (media_codec)
	{
		AMediaCodec_stop(media_codec.get());
		jobs.push([]() { return true; });
		if (worker.joinable())
			worker.join();
	}
	input_buffers.close();
	jobs.close();

	if (worker.joinable())
		worker.join();

	helix_remove_health(this, stream_index);
	spdlog::info("decoder::~decoder");
}

void decoder::push_data(std::span<std::span<const uint8_t>> data, uint64_t frame_index, bool partial)
{
	if (current_input_buffer.data == nullptr)
		current_input_buffer = input_buffers.pop();
	else if (current_input_buffer.frame_index != frame_index)
	{
		// Reuse the input buffer, discard existing data
		current_input_buffer.data_size = 0;
	}
	current_input_buffer.frame_index = frame_index;

	for (const auto & sub_data: data)
	{
		if (current_input_buffer.data_size + sub_data.size() > current_input_buffer.capacity)
		{
			spdlog::error("data to decode is larger than decoder buffer, skipping frame");
			helix_note_failure(this, helix_decoder_failure::input_buffer_overflow);
			helix_request_recovery(this, weak_scene, stream_index, "decoder input buffer overflow", frame_index);
			return;
		}

		memcpy(current_input_buffer.data + current_input_buffer.data_size, sub_data.data(), sub_data.size());
		current_input_buffer.data_size += sub_data.size();
	}

	if (partial)
		return;

	jobs.push([=, this, idx = current_input_buffer.idx, data_size = current_input_buffer.data_size, mc = media_codec.get()]() {
		uint64_t timestamp = frame_index * 10'000;
		auto status = AMediaCodec_queueInputBuffer(mc, idx, 0, data_size, timestamp, 0);
		if (status != AMEDIA_OK)
		{
			spdlog::error("AMediaCodec_queueInputBuffer: MediaCodec error {}({})",
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
			helix_note_failure(this, helix_decoder_failure::input_submission);
			helix_request_recovery(this, weak_scene, stream_index, "MediaCodec input submission failed", frame_index);
		}
		return false;
	});
	current_input_buffer = input_buffer{};
}

void decoder::frame_completed(const wivrn::from_headset::feedback & feedback, const wivrn::to_headset::video_stream_data_shard::view_info_t & view_info)
{
	if (not media_codec)
	{
		if (auto scene = weak_scene.lock())
			scene->send_feedback(feedback);
	}

	frame_infos.push(frame_info{
	        .feedback = feedback,
	        .view_info = view_info,
	});
	helix_note_submitted(this, weak_scene, stream_index, feedback);

	if (helix_should_flush(this))
	{
		spdlog::warn("Helix escalating decoder recovery to MediaCodec flush on stream {}", stream_index);
		current_input_buffer = input_buffer{};

		auto completion = std::make_shared<std::promise<media_status_t>>();
		auto future = completion->get_future();
		jobs.push([this, completion, mc = media_codec.get()]() {
			helix_begin_flush(this);

			auto status = AMediaCodec_flush(mc);
			if (status == AMEDIA_OK)
			{
				input_buffers.drop_until([](auto &) { return false; });
				frame_infos.drop_until([](auto &) { return false; });
				status = AMediaCodec_start(mc);
			}

			completion->set_value(status);
			return false;
		});

		auto status = future.get();
		helix_note_flush_result(this, status == AMEDIA_OK);
		if (status == AMEDIA_OK)
		{
			helix_reset_after_flush(this);
			spdlog::info("Helix MediaCodec flush completed on stream {}", stream_index);
			helix_request_recovery(this, weak_scene, stream_index, "decoder flushed; fresh IDR required", feedback.frame_index);
		}
		else
		{
			spdlog::error("Helix MediaCodec flush/restart failed on stream {}: {}({})",
			              stream_index,
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
		}
	}
}

void decoder::on_image_available(void * context, AImageReader * reader)
{
	try
	{
		static_cast<decoder *>(context)->on_image_available(reader);
	}
	catch (std::exception & e)
	{
		spdlog::error("Exception in decoder::on_image_available: {}", e.what());
	}
}

void decoder::on_image_available(AImageReader * reader)
{
	assert(reader == image_reader.get());
	decltype(android_blit_handle::aimage) image;
	try
	{
		auto image_processing_start = helix_clock::now();
		AImage * tmp;
		check(AImageReader_acquireLatestImage(image_reader.get(), &tmp), "AImageReader_acquireLatestImage");
		image.reset(tmp);

		int64_t fake_timestamp_ns;
		check(AImage_getTimestamp(image.get(), &fake_timestamp_ns), "AImage_getTimestamp");
		uint64_t frame_index = (fake_timestamp_ns + 5'000'000) / (10'000'000);
		frame_infos.drop_until([frame_index](auto & x) { return x.feedback.frame_index >= frame_index; });
		auto info = frame_infos.pop_if([frame_index](auto & x) { return x.feedback.frame_index == frame_index; });

		if (!info)
		{
			spdlog::warn("No frame info for frame {}, dropping frame", frame_index);
			return;
		}

		assert(info->feedback.frame_index == frame_index);
		helix_note_decoded(this, stream_index, frame_index);

		auto vk_data = map_hardware_buffer(image.get());

		auto handle = std::make_shared<android_blit_handle>(
		        info->feedback,
		        info->view_info,
		        *vk_data->image_view,
		        *vk_data->vimage,
		        vk_data->extent,
		        vk_data->layout,
		        std::move(vk_data),
		        image_reader,
		        std::move(image));

		if (auto scene = weak_scene.lock())
			scene->push_blit_handle(accumulator, std::move(handle));
		helix_note_image_processing(this, helix_duration_us(helix_clock::now(), image_processing_start));
	}
	catch (const std::exception & e)
	{
		spdlog::warn("Helix image output failure on stream {}: {}", stream_index, e.what());
		helix_note_failure(this, helix_decoder_failure::image_output);
		helix_request_recovery(this, weak_scene, stream_index, "image output processing failed");
	}
	catch (...)
	{
		spdlog::warn("Helix unknown image output failure on stream {}", stream_index);
		helix_note_failure(this, helix_decoder_failure::image_output);
		helix_request_recovery(this, weak_scene, stream_index, "unknown image output processing failure");
	}
}

void decoder::create_sampler(const AHardwareBuffer_Desc & buffer_desc, vk::AndroidHardwareBufferFormatPropertiesANDROID & ahb_format)
{
	assert(ahb_format.externalFormat != 0);
	spdlog::info("AndroidHardwareBufferProperties");
	spdlog::info("  Vulkan format: {}", vk::to_string(ahb_format.format));
	spdlog::info("  External format: {:#x}", ahb_format.externalFormat);
	spdlog::info("  Format features: {}", vk::to_string(ahb_format.formatFeatures));
	spdlog::info("  samplerYcbcrConversionComponents: ({}, {}, {}, {})",
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.r),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.g),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.b),
	             vk::to_string(ahb_format.samplerYcbcrConversionComponents.a));
	spdlog::info("  Suggested YCbCr model: {}", vk::to_string(ahb_format.suggestedYcbcrModel));
	spdlog::info("  Suggested YCbCr range: {}", vk::to_string(ahb_format.suggestedYcbcrRange));
	spdlog::info("  Suggested X chroma offset: {}", vk::to_string(ahb_format.suggestedXChromaOffset));
	spdlog::info("  Suggested Y chroma offset: {}", vk::to_string(ahb_format.suggestedYChromaOffset));

	vk::Filter yuv_filter;
	if (ahb_format.formatFeatures & vk::FormatFeatureFlagBits::eSampledImageYcbcrConversionLinearFilter)
		yuv_filter = vk::Filter::eLinear;
	else
		yuv_filter = vk::Filter::eNearest;

	vk::StructureChain ycbcr_create_info{
	        vk::SamplerYcbcrConversionCreateInfo{
	                .format = vk::Format::eUndefined,
	                .ycbcrModel = ahb_format.suggestedYcbcrModel,
	                .ycbcrRange = ahb_format.suggestedYcbcrRange,
	                .components = ahb_format.samplerYcbcrConversionComponents,
	                .xChromaOffset = ahb_format.suggestedXChromaOffset,
	                .yChromaOffset = ahb_format.suggestedYChromaOffset,
	                .chromaFilter = yuv_filter,
	        },
	        vk::ExternalFormatANDROID{
	                .externalFormat = ahb_format.externalFormat,
	        },
	};

	ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>().ycbcrRange = vk::SamplerYcbcrRange::eItuFull;
	ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>().ycbcrModel = vk::SamplerYcbcrModelConversion::eYcbcr709;

	ycbcr_conversion = vk::raii::SamplerYcbcrConversion(device, ycbcr_create_info.get<vk::SamplerYcbcrConversionCreateInfo>());

	vk::StructureChain sampler_info{
	        vk::SamplerCreateInfo{
	                .magFilter = yuv_filter,
	                .minFilter = yuv_filter,
	                .mipmapMode = vk::SamplerMipmapMode::eNearest,
	                .addressModeU = vk::SamplerAddressMode::eClampToEdge,
	                .addressModeV = vk::SamplerAddressMode::eClampToEdge,
	                .addressModeW = vk::SamplerAddressMode::eClampToEdge,
	                .mipLodBias = 0.0f,
	                .anisotropyEnable = VK_FALSE,
	                .maxAnisotropy = 1,
	                .compareEnable = VK_FALSE,
	                .compareOp = vk::CompareOp::eNever,
	                .minLod = 0.0f,
	                .maxLod = 0.0f,
	                .borderColor = vk::BorderColor::eFloatOpaqueWhite,
	                .unnormalizedCoordinates = VK_FALSE,
	        },
	        vk::SamplerYcbcrConversionInfo{
	                .conversion = *ycbcr_conversion,
	        },
	};

	ycbcr_sampler = vk::raii::Sampler(device, sampler_info.get());
}

std::shared_ptr<decoder::mapped_hardware_buffer> decoder::map_hardware_buffer(AImage * image)
{
	AHardwareBuffer * hardware_buffer;
	check(AImage_getHardwareBuffer(image, &hardware_buffer), "AImage_getHardwareBuffer");

	std::unique_lock lock(hbm_mutex);

	AHardwareBuffer_Desc buffer_desc{};
	AHardwareBuffer_describe(hardware_buffer, &buffer_desc);

	auto [properties, format_properties] = device.getAndroidHardwareBufferPropertiesANDROID<vk::AndroidHardwareBufferPropertiesANDROID, vk::AndroidHardwareBufferFormatPropertiesANDROID>(*hardware_buffer);

	if (!*ycbcr_sampler || memcmp(&ahb_format, &format_properties, sizeof(format_properties)))
	{
		memcpy(&ahb_format, &format_properties, sizeof(format_properties));
		spdlog::info("decoded image size: {}x{}", buffer_desc.width, buffer_desc.height);
		create_sampler(buffer_desc, ahb_format);
		hardware_buffer_map.clear();
	}

	auto it = hardware_buffer_map.find(hardware_buffer);
	if (it != hardware_buffer_map.end())
		return it->second;

	vk::StructureChain img_info{
	        vk::ImageCreateInfo{
	                .flags = {},
	                .imageType = vk::ImageType::e2D,
	                .format = vk::Format::eUndefined,
	                .extent = {buffer_desc.width, buffer_desc.height, 1},
	                .mipLevels = 1,
	                .arrayLayers = 1,
	                .samples = vk::SampleCountFlagBits::e1,
	                .tiling = vk::ImageTiling::eOptimal,
	                .usage = vk::ImageUsageFlagBits::eSampled,
	                .sharingMode = vk::SharingMode::eExclusive,
	                .initialLayout = vk::ImageLayout::eUndefined,
	        },
	        vk::ExternalMemoryImageCreateInfo{
	                .handleTypes = vk::ExternalMemoryHandleTypeFlagBits::eAndroidHardwareBufferANDROID,
	        },
	        vk::ExternalFormatANDROID{
	                .externalFormat = format_properties.externalFormat,
	        },
	};

	vk::raii::Image vimage(device, img_info.get());

	assert(properties.memoryTypeBits != 0);
	vk::StructureChain mem_info{
	        vk::MemoryAllocateInfo{
	                .allocationSize = properties.allocationSize,
	                .memoryTypeIndex = (uint32_t)(ffs(properties.memoryTypeBits) - 1),
	        },
	        vk::MemoryDedicatedAllocateInfo{
	                .image = *vimage,
	        },
	        vk::ImportAndroidHardwareBufferInfoANDROID{
	                .buffer = hardware_buffer,
	        },
	};

	vk::raii::DeviceMemory memory(device, mem_info.get());

	vimage.bindMemory(*memory, 0);

	vk::StructureChain iv_info{
	        vk::ImageViewCreateInfo{
	                .image = *vimage,
	                .viewType = vk::ImageViewType::e2D,
	                .format = vk::Format::eUndefined,
	                .subresourceRange = {
	                        .aspectMask = vk::ImageAspectFlagBits::eColor,
	                        .baseMipLevel = 0,
	                        .levelCount = 1,
	                        .baseArrayLayer = 0,
	                        .layerCount = 1,
	                },
	        },
	        vk::SamplerYcbcrConversionInfo{
	                .conversion = *ycbcr_conversion,
	        },
	};

	application::ignore_debug_reports_for(*vimage);
	vk::raii::ImageView image_view(device, iv_info.get());
	application::unignore_debug_reports_for(*vimage);

	auto handle = std::make_shared<mapped_hardware_buffer>();
	handle->vimage = std::move(vimage);
	handle->image_view = std::move(image_view);
	handle->memory = std::move(memory);
	handle->extent = vk::Extent2D{
	        .width = buffer_desc.width,
	        .height = buffer_desc.height,
	};

	hardware_buffer_map[hardware_buffer] = handle;
	return handle;
}

void decoder::on_media_error(AMediaCodec *, void * userdata, media_status_t error, int32_t actionCode, const char * detail)
{
	auto self = (decoder *)userdata;
	spdlog::warn("Mediacodec error {} action {}: {}", int(error), actionCode, detail ? detail : "unknown");
	helix_note_failure(self, helix_decoder_failure::async_codec);
	helix_request_recovery(self, self->weak_scene, self->stream_index, "MediaCodec asynchronous error");
}
void decoder::on_media_format_changed(AMediaCodec *, void * userdata, AMediaFormat *)
{
	spdlog::info("Mediacodec format changed");
}
void decoder::on_media_input_available(AMediaCodec * media_codec, void * userdata, int32_t index)
{
	auto self = (decoder *)userdata;
	size_t size;
	uint8_t * buffer = AMediaCodec_getInputBuffer(media_codec, index, &size);
	self->input_buffers.push({
	        .idx = index,
	        .capacity = size,
	        .data = buffer,
	});
}
void decoder::on_media_output_available(AMediaCodec * media_codec, void * userdata, int32_t index, AMediaCodecBufferInfo * bufferInfo)
{
	auto self = (decoder *)userdata;
	auto generation = helix_codec_generation(self);
	uint64_t frame_index = bufferInfo && bufferInfo->presentationTimeUs >= 0 ? static_cast<uint64_t>(bufferInfo->presentationTimeUs) / 10'000 : 0;
	helix_note_media_output(self, frame_index);
	self->jobs.push([=]() {
		if (!helix_codec_generation_matches(self, generation))
			return false;

		auto status = AMediaCodec_releaseOutputBuffer(media_codec, index, true);
		if (status != AMEDIA_OK)
		{
			spdlog::error("AMediaCodec_releaseOutputBuffer: MediaCodec error {}({})",
			              int(status),
			              std::string(magic_enum::enum_name(status)).c_str());
			helix_note_failure(self, helix_decoder_failure::output_release);
			helix_request_recovery(self, self->weak_scene, self->stream_index, "MediaCodec output release failed");
		}
		else
		{
			helix_note_output_released(self, frame_index);
		}
		return false;
	});
}

static bool hardware_accelerated(AMediaCodec * media_codec)
{
	char * name;
	AMediaCodec_getName(media_codec, &name);
	auto release = [&]() {
		AMediaCodec_releaseName(media_codec, name);
	};
	for (const char * prefix: {
	             "OMX.google",
	             "c2.android",
	     })
	{
		if (std::string_view(name).starts_with(prefix))
		{
			release();
			return false;
		}
	}
	release();
	return true;
}

void decoder::supported_codecs(std::vector<wivrn::video_codec> & result)
{
	static_assert(magic_enum::enum_count<wivrn::video_codec>() == 4);

	for (auto codec: {
	             wivrn::video_codec::av1,
	             wivrn::video_codec::h265,
	             wivrn::video_codec::h264,
	     })
	{
		AMediaCodec_ptr media_codec(AMediaCodec_createDecoderByType(mime(codec)));

		bool supported = media_codec and hardware_accelerated(media_codec.get());
		if (supported)
			result.push_back(codec);

		spdlog::info("video codec {}: {}supported", magic_enum::enum_name(codec), supported ? "" : "NOT ");
	}
}

} // namespace wivrn::android