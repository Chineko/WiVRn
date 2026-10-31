// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include "helix_encoded_path.h"
#include <charconv>
#include <cstdint>
#include <cstdlib>
#include <string_view>

namespace wivrn::helix
{
inline uint32_t encoded_bitrate_override()
{
	static const uint32_t rate = [] {
		if (!std::getenv("HELIX_ENCODED_PATH_PLAN"))
			return uint32_t(0);
		const char * text = std::getenv("HELIX_ENCODED_BITRATE_BPS");
		if (!text)
			throw std::runtime_error("missing representative bitrate input");
		uint32_t value = 0;
		std::string_view s(text);
		auto [end, error] = std::from_chars(s.data(), s.data() + s.size(), value);
		if (error != std::errc{} || end != s.data() + s.size() || value < 4'000'000 || value > 200'000'000)
			throw std::runtime_error("invalid representative bitrate input");
		return value;
	}();
	return rate;
}

// Called only on the compositor submission thread, before any present-slot state
// or image is acquired. Skipping here is lack of production, not network loss.
class production_schedule
{
	std::vector<std::pair<long long, long long>> stalls;
	std::vector<long long> idrs;
	size_t stall_index = 0, idr_index = 0, pending_idrs = 0;
	bool stalled = false;

public:
	struct decision
	{
		bool skip;
		size_t idrs;
	};
	explicit production_schedule(const std::string & path)
	{
		std::ifstream in(path);
		std::string line, extra;
		if (!std::getline(in, line) || line != "HELIX_ENCODED_PRODUCTION 1")
			throw std::runtime_error("invalid production plan header");
		while (std::getline(in, line))
		{
			std::istringstream row(line);
			char type = 0;
			long long begin = 0, end = 0;
			if (!(row >> type >> begin) || begin < 15'000'000 || begin > 1'800'000'000)
				throw std::runtime_error("invalid production plan time");
			if (type == 'S')
			{
				if (!(row >> end) || row >> extra || end <= begin || end > 1'800'000'000 || end - begin > 170'000 ||
				    (!stalls.empty() && begin <= stalls.back().second) || stalls.size() >= 512)
					throw std::runtime_error("invalid production stall");
				stalls.emplace_back(begin, end);
			}
			else if (type == 'I')
			{
				if (row >> extra || (!idrs.empty() && begin <= idrs.back()) || idrs.size() >= 512)
					throw std::runtime_error("invalid production IDR");
				idrs.push_back(begin);
			}
			else
				throw std::runtime_error("unknown production event");
		}
		if (!in.eof() || stalls.empty())
			throw std::runtime_error("empty/truncated production schedule");
		std::fprintf(stderr, "HELIX_PRODUCTION_ARM stalls=%zu idrs=%zu bitrate_bps=%u\n", stalls.size(), idrs.size(), encoded_bitrate_override());
	}
	decision at(long long elapsed)
	{
		while (stall_index < stalls.size() && elapsed >= stalls[stall_index].second)
		{
			std::fprintf(stderr, "HELIX_PRODUCER_STALL_END index=%zu at_us=%lld observed=%d\n", stall_index, elapsed, stalled);
			stalled = false;
			++stall_index;
		}
		bool skip = stall_index < stalls.size() && elapsed >= stalls[stall_index].first;
		if (skip && !stalled)
		{
			stalled = true;
			std::fprintf(stderr, "HELIX_PRODUCER_STALL_BEGIN index=%zu at_us=%lld end_us=%lld\n", stall_index, elapsed, stalls[stall_index].second);
		}
		while (idr_index < idrs.size() && elapsed >= idrs[idr_index])
		{
			++idr_index;
			++pending_idrs;
		}
		if (skip)
			return {true, 0};
		auto due = pending_idrs;
		pending_idrs = 0;
		if (due)
			std::fprintf(stderr, "HELIX_PRODUCER_IDR count=%zu at_us=%lld\n", due, elapsed);
		return {false, due};
	}
	decision now()
	{
		return at(std::chrono::duration_cast<std::chrono::microseconds>(std::chrono::steady_clock::now() - encoded_epoch()).count());
	}
};
} // namespace wivrn::helix
