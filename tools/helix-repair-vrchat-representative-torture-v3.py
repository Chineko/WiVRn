#!/usr/bin/env python3
from pathlib import Path
import argparse
import json
import sys

ROOT = Path('.')
SERVER = ROOT / 'server/helix_synthetic_transport.cpp'
GEN = ROOT / 'tools/helix-vrchat-workload-model.py'
DOC = ROOT / 'docs/helix/2026-10-31-vrchat-realistic-torture.md'
CHECK = ROOT / 'tools/helix-vrchat-trace-check.cpp'
HEADER = ROOT / 'server/helix_vrchat_trace.h'

FILES = (SERVER, GEN, DOC, CHECK, HEADER)


def fail(msg):
    raise SystemExit(f'FAIL: {msg}')


def one(text, old, new, label):
    n = text.count(old)
    if n != 1:
        fail(f'{label} count={n}')
    return text.replace(old, new, 1)


def transform_generator(text):
    text = one(
        text,
        '''            nshards = -(-nbytes // cal["shard_payload"])
            nshards = min(nshards, cal["shards_max"])
            nbytes = min(nbytes, nshards * cal["shard_payload"])
''',
        '''            edge_payload = min(1200, cal["shard_payload"])
            nshards = -(-nbytes // cal["shard_payload"])
            nshards = min(nshards, cal["shards_max"])
            def capacity(n):
                if n == 1:
                    return edge_payload
                return (n - 2) * cal["shard_payload"] + 2 * edge_payload
            while nshards < cal["shards_max"] and nbytes > capacity(nshards):
                nshards += 1
            nbytes = min(nbytes, capacity(nshards))
''',
        'generator packetisation block')
    text = one(
        text,
        '''            rem = nbytes
            for sh in range(nshards):
                pb = min(cal["shard_payload"], rem)
                rem -= pb
                packets.append((int(t0 + sh * spacing), s, f, sh, nshards, pb))
''',
        '''            rem = nbytes
            for sh in range(nshards):
                cap_shard = edge_payload if sh == 0 or sh == nshards - 1 else cal["shard_payload"]
                pb = min(cap_shard, rem)
                rem -= pb
                packets.append((int(t0 + sh * spacing), s, f, sh, nshards, pb))
            assert rem == 0
''',
        'generator shard payload block')
    text = one(
        text,
        '''        rows.append((tg, ts, s, f, sh, ns, pb))
    return {
        "rows": rows, "events": events, "stall_spans": stall_spans, "frame_meta": frame_meta,
        "drop_frames": drop_frames, "max_delay_us": max_delay, "seed": seed,
''',
        '''        rows.append((tg, ts, s, f, sh, ns, pb))

    # Explicit transport-recovery canaries: one single shard-0 omission per eye.
    # This uses the already-proven WiVRn RTX condition where view_info has not arrived yet,
    # so no synthetic/future headset display clock is required.
    rtx_canary_frames = {}
    rows = list(rows)
    for wanted_stream in (0, 1):
        for i, row in enumerate(rows):
            tg, ts, s, f, sh, ns, pb = row
            if s == wanted_stream and sh == 0 and ts is not None and (s, f) not in drop_frames and tg >= 1_000_000:
                rows[i] = (tg, None, s, f, sh, ns, pb)
                drop_frames.add((s, f))
                rtx_canary_frames[s] = f
                break
    if len(rtx_canary_frames) != 2:
        raise RuntimeError("failed to place both RTX canaries")
    return {
        "rows": rows, "events": events, "stall_spans": stall_spans, "frame_meta": frame_meta,
        "drop_frames": drop_frames, "rtx_canary_frames": rtx_canary_frames, "max_delay_us": max_delay, "seed": seed,
''',
        'generator RTX canary insertion')
    text = one(
        text,
        '''    out["frames_expected_incomplete"] = len(tr["drop_frames"])
''',
        '''    out["frames_expected_incomplete"] = len(tr["drop_frames"])
    out["rtx_canary_frames"] = {str(k): v for k, v in tr.get("rtx_canary_frames", {}).items()}
''',
        'generator canary stats')
    text = one(text, '    means, maxes, smax = [], [], []\n', '    means, maxes, smax, gaps = [], [], [], []\n', 'calibration accumulators')
    text = one(
        text,
        '                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4]))\n',
        '                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4])); gaps.append(int(m[5]))\n',
        'calibration parse')
    text = one(
        text,
        '''    cal["shards_max"] = max(smax)
    return cal
''',
        '''    cal["shards_max"] = max(smax)
    gap_mean_us = sum(gaps) / len(gaps)
    if gap_mean_us <= 0:
        raise SystemExit("invalid measured inter-frame gap")
    cal["fps"] = 1_000_000.0 / gap_mean_us
    return cal
''',
        'calibration cadence')
    return text


