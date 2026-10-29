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

#pragma once

#include "driver/clock_offset.h"
#include "idr_handler.h"
#include "wivrn_packets.h"

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <fstream>
#include <memory>
#include <mutex>
#include <optional>
#include <thread>
#include <vector>
#include <vulkan/vulkan_raii.hpp>

namespace wivrn
{

struct encoder_settings;
struct vk_bundle;
class wivrn_session;

inline const char * encoder_nvenc = "nvenc";
inline const char * encoder_vaapi = "vaapi";
inline const char * encoder_x264 = "x264";
inline const char * encoder_vulkan = "vulkan";
inline const char * encoder_raw = "raw";

class video_encoder
{
protected:
	struct data
	{
		video_encoder * encoder;
		std::span<uint8_t> span;
		std::shared_ptr<void> mem;
		// true if data should be sent over reliable (TCP) socket
		bool prefer_control = false;
	};

private:
	class sender
	{
		struct queued_data
		{
			data payload;
			std::chrono::steady_clock::time_point enqueued_at;
		};

		std::mutex mutex;
		std::condition_variable cv;
		std::deque<queued_data> pending;
		std::jthread thread;
		void run();
		sender();

	public:
		void push(data &&);
		static std::shared_ptr<sender> get();
		void wait_idle(video_encoder *);
	};

public:
	const uint8_t stream_idx;
	const uint32_t target_queue;
	const bool need_transfer;
	// Layout the encoder needs y_cbcr to arrive in. Set during construction
	// or init() and read by the compositor on every layer_commit — must not
	// change after the first frame.
	vk::ImageLayout target_layout = vk::ImageLayout::eGeneral;
	static const uint8_t num_slots = 2;
	const double bitrate_multiplier;

private:
	using state_t = std::atomic_unsigned_lock_free::value_type;
	static const state_t idle = 0;
	static const state_t busy = 1;
	static const state_t skip = 2;
	std::array<std::atomic_unsigned_lock_free, num_slots> state = {idle, idle};
	uint8_t present_slot = 0;
	uint8_t encode_slot = 0;

	std::mutex mutex;

	// temporary data
	wivrn_session * cnx;

	// shard to send
	to_headset::video_stream_data_shard shard;

	to_headset::video_stream_data_shard::timing_info_t timing_info;
	clock_offset clock;

	std::ofstream video_dump;

	std::shared_ptr<sender> shared_sender;

	// Helix 0.2 telemetry: measure the existing unpaced sender before changing behavior.
	std::chrono::steady_clock::time_point helix_frame_send_started_at{};
	std::optional<std::chrono::steady_clock::time_point> helix_last_frame_send_started_at;
	uint64_t helix_current_frame_bytes = 0;
	uint64_t helix_current_frame_shards = 0;
	uint64_t helix_packet_sequence = 1;

	struct helix_rtx_cache_entry
	{
		uint64_t packet_sequence;
		uint64_t frame_idx;
		uint16_t shard_idx;
		uint64_t send_attempt_ns;
		std::optional<to_headset::video_stream_data_shard::view_info_t> view_info;
		std::optional<to_headset::video_stream_data_shard::timing_info_t> timing_info;
		std::vector<uint8_t> payload;
	};
	static constexpr size_t helix_rtx_cache_limit = 512;
	std::deque<helix_rtx_cache_entry> helix_rtx_cache;
	uint64_t helix_rtx_requests = 0;
	uint64_t helix_rtx_cache_hits = 0;
	uint64_t helix_rtx_cache_misses = 0;
	uint64_t helix_rtx_sent = 0;
	uint64_t helix_rtx_bytes = 0;
	uint64_t helix_rtx_send_time_total_us = 0;
	uint64_t helix_rtx_send_time_max_us = 0;
	uint64_t helix_rtx_send_errors = 0;
	uint64_t helix_initial_send_errors = 0;

	uint64_t helix_gap_reports = 0;
	uint64_t helix_gap_positions = 0;
	uint64_t helix_gap_fully_mapped = 0;
	uint64_t helix_gap_partially_mapped = 0;
	uint64_t helix_gap_unmapped = 0;
	std::array<uint64_t, 6> helix_gap_send_span_hist{};
	std::array<uint64_t, 5> helix_gap_frame_span_hist{};
	uint64_t helix_gap_report_delay_samples = 0;
	uint64_t helix_gap_report_delay_total_us = 0;
	uint64_t helix_gap_report_delay_max_us = 0;

	// Helix bounded time-diverse recovery prototype. Protect complete, bounded
	// NVENC reference frames only; never send a partial recovery copy.
	static constexpr size_t helix_td_max_shards = 48;
	static constexpr uint64_t helix_td_budget_divisor = 5; // <= 20% fresh payload long-run
	static constexpr uint64_t helix_td_credit_cap_bytes =
	        helix_td_max_shards * to_headset::video_stream_data_shard::max_payload_size * 2;
	bool helix_td_enabled = false;
	uint64_t helix_td_credit_bytes = 0;
	std::optional<uint64_t> helix_td_pending_frame;
	uint64_t helix_td_fresh_bytes = 0;
	uint64_t helix_td_replay_bytes = 0;
	uint64_t helix_td_reference_frames = 0;
	uint64_t helix_td_scheduled_frames = 0;
	uint64_t helix_td_replayed_frames = 0;
	uint64_t helix_td_replayed_shards = 0;
	uint64_t helix_td_skipped_oversize = 0;
	uint64_t helix_td_skipped_budget = 0;
	uint64_t helix_td_expired = 0;
	uint64_t helix_td_send_errors = 0;

	bool retransmit_cached(uint64_t packet_sequence);
	void helix_send_time_diverse_replay(uint64_t next_frame_idx);
	void helix_finish_time_diverse_frame(bool control);

protected:
	std::atomic_uint32_t pending_bitrate;
	std::atomic<float> pending_framerate;
	std::unique_ptr<idr_handler> idr;
	const vk::Extent2D extent;

public:
	static std::unique_ptr<video_encoder> create(
	        wivrn::vk_bundle &,
	        const encoder_settings & settings,
	        uint8_t stream_idx);

	static bool request_retransmission(uint8_t stream_index, uint64_t packet_sequence);
	static void report_gap(const from_headset::video_gap_report & report);

	video_encoder(vk_bundle &, uint8_t stream_idx, uint32_t target_queue, const encoder_settings & settings, std::unique_ptr<idr_handler>, bool async_send);
	virtual ~video_encoder();

	void present_image(vk::Image y_cbcr,
	                   vk::SemaphoreSubmitInfo sem_info,
	                   uint64_t frame_index);

	void on_feedback(const from_headset::feedback &);
	void reset();

	// bitrate_bps is the bitrate for the whole stream
	// the encoder bitrate will be scaled accordingly
	void set_bitrate(uint32_t bitrate_bps);
	void set_framerate(float framerate);

	void encode(wivrn_session & cnx,
	            const to_headset::video_stream_data_shard::view_info_t & view_info,
	            uint64_t frame_index);

protected:
	// called on present to submit command buffers for the image.
	virtual void present_image(vk::Image y_cbcr,
	                           vk::SemaphoreSubmitInfo sem_info,
	                           uint8_t slot,
	                           uint64_t frame_index) = 0;

	// called when command buffer finished executing
	virtual std::optional<data> encode(uint8_t slot, uint64_t frame_index) = 0;

	void SendData(std::span<uint8_t> data, bool end_of_frame, bool control = false);
};

} // namespace wivrn
