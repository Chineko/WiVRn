// Preflight for Helix VRChat-like traces: runs the exact loader/validator the synthetic
// server mode uses, without WiVRn, a headset or a GPU.
//
//   c++ -std=c++20 -O2 -I server tools/helix-vrchat-trace-check.cpp -o helix-vrchat-trace-check
//   ./helix-vrchat-trace-check <trace>
//
// Exit status: 0 valid, 2 invalid. The limits below must match
// server/helix_synthetic_transport.cpp (receiver raw frame buffer / UDP shard payload).
#include "helix_vrchat_trace.h"

#include <algorithm>
#include <cstdio>
#include <string>

int main(int argc, char ** argv)
{
	if (argc != 2)
	{
		std::fprintf(stderr, "usage: %s <trace>\n", argv[0]);
		return 2;
	}
	const wivrn::helix_vrchat_trace::limits lim{
	        .max_frame_bytes = 256u * 160u * 3u / 2u,
	        .max_shard_payload = 1400,
	        .max_shards = 64,
	        .max_rows = 6'000'000,
	        .max_duration_us = 1'800'000'000,
	};
	wivrn::helix_vrchat_trace::trace tr;
	std::string error;
	if (!wivrn::helix_vrchat_trace::load(argv[1], lim, tr, error))
	{
		std::printf("TRACE_INVALID %s\n", error.c_str());
		return 2;
	}
	size_t dropped_rows = 0, incomplete_frames = 0, max_frame = 0;
	int64_t last_send = 0, max_delay = 0;
	for (const auto & r: tr.rows)
	{
		dropped_rows += r.drop;
		if (!r.drop)
		{
			last_send = std::max(last_send, r.t_send_us);
			max_delay = std::max(max_delay, r.t_send_us - r.t_gen_us);
		}
	}
	for (const auto & [key, info]: tr.frames)
	{
		incomplete_frames += info.has_drop;
		max_frame = std::max<size_t>(max_frame, info.bytes);
	}
	std::printf("TRACE_VALID rows=%zu frames=%zu dropped_rows=%zu expected_incomplete_frames=%zu max_frame_bytes=%zu "
	            "last_send_s=%.3f max_path_delay_ms=%.3f\n",
	            tr.rows.size(), tr.frames.size(), dropped_rows, incomplete_frames, max_frame,
	            double(last_send) / 1e6, double(max_delay) / 1e3);
	return 0;
}