TRACE_START = '// ---------------------------------------------------------------------------------------\n// Sustained VRChat-like trace replay (HELIX_SYNTHETIC_TRACE=<file>).\n'
TRACE_END = '\n} // namespace\n\nint run(wivrn_connection & connection, std::stop_token stop_token)'

TRACE_BLOCK = r'''// ---------------------------------------------------------------------------------------
// Sustained VRChat-like trace replay (HELIX_SYNTHETIC_TRACE=<file>).
//
// The representative path model remains characterization data. Two deterministic single-
// shard-0 omissions (one per eye) are added as RTX canaries. Shard 0 carries view_info;
// withholding it exercises the same already-proven RTX condition as run_rtx_rescue_case
// without inventing a headset display-time clock. A damaged frame counts as recovered only
// after every modeled omitted sequence for that frame was actually retransmitted.
// ---------------------------------------------------------------------------------------
constexpr size_t trace_max_frame_bytes = frame_bytes;
constexpr auto trace_start_delay = 500ms;
constexpr auto trace_drain_time = 1500ms;

int run_trace(wivrn_connection & connection, std::stop_token stop_token, const char * path)
{
	using clock = std::chrono::steady_clock;

	const helix_vrchat_trace::limits limits{
	        .max_frame_bytes = trace_max_frame_bytes,
	        .max_shard_payload = to_headset::video_stream_data_shard::max_payload_size,
	        .max_shards = 64,
	        .max_rows = 6'000'000,
	        .max_duration_us = 1'800'000'000,
	};
	helix_vrchat_trace::trace tr;
	std::string error;
	if (!helix_vrchat_trace::load(path, limits, tr, error))
	{
		U_LOG_E("HELIX_VRCHAT_TRACE_INVALID path=%s error=%s", path, error.c_str());
		return 2;
	}
	U_LOG_I("HELIX_VRCHAT_TRACE_LOADED path=%s rows=%zu frames=%zu", path, tr.rows.size(), tr.frames.size());

	connection.send_control(to_headset::video_stream_description{
	        .width = width,
	        .height = height,
	        .codec = {video_codec::raw, video_codec::raw, video_codec::raw},
	        .frame_rate = 90.0f,
	        .refresh_rate = 90.0f,
	});
	std::this_thread::sleep_for(setup_delay);

	observation obs;
	auto absorb = [&obs](auto && packet) {
		using T = std::remove_cvref_t<decltype(packet)>;
		if constexpr (std::is_same_v<T, from_headset::feedback>)
			obs.feedback[{packet.stream_index, packet.frame_index}] = packet;
		else if constexpr (std::is_same_v<T, from_headset::video_gap_report>)
			obs.gaps.push_back(packet);
		else if constexpr (std::is_same_v<T, from_headset::video_retransmission_request>)
			obs.rtx.push_back(packet);
	};

	std::array<uint8_t, to_headset::video_stream_data_shard::max_payload_size> filler{};
	for (size_t i = 0; i < filler.size(); ++i)
		filler[i] = uint8_t(i * 31 + 7);

	std::array<uint64_t, 2> sequence{};
	std::map<std::pair<uint8_t, uint64_t>, helix_vrchat_trace::row> dropped_packets;
	std::map<std::pair<uint8_t, uint64_t>, uint64_t> dropped_by_frame;
	std::map<std::pair<uint8_t, uint64_t>, uint64_t> retransmitted_by_frame;
	std::set<std::pair<uint8_t, uint64_t>> dropped_shard0_frames;
	std::set<std::pair<uint8_t, uint64_t>> retransmitted_sequences;
	uint64_t rtx_retransmissions = 0;
	size_t rtx_cursor = 0;

	auto transmit = [&](const helix_vrchat_trace::row & row, uint64_t seq, bool retransmission) {
		to_headset::video_stream_data_shard packet{};
		packet.stream_item_idx = row.stream;
		packet.frame_idx = row.frame;
		packet.packet_sequence = seq;
		packet.retransmission = retransmission;
		packet.shard_idx = row.shard;
		if (row.shard == 0)
			packet.view_info = make_view_info();
		if (row.shard == row.shards - 1)
			packet.timing_info = to_headset::video_stream_data_shard::timing_info_t{};
		const size_t overhead = serialized_size(packet.view_info) + serialized_size(packet.timing_info);
		const size_t limit = to_headset::video_stream_data_shard::max_payload_size > overhead
		                             ? to_headset::video_stream_data_shard::max_payload_size - overhead
		                             : 0;
		if (row.bytes > limit)
		{
			U_LOG_E("HELIX_VRCHAT_TRACE_INVALID payload_would_clamp stream=%u frame=%llu shard=%u bytes=%u limit=%zu retransmission=%d",
			        row.stream, static_cast<unsigned long long>(row.frame), row.shard, row.bytes, limit, retransmission);
			return false;
		}
		packet.payload = std::span<uint8_t>{filler.data(), row.bytes};
		connection.send_stream(std::move(packet));
		return true;
	};

	auto process_rtx = [&]() {
		while (rtx_cursor < obs.rtx.size())
		{
			const auto & request = obs.rtx[rtx_cursor++];
			const auto seq_key = std::pair<uint8_t, uint64_t>{request.stream_index, request.packet_sequence};
			auto it = dropped_packets.find(seq_key);
			if (it == dropped_packets.end() || !retransmitted_sequences.insert(seq_key).second)
				continue;
			const auto & row = it->second;
			if (!transmit(row, request.packet_sequence, true))
				return false;
			++rtx_retransmissions;
			++retransmitted_by_frame[{row.stream, row.frame}];
		}
		return true;
	};

	std::vector<int64_t> lateness_us;
	lateness_us.reserve(tr.rows.size());
	struct send_record
	{
		uint8_t stream;
		uint64_t frame;
		uint16_t shard;
		uint64_t sequence;
		int64_t nominal_us;
		int64_t actual_us;
	};
	std::vector<send_record> send_log;
	const char * send_log_path = std::getenv("HELIX_SYNTHETIC_TRACE_SEND_LOG");
	if (send_log_path && *send_log_path)
		send_log.reserve(tr.rows.size());

	uint64_t sent = 0, path_dropped = 0;
	const auto t0 = clock::now() + trace_start_delay;
	for (const auto & row: tr.rows)
	{
		if (stop_token.stop_requested())
		{
			U_LOG_W("HELIX_VRCHAT_TRACE_CANCELLED sent=%llu", static_cast<unsigned long long>(sent));
			return 3;
		}

		const uint64_t seq = ++sequence[row.stream];
		if (row.drop)
		{
			++path_dropped;
			dropped_packets[{row.stream, seq}] = row;
			++dropped_by_frame[{row.stream, row.frame}];
			if (row.shard == 0)
				dropped_shard0_frames.insert({row.stream, row.frame});
			continue;
		}

		const auto target = t0 + std::chrono::microseconds(row.t_send_us);
		for (;;)
		{
			const auto now = clock::now();
			if (now >= target)
				break;
			const auto left = target - now;
			if (left > 300us)
			{
				connection.poll(absorb, 0);
				if (!process_rtx())
					return 2;
				std::this_thread::sleep_for(left > 1500us ? 500us : 100us);
			}
		}

		if (!transmit(row, seq, false))
			return 2;
		connection.poll(absorb, 0);
		if (!process_rtx())
			return 2;

		const int64_t actual_us = std::chrono::duration_cast<std::chrono::microseconds>(clock::now() - t0).count();
		lateness_us.push_back(actual_us - row.t_send_us);
		if (!send_log.empty() || (send_log_path && *send_log_path))
			send_log.push_back({row.stream, row.frame, row.shard, seq, row.t_send_us, actual_us});
		++sent;
	}

	{
		const auto deadline = clock::now() + trace_drain_time;
		while (clock::now() < deadline)
		{
			connection.poll(absorb, 10);
			if (!process_rtx())
				return 2;
		}
	}

	if (send_log_path && *send_log_path)
	{
		if (FILE * out = std::fopen(send_log_path, "w"))
		{
			std::fprintf(out, "stream,frame,shard,sequence,nominal_us,actual_us\n");
			for (const auto & r: send_log)
				std::fprintf(out, "%u,%llu,%u,%llu,%lld,%lld\n", r.stream, static_cast<unsigned long long>(r.frame), r.shard,
				             static_cast<unsigned long long>(r.sequence), static_cast<long long>(r.nominal_us),
				             static_cast<long long>(r.actual_us));
			std::fclose(out);
		}
		else
			U_LOG_W("HELIX_VRCHAT_TRACE_SEND_LOG_OPEN_FAILED path=%s", send_log_path);
	}

	uint64_t frames_total = 0, clean_complete = 0, clean_failed = 0;
	uint64_t damaged_recovered = 0, damaged_unrecovered = 0, false_complete = 0;
	uint64_t rtx_canary_candidates = 0, rtx_canary_recovered = 0;
	std::vector<double> assembly_ms;
	for (const auto & [key, info]: tr.frames)
	{
		++frames_total;
		const auto it = obs.feedback.find(key);
		const bool complete = it != obs.feedback.end() && it->second.sent_to_decoder != 0;
		if (!info.has_drop)
		{
			if (complete)
				++clean_complete;
			else
				++clean_failed;
		}
		else
		{
			const uint64_t dropped = dropped_by_frame[key];
			const uint64_t resent = retransmitted_by_frame[key];
			const bool canary = dropped == 1 && dropped_shard0_frames.contains(key);
			if (canary)
				++rtx_canary_candidates;
			if (complete && dropped != 0 && resent == dropped)
			{
				++damaged_recovered;
				if (canary)
					++rtx_canary_recovered;
			}
			else if (complete)
				++false_complete;
			else
				++damaged_unrecovered;
		}
		if (complete && it != obs.feedback.end() && it->second.received_first_packet != 0 &&
		    it->second.received_last_packet >= it->second.received_first_packet)
			assembly_ms.push_back(double(it->second.received_last_packet - it->second.received_first_packet) / 1e6);
	}

	auto percentile = [](std::vector<double> v, double q) {
		if (v.empty())
			return 0.0;
		std::sort(v.begin(), v.end());
		return v[std::min(v.size() - 1, size_t(q * double(v.size())))];
	};
	std::vector<double> late_ms;
	late_ms.reserve(lateness_us.size());
	for (auto l: lateness_us)
		late_ms.push_back(double(l) / 1e3);

	// Characterization gate only: no post-hoc damaged-frame recovery percentage.
	// The two single-shard-0 canaries must recover, clean frames must stay complete,
	// and no damaged frame may complete without all modeled omitted sequences resent.
	const bool pass = clean_failed == 0 && false_complete == 0 && rtx_canary_candidates == 2 &&
	                  rtx_canary_recovered == 2 && rtx_retransmissions >= 2 && !obs.rtx.empty();

	U_LOG_I("HELIX_VRCHAT_TRACE_RESULT pass=%d phase=characterization frames=%llu sent=%llu path_dropped=%llu "
	        "clean_complete=%llu clean_failed=%llu damaged_recovered=%llu damaged_unrecovered=%llu false_complete=%llu "
	        "rtx_canary_candidates=%llu rtx_canary_recovered=%llu gap_reports=%zu rtx_requests=%zu rtx_retransmissions=%llu "
	        "assembly_ms(p50/p99/max)=%.3f/%.3f/%.3f send_lateness_ms(p50/p99/max)=%.3f/%.3f/%.3f",
	        pass, static_cast<unsigned long long>(frames_total), static_cast<unsigned long long>(sent),
	        static_cast<unsigned long long>(path_dropped), static_cast<unsigned long long>(clean_complete),
	        static_cast<unsigned long long>(clean_failed), static_cast<unsigned long long>(damaged_recovered),
	        static_cast<unsigned long long>(damaged_unrecovered), static_cast<unsigned long long>(false_complete),
	        static_cast<unsigned long long>(rtx_canary_candidates), static_cast<unsigned long long>(rtx_canary_recovered),
	        obs.gaps.size(), obs.rtx.size(), static_cast<unsigned long long>(rtx_retransmissions),
	        percentile(assembly_ms, 0.5), percentile(assembly_ms, 0.99), percentile(assembly_ms, 1.0),
	        percentile(late_ms, 0.5), percentile(late_ms, 0.99), percentile(late_ms, 1.0));
	return pass ? 0 : 1;
}
'''


