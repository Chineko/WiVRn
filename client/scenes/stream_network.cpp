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

#include "stream.h"

#include "application.h"
#include "utils/i18n.h"
#include "utils/named_thread.h"

#include <spdlog/spdlog.h>
#include <uni_algo/case.h>

namespace
{
constexpr XrDuration helix_rtx_min_remaining_ns = 5'000'000; // provisional usefulness floor, not an RTT estimate
constexpr uint64_t helix_rtx_max_requests_per_gap = 8;

size_t helix_rtx_gap_bucket(uint64_t gap)
{
	if (gap <= 1)
		return 0;
	if (gap == 2)
		return 1;
	if (gap <= 4)
		return 2;
	if (gap <= 8)
		return 3;
	return 4;
}
} // namespace

void scenes::stream::process_packets()
{
#ifdef __ANDROID__
	application::instance().setup_jni();
#endif
	while (state_ != state::shutdown)
	{
		try
		{
			network_session->poll(*this, std::chrono::milliseconds(500));
		}
		catch (std::exception & e)
		{
			spdlog::info("Exception in network thread, exiting: {}", e.what());
			exit();
		}
	}

	for (size_t stream_idx = 0; stream_idx < decoders.size(); ++stream_idx)
	{
		spdlog::info(
		        "Helix UDP packet sequence summary stream={} received={} forward_gap_candidates={} late_or_duplicate={} unsequenced_control_or_fallback={} highest={}",
		        stream_idx,
		        helix_packet_sequence_received[stream_idx],
		        helix_packet_sequence_forward_gap_candidates[stream_idx],
		        helix_packet_sequence_late_or_duplicate[stream_idx],
		        helix_unsequenced_video_packets[stream_idx],
		        helix_highest_packet_sequence[stream_idx].value_or(0));
		spdlog::info(
		        "Helix RTX summary stream={} requests={} arrivals={} useful={} late={} recovered_frames={} skipped_deadline={} skipped_cross_frame={} skipped_gap_cap={} pending={} gap_hist(1/2/3-4/5-8/>8)={}/{}/{}/{}/{}",
		        stream_idx,
		        helix_rtx_requests[stream_idx],
		        helix_rtx_arrivals[stream_idx],
		        helix_rtx_arrivals_useful[stream_idx],
		        helix_rtx_arrivals_late[stream_idx],
		        helix_rtx_recovered_frames[stream_idx],
		        helix_rtx_skipped_deadline[stream_idx],
		        helix_rtx_skipped_cross_frame[stream_idx],
		        helix_rtx_skipped_gap_cap[stream_idx],
		        helix_rtx_pending[stream_idx].size(),
		        helix_rtx_gap_hist[stream_idx][0],
		        helix_rtx_gap_hist[stream_idx][1],
		        helix_rtx_gap_hist[stream_idx][2],
		        helix_rtx_gap_hist[stream_idx][3],
		        helix_rtx_gap_hist[stream_idx][4]);
	}
}

void scenes::stream::operator()(to_headset::server_message && message)
{
	switch (message.kind)
	{
		case to_headset::server_message::kind::toast:
		case to_headset::server_message::kind::toast_urgent: {
			auto toast = gui_toast.lock();
			toast->emplace(message.msg, message.kind == to_headset::server_message::kind::toast_urgent);

			gui_status_last_change = instance.now();
			break;
		}

		case to_headset::server_message::kind::error: {
			auto queue = stream_error_queue.lock();
			queue->emplace(std::move(message.msg));

			break;
		}
	}
}

