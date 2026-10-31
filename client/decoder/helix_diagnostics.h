/*
 * WiVRn Helix diagnostics
 *
 * Lightweight, bounded telemetry shared by the network frame assembler and
 * decoder. Keep this header allocation-free on hot paths: it stores counters,
 * timestamps and fixed-size histograms only, and logs elsewhere only on
 * incidents or teardown.
 */

#pragma once

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <mutex>
#include <optional>

namespace wivrn::helix_diag
{
using clock = std::chrono::steady_clock;

constexpr size_t stream_count = 3;
constexpr size_t latency_bucket_count = 6;

inline size_t latency_bucket(uint64_t us)
{
	if (us < 5'000)
		return 0;
	if (us < 10'000)
		return 1;
	if (us < 20'000)
		return 2;
	if (us < 40'000)
		return 3;
	if (us < 80'000)
		return 4;
	return 5;
}

struct network_snapshot
{
	uint64_t completed_frames = 0;
	uint64_t incomplete_frames = 0;
	uint64_t zero_shard_frames = 0;
	uint64_t missing_shards = 0;
	uint64_t old_shards = 0;
	uint64_t frame_jump_events = 0;
	uint64_t skipped_frames = 0;
	uint64_t last_assembly_us = 0;
	uint64_t max_assembly_us = 0;
	uint64_t since_incomplete_us = std::numeric_limits<uint64_t>::max();
	uint64_t since_old_shard_us = std::numeric_limits<uint64_t>::max();
	uint64_t since_frame_jump_us = std::numeric_limits<uint64_t>::max();
	std::array<uint64_t, latency_bucket_count> assembly_hist{};
};

struct network_state
{
	std::mutex mutex;
	uint64_t completed_frames = 0;
	uint64_t incomplete_frames = 0;
	uint64_t zero_shard_frames = 0;
	uint64_t missing_shards = 0;
	uint64_t old_shards = 0;
	uint64_t frame_jump_events = 0;
	uint64_t skipped_frames = 0;
	uint64_t last_assembly_us = 0;
	uint64_t max_assembly_us = 0;
	std::array<uint64_t, latency_bucket_count> assembly_hist{};
	clock::time_point last_incomplete{};
	clock::time_point last_old_shard{};
	clock::time_point last_frame_jump{};
};

inline std::array<network_state, stream_count> & network_states()
{
	static std::array<network_state, stream_count> states;
	return states;
}

inline network_state & network(uint8_t stream_index)
{
	return network_states()[std::min<size_t>(stream_index, stream_count - 1)];
}

inline uint64_t age_us(clock::time_point now, clock::time_point then)
{
	if (then == clock::time_point{})
		return std::numeric_limits<uint64_t>::max();
	return static_cast<uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(now - then).count());
}

inline void note_frame_complete(uint8_t stream_index, uint64_t assembly_us)
{
	auto & state = network(stream_index);
	std::scoped_lock lock(state.mutex);
	state.completed_frames++;
	state.last_assembly_us = assembly_us;
	state.max_assembly_us = std::max(state.max_assembly_us, assembly_us);
	state.assembly_hist[latency_bucket(assembly_us)]++;
}

inline void note_incomplete_frame(uint8_t stream_index, uint64_t missing_shards, bool zero_shards)
{
	auto & state = network(stream_index);
	std::scoped_lock lock(state.mutex);
	state.incomplete_frames++;
	state.missing_shards += missing_shards;
	if (zero_shards)
		state.zero_shard_frames++;
	state.last_incomplete = clock::now();
}

inline void note_old_shard(uint8_t stream_index)
{
	auto & state = network(stream_index);
	std::scoped_lock lock(state.mutex);
	state.old_shards++;
	state.last_old_shard = clock::now();
}

inline void note_frame_jump(uint8_t stream_index, uint64_t skipped_frames)
{
	auto & state = network(stream_index);
	std::scoped_lock lock(state.mutex);
	state.frame_jump_events++;
	state.skipped_frames += skipped_frames;
	state.last_frame_jump = clock::now();
}

inline network_snapshot snapshot(uint8_t stream_index)
{
	auto & state = network(stream_index);
	std::scoped_lock lock(state.mutex);
	auto now = clock::now();
	return {
	        .completed_frames = state.completed_frames,
	        .incomplete_frames = state.incomplete_frames,
	        .zero_shard_frames = state.zero_shard_frames,
	        .missing_shards = state.missing_shards,
	        .old_shards = state.old_shards,
	        .frame_jump_events = state.frame_jump_events,
	        .skipped_frames = state.skipped_frames,
	        .last_assembly_us = state.last_assembly_us,
	        .max_assembly_us = state.max_assembly_us,
	        .since_incomplete_us = age_us(now, state.last_incomplete),
	        .since_old_shard_us = age_us(now, state.last_old_shard),
	        .since_frame_jump_us = age_us(now, state.last_frame_jump),
	        .assembly_hist = state.assembly_hist,
	};
}

constexpr size_t hevc10_probe_slots = 8;

struct hevc10_probe_snapshot
{
	uint64_t rtx_assembled = 0;
	uint64_t rtx_media_output = 0;
	uint64_t image_after_rtx = 0;
	uint64_t overflow = 0;
	size_t pending_media = 0;
	size_t pending_image = 0;
};

struct hevc10_probe_state
{
	std::mutex mutex;
	std::array<std::optional<uint64_t>, hevc10_probe_slots> pending_media{};
	std::array<std::optional<uint64_t>, hevc10_probe_slots> pending_image{};
	uint64_t rtx_assembled = 0;
	uint64_t rtx_media_output = 0;
	uint64_t image_after_rtx = 0;
	uint64_t overflow = 0;
};

inline std::array<hevc10_probe_state, stream_count> & hevc10_probe_states()
{
	static std::array<hevc10_probe_state, stream_count> states;
	return states;
}

inline hevc10_probe_state & hevc10_probe(uint8_t stream_index)
{
	return hevc10_probe_states()[std::min<size_t>(stream_index, stream_count - 1)];
}

// An experiment permits one decoder epoch only. Reset stale state explicitly;
// the reducer rejects recreation/flush instead of attributing across generations.
inline uint64_t hevc10_begin_epoch(uint8_t stream_index)
{
	static std::array<uint64_t, stream_count> epochs{};
	auto & state = hevc10_probe(stream_index);
	std::scoped_lock lock(state.mutex);
	state.pending_media = {};
	state.pending_image = {};
	state.rtx_assembled = state.rtx_media_output = state.image_after_rtx = state.overflow = 0;
	return ++epochs[std::min<size_t>(stream_index, stream_count - 1)];
}

template <size_t N>
inline bool hevc10_insert_unique(std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)
{
	for (const auto & slot: slots)
		if (slot && *slot == frame_index)
			return true;
	for (auto & slot: slots)
	{
		if (!slot)
		{
			slot = frame_index;
			return true;
		}
	}
	return false;
}

template <size_t N>
inline bool hevc10_erase_exact(std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)
{
	for (auto & slot: slots)
	{
		if (slot && *slot == frame_index)
		{
			slot.reset();
			return true;
		}
	}
	return false;
}

template <size_t N>
inline std::optional<uint64_t> hevc10_erase_oldest_leq(
        std::array<std::optional<uint64_t>, N> & slots, uint64_t frame_index)
{
	std::optional<size_t> best;
	for (size_t i = 0; i < N; ++i)
	{
		if (!slots[i] || *slots[i] > frame_index)
			continue;
		if (!best || *slots[i] < *slots[*best])
			best = i;
	}
	if (!best)
		return {};
	auto recovered = slots[*best];
	slots[*best].reset();
	return recovered;
}

inline void hevc10_note_rtx_assembled(uint8_t stream_index, uint64_t frame_index)
{
	auto & state = hevc10_probe(stream_index);
	std::scoped_lock lock(state.mutex);
	state.rtx_assembled++;
	if (!hevc10_insert_unique(state.pending_media, frame_index))
		state.overflow++;
}

inline bool hevc10_note_media_output(uint8_t stream_index, uint64_t frame_index)
{
	auto & state = hevc10_probe(stream_index);
	std::scoped_lock lock(state.mutex);
	if (!hevc10_erase_exact(state.pending_media, frame_index))
		return false;
	state.rtx_media_output++;
	if (!hevc10_insert_unique(state.pending_image, frame_index))
		state.overflow++;
	return true;
}

inline std::optional<uint64_t> hevc10_note_image(uint8_t stream_index, uint64_t frame_index)
{
	auto & state = hevc10_probe(stream_index);
	std::scoped_lock lock(state.mutex);
	auto recovered = hevc10_erase_oldest_leq(state.pending_image, frame_index);
	if (recovered)
		state.image_after_rtx++;
	return recovered;
}

inline hevc10_probe_snapshot hevc10_probe_snapshot_for(uint8_t stream_index)
{
	auto & state = hevc10_probe(stream_index);
	std::scoped_lock lock(state.mutex);
	size_t pending_media = 0;
	size_t pending_image = 0;
	for (const auto & slot: state.pending_media)
		pending_media += bool(slot);
	for (const auto & slot: state.pending_image)
		pending_image += bool(slot);
	return {
	        .rtx_assembled = state.rtx_assembled,
	        .rtx_media_output = state.rtx_media_output,
	        .image_after_rtx = state.image_after_rtx,
	        .overflow = state.overflow,
	        .pending_media = pending_media,
	        .pending_image = pending_image,
	};
}

struct peer_stall_result
{
	uint64_t peer_age_us = std::numeric_limits<uint64_t>::max();
	bool within_5ms = false;
	bool within_10ms = false;
	bool within_20ms = false;
	bool within_50ms = false;
};

struct stall_state
{
	std::mutex mutex;
	std::array<clock::time_point, stream_count> last_stall{};
};

inline stall_state & stalls()
{
	static stall_state state;
	return state;
}

inline peer_stall_result note_stall(uint8_t stream_index)
{
	auto now = clock::now();
	auto & state = stalls();
	std::scoped_lock lock(state.mutex);

	peer_stall_result result;
	for (size_t i = 0; i < stream_count; ++i)
	{
		if (i == stream_index || state.last_stall[i] == clock::time_point{})
			continue;
		auto age = age_us(now, state.last_stall[i]);
		result.peer_age_us = std::min(result.peer_age_us, age);
	}
	state.last_stall[std::min<size_t>(stream_index, stream_count - 1)] = now;

	if (result.peer_age_us != std::numeric_limits<uint64_t>::max())
	{
		result.within_5ms = result.peer_age_us <= 5'000;
		result.within_10ms = result.peer_age_us <= 10'000;
		result.within_20ms = result.peer_age_us <= 20'000;
		result.within_50ms = result.peer_age_us <= 50'000;
	}
	return result;
}

} // namespace wivrn::helix_diag