def transform_server(text):
    if text.count(TRACE_START) != 1:
        fail(f'trace block start count={text.count(TRACE_START)}')
    if text.count(TRACE_END) != 1:
        fail(f'trace block end count={text.count(TRACE_END)}')
    start = text.index(TRACE_START)
    end = text.index(TRACE_END, start)
    new_text = text[:start] + TRACE_BLOCK + text[end:]
    if 'trace_false_incomplete_budget' in new_text:
        fail('stale 0.5% budget remains')
    if 'clamped_bytes' in new_text:
        fail('stale clamped-byte accounting remains')
    for needle in (
        'rtx_canary_candidates == 2',
        'rtx_canary_recovered == 2',
        'packet.retransmission = retransmission;',
        'payload_would_clamp',
        'dropped_packets[{row.stream, seq}] = row;',
        'connection.poll(absorb, 0);',
    ):
        if needle not in new_text:
            fail(f'server invariant missing: {needle}')
    return new_text


def transform_doc(text):
    text = one(
        text,
        '''Result line: `HELIX_VRCHAT_TRACE_RESULT`. `false_complete` must be 0. `false_incomplete` plus
`silent_expected_complete` must stay under 0.5% of frames; that budget is my provisional
number, not a measured one.''',
        '''Result line: `HELIX_VRCHAT_TRACE_RESULT`. This first lane is characterization, not a
post-hoc percentage promotion gate. Clean frames must remain complete, a damaged frame may only
complete after all modeled omitted sequences were retransmitted, and two deterministic single-
shard-0 RTX canaries (one per eye) must both recover. Representative damaged-frame recovery is
reported, not thresholded.''',
        'documentation result contract')
    text = text.replace('whether the 0.5% budget is sensible.', 'the representative damaged-frame recovery distribution before any promotion threshold is frozen.')
    return text


