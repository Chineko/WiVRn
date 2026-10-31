// SPDX-License-Identifier: GPL-3.0-or-later
#include "helix_production_schedule.h"
#include <cassert>
int main(int argc, char ** argv)
{
	assert(argc >= 2);
	wivrn::helix::production_schedule plan(argv[1]);
	if (argc == 3)
		return 0;
	auto before = plan.at(14'999'999);
	assert(!before.skip && before.idrs == 0);
	assert(plan.at(15'000'000).skip);
	auto during = plan.at(15'030'000);
	assert(during.skip && during.idrs == 0);
	auto resumed = plan.at(15'050'000);
	assert(!resumed.skip && resumed.idrs == 1);
	assert(plan.at(15'050'001).idrs == 0);
}