void scenes::stream::operator()(to_headset::video_stream_data_shard && shard)
{
	std::shared_lock lock(decoder_mutex);
	uint8_t idx = shard.stream_item_idx;
	if (idx >= decoders.size())
	{
		// We don't know (yet?) about this stream, ignore packet
		return;
	}

	auto now = instance.now();
	if (shard.view_info)
		helix_rtx_frame_deadline[idx] = helix_rtx_deadline{
		        .frame_idx = shard.frame_idx,
		        .display_time = shard.view_info->display_time,
	};

	if (shard.packet_sequence == 0)
	{
		++helix_unsequenced_video_packets[idx];
	}
	else
	{
		++helix_packet_sequence_received[idx];
		auto & highest = helix_highest_packet_sequence[idx];

		if (auto pending = helix_rtx_pending[idx].find(shard.packet_sequence); pending != helix_rtx_pending[idx].end())
		{
			if (shard.retransmission)
			{
				++helix_rtx_arrivals[idx];
				if (decoders[idx].decoder->accepts_frame(shard.frame_idx) && pending->second == shard.frame_idx)
					++helix_rtx_arrivals_useful[idx];
				else
					++helix_rtx_arrivals_late[idx];
			}
			helix_rtx_pending[idx].erase(pending);
		}

		if (highest)
		{
			if (shard.packet_sequence > *highest)
			{
				auto delta = shard.packet_sequence - *highest;
				if (delta > 1)
				{
					auto gap = delta - 1;
					helix_packet_sequence_forward_gap_candidates[idx] += gap;
					helix_rtx_gap_hist[idx][helix_rtx_gap_bucket(gap)]++;

					try
					{
						network_session->send_control(wivrn::from_headset::video_gap_report{
						        .stream_index = idx,
						        .first_missing_sequence = *highest + 1,
						        .missing_count = gap,
						        .exposing_sequence = shard.packet_sequence,
						        .exposing_frame_idx = shard.frame_idx,
						});
					}
					catch (const std::exception & e)
					{
						spdlog::warn(
						        "Helix gap report send failed stream={} first={} count={}: {}",
						        idx,
						        *highest + 1,
						        gap,
						        e.what());
					}

					// Only the sequence positions immediately preceding this shard that fit
					// within shard_idx are provably part of this same frame. Anything
					// earlier may belong to the previous frame and is intentionally skipped.
					auto same_frame_missing = std::min<uint64_t>(gap, shard.shard_idx);
					helix_rtx_skipped_cross_frame[idx] += gap - same_frame_missing;

					bool frame_relevant = decoders[idx].decoder->accepts_frame(shard.frame_idx);
					bool deadline_ok = true;
					if (auto deadline = helix_rtx_frame_deadline[idx];
					    deadline && deadline->frame_idx == shard.frame_idx)
					{
						deadline_ok = deadline->display_time > now + helix_rtx_min_remaining_ns;
					}

					if (!frame_relevant || !deadline_ok)
					{
						helix_rtx_skipped_deadline[idx] += same_frame_missing;
					}
					else if (same_frame_missing > helix_rtx_max_requests_per_gap)
					{
						// A frame with more than the bounded RTX budget already missing is
						// treated as burst-loss territory rather than sending a partial rescue.
						helix_rtx_skipped_gap_cap[idx] += same_frame_missing;
					}
					else if (same_frame_missing > 0)
					{
						auto first_sequence = shard.packet_sequence - same_frame_missing;
						for (uint64_t sequence = first_sequence; sequence < shard.packet_sequence; ++sequence)
						{
							try
							{
								network_session->send_control(wivrn::from_headset::video_retransmission_request{
								        .stream_index = idx,
								        .packet_sequence = sequence,
								});
								helix_rtx_pending[idx][sequence] = shard.frame_idx;
								++helix_rtx_requests[idx];
							}
							catch (const std::exception & e)
							{
								spdlog::warn("Helix RTX request send failed stream={} sequence={}: {}", idx, sequence, e.what());
								break;
							}
						}
					}
				}
				highest = shard.packet_sequence;
			}
			else
			{
				++helix_packet_sequence_late_or_duplicate[idx];
			}
		}
		else
		{
			if (shard.packet_sequence > 1)
			{
				auto gap = shard.packet_sequence - 1;
				helix_packet_sequence_forward_gap_candidates[idx] += gap;
				helix_rtx_gap_hist[idx][helix_rtx_gap_bucket(gap)]++;
			}
			highest = shard.packet_sequence;
		}
	}

	decoders[idx].decoder->push_shard(std::move(shard));
}

void scenes::stream::operator()(to_headset::feature_control && control)
{
	switch (control.f)
	{
		case wivrn::to_headset::feature_control::hid_input:
			hid_forwarding = control.state;
			if (not control.state and (application::get_config().forward_keyboard or application::get_config().forward_mouse or application::get_config().forward_gamepad))
			{
				auto toast = gui_toast.lock();
				toast->emplace(_("The server does not allow forwarded input devices"), true);
				gui_status_last_change = instance.now();
			}
			return;
		case wivrn::to_headset::feature_control::microphone:
			if (audio_handle)
				audio_handle->set_mic_state(control.state);
			return;
	}
}

void scenes::stream::operator()(to_headset::audio_stream_description && desc)
{
	audio_handle.emplace(desc, *network_session, instance);
}

void scenes::stream::operator()(to_headset::video_stream_description && desc)
{
	setup(desc);

	if (not tracking_thread)
	{
		tracking_thread = utils::named_thread("tracking_thread", &stream::tracking, this);
	}
}

void scenes::stream::operator()(to_headset::refresh_rate_change && rate)
{
	spdlog::info("refresh rate change request: {}", rate.hz);
	session.set_refresh_rate(rate.hz);
	std::shared_lock lock(decoder_mutex);
	if (video_stream_description)
		video_stream_description->refresh_rate = rate.hz;
}

void scenes::stream::operator()(to_headset::stream_tab_change && tab)
{
	next_gui_status = tab.tab;
}

void scenes::stream::operator()(to_headset::timesync_query && query)
{
	network_session->send_stream(from_headset::timesync_response{
	        .query = query.query,
	        .response = instance.now(),
	});
}

void scenes::stream::operator()(audio_data && data)
{
	if (audio_handle)
		(*audio_handle)(std::move(data));
}

void scenes::stream::send_feedback(const wivrn::from_headset::feedback & feedback)
{
	try
	{
		network_session->send_control(wivrn::from_headset::feedback{feedback});
	}
	catch (std::exception & e)
	{
		spdlog::warn("Exception while sending feedback packet: {}", e.what());
	}
}

void scenes::stream::operator()(to_headset::application_list && l)
{
	apps(std::move(l));
}

void scenes::stream::operator()(to_headset::application_icon && icon)
{
	apps(std::move(icon));
}

void scenes::stream::operator()(to_headset::running_applications && apps)
{
	*running_applications.lock() = std::move(apps);
}

void scenes::stream::start_application(std::string appid)
{
	network_session->send_control(wivrn::from_headset::start_app{
	        .app_id = std::move(appid),
	});
}