def validate_transformed(texts):
    s = texts[SERVER]
    g = texts[GEN]
    d = texts[DOC]
    if s.count('int run_trace(') != 1:
        fail(f'run_trace count={s.count("int run_trace(")}')
    if g.count('rtx_canary_frames = {}') != 1:
        fail('generator canary block count mismatch')
    if g.count('edge_payload = min(1200, cal["shard_payload"])') != 1:
        fail('generator edge headroom count mismatch')
    if '0.5% of frames' in d:
        fail('stale 0.5% result contract remains in docs')
    # Bind the stand-alone checker hard-code to the protocol source rather than silently drifting.
    checker = texts[CHECK]
    if '.max_shard_payload = 1400,' not in checker:
        fail('checker max payload is not the audited 1400 value')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check-only', action='store_true', help='validate all transforms and invariants without writing')
    args = ap.parse_args()

    for p in FILES:
        if not p.is_file():
            fail(f'missing post-patch file {p}')

    original = {p: p.read_text() for p in FILES}
    transformed = dict(original)

    # Transactional: no file is written until every transform and validation below succeeds.
    transformed[GEN] = transform_generator(original[GEN])
    transformed[SERVER] = transform_server(original[SERVER])
    transformed[DOC] = transform_doc(original[DOC])
    validate_transformed(transformed)

    if args.check_only:
        print('PASS: representative trace repair v3 check-only')
        print('writes=0')
        print('contract=transactional-shard0-rtx-canary-both-eyes-zero-clamp-characterization')
        return 0

    for p in FILES:
        if transformed[p] != original[p]:
            tmp = p.with_name(p.name + '.helix-v3.tmp')
            tmp.write_text(transformed[p])
            tmp.replace(p)

    print('PASS: representative trace repair v3 applied')
    print('contract=transactional-shard0-rtx-canary-both-eyes-zero-clamp-characterization')
    print('STATUS: source transformed only; build/runtime not executed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
