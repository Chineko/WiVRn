// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#include <algorithm>
#include <cstdint>

namespace helix_stimulus
{
constexpr uint32_t noise_seed = 0x6d2b79f5u;
constexpr uint32_t next_noise(uint32_t & seed)
{
	seed ^= seed << 13;
	seed ^= seed >> 17;
	seed ^= seed << 5;
	return seed;
}

constexpr uint32_t base_pixel(uint32_t eye, uint32_t x, uint32_t y)
{
	return ((x >> 5u) ^ (y >> 5u) ^ eye) & 1u ? 0x00c06020u : 0x002040c0u;
}

// Fixed geometry and fixed noise samples across levels. Linear interpolation
// makes each channel's distance from the base nondecreasing, without clipping.
constexpr uint32_t pixel(uint32_t base, uint32_t noise, uint32_t level)
{
	level = std::min(level, 31u);
	uint32_t rgb = 0xff000000u;
	for (uint32_t shift: {0u, 8u, 16u})
	{
		const auto b = (base >> shift) & 255u;
		const auto n = (noise >> shift) & 255u;
		rgb |= ((b * (31u - level) + n * level + 15u) / 31u) << shift;
	}
	return rgb;
}
} // namespace helix_stimulus
