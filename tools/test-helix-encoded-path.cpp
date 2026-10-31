// SPDX-License-Identifier: GPL-3.0-or-later
#include "helix_encoded_path.h"
#include <atomic>
#include <cassert>
#include <cstdint>
#include <span>

struct packet
{
	uint8_t stream_item_idx = 0;
	uint64_t frame_idx = 1, packet_sequence = 1;
	bool retransmission = false;
	std::span<uint8_t> payload;
};
int main(int argc, char ** argv)
{
	assert(argc == 2);
	wivrn::helix::encoded_plan plan(argv[1]);
	long long free_at = 0;
	auto e = plan.events.front();
	assert(!plan.decide(e.start - 1, free_at).first);
	if (e.loss_end > e.start)
		assert(plan.decide(e.start, free_at).first);
	auto kept = plan.decide(e.loss_end, free_at);
	assert(!kept.first && kept.second >= e.end);
	assert(plan.decide(e.end, free_at).second > kept.second);
	std::atomic<int> observed = 0;
	{
		wivrn::helix::encoded_path path(argv[1]);
		std::vector<uint8_t> bytes{42, 43};
		packet p;
		p.payload = bytes;
		path.push(p, [&observed](auto & received) { assert(received.payload[0] == 42); observed++; });
		bytes[0] = 99;
		path.close();
	}
	assert(observed == 1);
	return 0;
}
