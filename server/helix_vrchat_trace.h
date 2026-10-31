#pragma once

// Header-only loader/validator for Helix VRChat-like workload traces
// (written by tools/helix-vrchat-workload-model.py). It depends only on the C++ standard
// library so it can be unit-checked without the WiVRn build (see
// tools/helix-vrchat-trace-check.cpp).
//
// The validator is a safety gate: the Quest raw decoder copies shard payloads into a fixed
// size buffer without a bounds check, so a trace whose frames exceed that buffer must be
// rejected before a single packet is sent.

#include <cstdint>
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace wivrn::helix_vrchat_trace
{
struct row
{
	int64_t t_send_us; // -1 for path-dropped rows
	int64_t t_gen_us;
	uint8_t stream;
	uint64_t frame;
	uint16_t shard;
	uint16_t shards;
	uint16_t bytes;
	bool drop;
};

struct limits
{
	size_t max_frame_bytes;
	size_t max_shard_payload;
	uint16_t max_shards;
	size_t max_rows;
	int64_t max_duration_us;
};

struct frame_info
{
	bool has_drop = false;
	uint32_t bytes = 0;
	uint16_t shards = 0;
};

struct trace
{
	std::vector<row> rows;
	std::map<std::pair<uint8_t, uint64_t>, frame_info> frames;
};

inline bool load(const char * path, const limits & lim, trace & out, std::string & error)
{
	out = {};
	FILE * f = std::fopen(path, "r");
	if (!f)
	{
		error = "cannot open trace file";
		return false;
	}

	struct stream_state
	{
		bool started = false;
		uint64_t frame = 0;
		uint16_t shards = 0;
		uint16_t next_shard = 0;
	};
	stream_state state[2];
	int64_t last_send = -1;
	char line[256];
	size_t line_no = 0;

	auto fail = [&](const std::string & msg) {
		error = "line " + std::to_string(line_no) + ": " + msg;
		std::fclose(f);
		return false;
	};

	while (std::fgets(line, sizeof(line), f))
	{
		++line_no;
		if (line[0] == '#' || line[0] == '\n' || line[0] == '\0')
			continue;

		long long t_gen = 0, t_send = 0;
		unsigned stream = 0, shard = 0, shards = 0, bytes = 0;
		unsigned long long frame = 0;
		char fate = 0;
		if (std::sscanf(line, "P,%lld,%lld,%u,%llu,%u,%u,%u,%c", &t_gen, &t_send, &stream, &frame, &shard, &shards, &bytes, &fate) != 8)
			return fail("malformed row");
		if (stream > 1)
			return fail("stream must be 0 or 1");
		if (shards < 1 || shards > lim.max_shards)
			return fail("shards_in_frame out of range");
		if (shard >= shards)
			return fail("shard_idx >= shards_in_frame");
		if (bytes < 1 || bytes > lim.max_shard_payload)
			return fail("payload_bytes out of range");
		if (fate != 'K' && fate != 'D')
			return fail("fate must be K or D");
		if (t_gen < 0 || t_gen > lim.max_duration_us)
			return fail("t_gen out of range");
		if (fate == 'D')
		{
			if (t_send != -1)
				return fail("dropped row must have t_send=-1");
		}
		else
		{
			if (t_send < t_gen || t_send > lim.max_duration_us)
				return fail("t_send before t_gen or beyond max duration");
			if (t_send < last_send)
				return fail("t_send decreases (reordering is not supported)");
			last_send = t_send;
		}
		if (out.rows.size() >= lim.max_rows)
			return fail("too many rows");

		auto & st = state[stream];
		if (!st.started)
		{
			if (shard != 0)
				return fail("stream must start on shard 0");
		}
		else if (frame == st.frame)
		{
			if (shard != st.next_shard || shards != st.shards)
				return fail("shards of a frame must be consecutive with a constant shard count");
		}
		else if (frame == st.frame + 1)
		{
			if (st.next_shard != st.shards)
				return fail("previous frame truncated");
			if (shard != 0)
				return fail("new frame must start on shard 0");
		}
		else
			return fail("frame index must increase by exactly 1");

		st.started = true;
		st.frame = frame;
		st.shards = uint16_t(shards);
		st.next_shard = uint16_t(shard + 1);

		auto & info = out.frames[{uint8_t(stream), uint64_t(frame)}];
		info.bytes += bytes;
		info.shards = uint16_t(shards);
		info.has_drop |= fate == 'D';
		if (info.bytes > lim.max_frame_bytes)
			return fail("frame payload exceeds the receiver frame buffer");

		out.rows.push_back(row{
		        .t_send_us = fate == 'D' ? -1 : int64_t(t_send),
		        .t_gen_us = int64_t(t_gen),
		        .stream = uint8_t(stream),
		        .frame = uint64_t(frame),
		        .shard = uint16_t(shard),
		        .shards = uint16_t(shards),
		        .bytes = uint16_t(bytes),
		        .drop = fate == 'D',
		});
	}
	std::fclose(f);

	for (const auto & s: state)
		if (s.started && s.next_shard != s.shards)
		{
			error = "trace ends inside a frame";
			return false;
		}
	if (out.rows.empty())
	{
		error = "empty trace";
		return false;
	}
	return true;
}
} // namespace wivrn::helix_vrchat_trace
