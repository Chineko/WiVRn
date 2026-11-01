// SPDX-License-Identifier: GPL-3.0-or-later
#include "helix-stimulus-pattern.h"
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>

int main(int argc, char ** argv)
{
	// Exhaust all channel endpoint combinations, including the old 15/16 boundary.
	for (unsigned base = 0; base < 256; ++base)
		for (unsigned noise = 0; noise < 256; ++noise)
		{
			int previous = 0;
			int previous_value = base;
			for (unsigned level = 0; level < 32; ++level)
			{
				const auto rgb = helix_stimulus::pixel(base * 0x010101u, noise * 0x010101u, level);
				const int value = rgb & 255u;
				const int distance = std::abs(value - int(base));
				assert(distance >= previous && (rgb >> 24) == 255u);
				assert(std::abs(value - previous_value) <= 9);
				if (level == 0)
					assert(value == int(base));
				if (level == 31)
					assert(value == int(noise));
				previous = distance;
				previous_value = value;
			}
		}
	if (argc == 2 && std::strcmp(argv[1], "--raw") == 0)
	{
		// Fixed-size controlled spatial-complexity sweep for offline HEVC tests.
		for (unsigned level = 0; level < 32; ++level)
		{
			uint32_t seed = helix_stimulus::noise_seed;
			for (unsigned y = 0; y < 160; ++y)
				for (unsigned x = 0; x < 256; ++x)
				{
					const auto pixel = helix_stimulus::pixel(helix_stimulus::base_pixel(0, x, y), helix_stimulus::next_noise(seed), level);
					const unsigned char rgb[] = {static_cast<unsigned char>(pixel), static_cast<unsigned char>(pixel >> 8), static_cast<unsigned char>(pixel >> 16)};
					if (std::fwrite(rgb, 1, 3, stdout) != 3)
						return 2;
				}
		}
		return std::fflush(stdout) == 0 ? 0 : 2;
	}
	std::puts("PASS: exhaustive monotonic channel distance, endpoints and alpha");
}
