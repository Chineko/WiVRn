// SPDX-License-Identifier: GPL-3.0-or-later
// Opt-in, session-owned FIFO impairment of real encoded video, including RTX.
#pragma once
#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <deque>
#include <fstream>
#include <functional>
#include <mutex>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

namespace wivrn::helix
{
struct path_event
{
	long long start, loss_end, end;
};
struct encoded_plan
{
	long long duration = 0;
	std::vector<path_event> events;
	explicit encoded_plan(const std::string & path)
	{
		std::ifstream in(path);
		std::string line, extra;
		if (!std::getline(in, line) || line != "HELIX_ENCODED_PLAN 1")
			throw std::runtime_error("invalid encoded plan header");
		if (!std::getline(in, line))
			throw std::runtime_error("missing duration");
		std::istringstream header(line);
		if (!(header >> duration) || header >> extra || duration < 10'000'000 || duration > 1'800'000'000)
			throw std::runtime_error("invalid encoded plan duration");
		while (std::getline(in, line))
		{
			path_event e{};
			std::istringstream row(line);
			if (!(row >> e.start >> e.loss_end >> e.end) || row >> extra ||
			    e.start < 15'000'000 || e.start > e.loss_end || e.loss_end > e.end ||
			    e.end - e.start > 200'000 || e.end > duration ||
			    (!events.empty() && e.start <= events.back().end) || events.size() >= 512)
				throw std::runtime_error("invalid encoded path event");
			events.push_back(e);
		}
		if (!in.eof() || events.empty())
			throw std::runtime_error("empty/truncated encoded path plan");
	}
	// Returns drop and FIFO-ready offset. The shared FIFO includes both eyes and RTX.
	std::pair<bool, long long> decide(long long generated, long long & free_at) const
	{
		long long ready = generated;
		for (auto e: events)
		{
			if (generated < e.start)
				break;
			if (generated < e.end)
			{
				if (generated < e.loss_end)
					return {true, -1};
				ready = e.end;
				break;
			}
		}
		ready = std::max(ready, free_at);
		free_at = ready + 14; // Existing measured-model drain prior, explicitly assumed.
		return {false, ready};
	}
};

class encoded_path
{
	using clock = std::chrono::steady_clock;
	struct item
	{
		clock::time_point at;
		size_t bytes;
		std::function<void()> send;
	};
	encoded_plan plan;
	std::mutex mutex;
	std::condition_variable cv;
	std::deque<item> pending;
	size_t queued_bytes = 0, peak_packets = 0, peak_bytes = 0;
	unsigned long long dropped[2]{}, delayed[2]{}, sent = 0, failed = 0, canceled = 0;
	long long free_at = 0, late_max_us = 0;
	clock::time_point origin{};
	bool closed = false;
	std::thread worker;

	void run()
	{
		std::unique_lock lock(mutex);
		for (;;)
		{
			if (closed)
				return;
			if (pending.empty())
			{
				cv.wait(lock);
				continue;
			}
			if (clock::now() < pending.front().at)
			{
				cv.wait_until(lock, pending.front().at);
				continue;
			}
			auto next = std::move(pending.front());
			pending.pop_front();
			queued_bytes -= next.bytes;
			auto late = std::chrono::duration_cast<std::chrono::microseconds>(clock::now() - next.at).count();
			late_max_us = std::max<long long>(late_max_us, late);
			lock.unlock();
			bool ok = true;
			try
			{
				next.send();
			}
			catch (...)
			{
				ok = false;
			}
			lock.lock();
			if (ok)
				++sent;
			else
				++failed;
			cv.notify_all();
		}
	}

public:
	explicit encoded_path(const std::string & path) : plan(path), worker([this] { run(); })
	{
		std::fprintf(stderr, "HELIX_PATH_ARM duration_us=%lld events=%zu max_packets=4096 max_bytes=8388608\n", plan.duration, plan.events.size());
	}
	encoded_path(const encoded_path &) = delete;
	~encoded_path()
	{
		close();
	}

	template <typename Packet, typename Sender>
	void push(Packet packet, Sender sender)
	{
		std::unique_lock lock(mutex);
		if (closed || failed)
			throw std::runtime_error("encoded path closed/failed");
		if (packet.stream_item_idx > 1)
			throw std::runtime_error("unexpected encoded stream");
		if (origin == clock::time_point{})
			origin = clock::now();
		auto generated = std::chrono::duration_cast<std::chrono::microseconds>(clock::now() - origin).count();
		auto [drop, ready] = plan.decide(generated, free_at);
		if (drop)
		{
			++dropped[packet.stream_item_idx];
			std::fprintf(stderr, "HELIX_PATH_DROP stream=%u frame=%llu packet_sequence=%llu rtx=%d at_us=%lld\n", unsigned(packet.stream_item_idx), (unsigned long long)packet.frame_idx, (unsigned long long)packet.packet_sequence, packet.retransmission, (long long)generated);
			return;
		}
		if (ready > generated)
			++delayed[packet.stream_item_idx];
		if (pending.size() >= 4096 || queued_bytes + packet.payload.size() > 8 * 1024 * 1024)
		{
			++failed;
			throw std::runtime_error("encoded path queue capacity exceeded");
		}
		std::vector<unsigned char> payload(packet.payload.begin(), packet.payload.end());
		queued_bytes += payload.size();
		auto send = [packet, payload = std::move(payload), sender]() mutable {
			packet.payload = payload;
			sender(packet);
			if (packet.retransmission)
			{
				std::fprintf(stderr, "HELIX_HEVC10_RTX_SENT stream=%u frame=%llu packet_sequence=%llu actual_send=1\n", unsigned(packet.stream_item_idx), (unsigned long long)packet.frame_idx, (unsigned long long)packet.packet_sequence);
				std::fprintf(stderr, "HELIX_PATH_RTX_DELIVERED stream=%u frame=%llu packet_sequence=%llu\n", unsigned(packet.stream_item_idx), (unsigned long long)packet.frame_idx, (unsigned long long)packet.packet_sequence);
			}
		};
		pending.push_back({origin + std::chrono::microseconds(ready), packet.payload.size(), std::move(send)});
		peak_packets = std::max(peak_packets, pending.size());
		peak_bytes = std::max(peak_bytes, queued_bytes);
		cv.notify_all();
	}

	// Close only after producers stop. Teardown does not silently discard evidence.
	void close()
	{
		std::unique_lock lock(mutex);
		if (closed)
			return;
		cv.wait_for(lock, std::chrono::seconds(1), [this] { return pending.empty(); });
		canceled += pending.size();
		pending.clear();
		closed = true;
		cv.notify_all();
		lock.unlock();
		if (worker.joinable())
			worker.join();
		std::fprintf(stderr, "HELIX_PATH_SUMMARY sent=%llu dropped0=%llu dropped1=%llu delayed0=%llu delayed1=%llu failed=%llu canceled=%llu peak_packets=%zu peak_bytes=%zu late_max_us=%lld\n", sent, dropped[0], dropped[1], delayed[0], delayed[1], failed, canceled, peak_packets, peak_bytes, late_max_us);
	}
};
} // namespace wivrn::helix
