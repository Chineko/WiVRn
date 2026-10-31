#!/usr/bin/env python3
from pathlib import Path

ROOT = Path('.')
SERVER = ROOT / 'server/helix_synthetic_transport.cpp'
GEN = ROOT / 'tools/helix-vrchat-workload-model.py'
DOC = ROOT / 'docs/helix/2026-10-31-vrchat-realistic-torture.md'
for p in (SERVER, GEN, DOC, ROOT/'server/helix_vrchat_trace.h', ROOT/'tools/helix-vrchat-trace-check.cpp'):
    if not p.is_file():
        raise SystemExit(f'FAIL: missing post-patch file {p}')

def one(s, old, new, label):
    n = s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} count={n}')
    return s.replace(old, new, 1)

# Generator: keep measured middle-shard payloads, but reserve deterministic headroom on
# first/last shards for serialized view/timing metadata. Preserve frame bytes by adding a
# shard when needed rather than silently shrinking the frame.
g = GEN.read_text()
g = one(g,
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
''', 'generator packetisation block')
g = one(g,
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
''', 'generator shard payload block')
g = one(g, '    means, maxes, smax = [], [], []\n', '    means, maxes, smax, gaps = [], [], [], []\n', 'calibration accumulators')
g = one(g,
'                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4]))\n',
'                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4])); gaps.append(int(m[5]))\n',
'calibration parse')
g = one(g,
'''    cal["shards_max"] = max(smax)
    return cal
''',
'''    cal["shards_max"] = max(smax)
    gap_mean_us = sum(gaps) / len(gaps)
    if gap_mean_us <= 0:
        raise SystemExit("invalid measured inter-frame gap")
    cal["fps"] = 1_000_000.0 / gap_mean_us
    return cal
''', 'calibration cadence')
GEN.write_text(g)

# Server: all replay-specific replacements are scoped strictly to run_trace().
s = SERVER.read_text()
s = one(s, '#include <map>\n', '#include <map>\n#include <limits>\n', 'limits include')
anchor = '// ---------------------------------------------------------------------------------------\n// Sustained VRChat-like trace replay (HELIX_SYNTHETIC_TRACE=<file>).\n'
trace_view = '''to_headset::video_stream_data_shard::view_info_t make_trace_view_info()
{
\tauto view = make_view_info();
\t// Test-only RTX eligibility sentinel. Ordinary synthetic cases intentionally use
\t// display_time=0; this representative lane must exercise live retransmission.
\tview.display_time = std::numeric_limits<decltype(view.display_time)>::max() / 4;
\treturn view;
}

'''
s = one(s, anchor, trace_view + anchor, 'trace view-info insertion')
start = s.find('int run_trace(')
end = s.find('\n} // namespace', start)
if start < 0 or end < 0:
    raise SystemExit('FAIL: run_trace region not found')
pre, t, post = s[:start], s[start:end], s[end:]
t = one(t,
'// its own oracle: a frame is expected complete iff none of its rows is path-dropped.\n',
'// clean frames must complete; damaged frames count recovered only after actual RTX.\n',
'oracle comment')
t = one(t, 'constexpr double trace_false_incomplete_budget = 0.005; // provisional: 0.5% of frames\n', '', 'remove arbitrary budget')
t = one(t, 'packet.view_info = make_view_info();', 'packet.view_info = make_trace_view_info();', 'trace original view info')
t = one(t, 'uint64_t sent = 0, path_dropped = 0, clamped_bytes = 0;', 'uint64_t sent = 0, path_dropped = 0;', 'remove clamp counter')
t = one(t,
'\tstd::array<uint64_t, 2> sequence{};\n\tstd::vector<int64_t> lateness_us;\n',
'''\tstd::array<uint64_t, 2> sequence{};
\tstd::map<std::pair<uint8_t, uint64_t>, helix_vrchat_trace::row> dropped_packets;
\tstd::map<std::pair<uint8_t, uint64_t>, uint64_t> dropped_by_frame;
\tstd::map<std::pair<uint8_t, uint64_t>, uint64_t> retransmitted_by_frame;
\tstd::set<std::pair<uint8_t, uint64_t>> retransmitted_sequences;
\tsize_t rtx_cursor = 0;
\tuint64_t rtx_retransmissions = 0;
\tauto process_rtx = [&]() {
\t\twhile (rtx_cursor < obs.rtx.size())
\t\t{
\t\t\tconst auto & request = obs.rtx[rtx_cursor++];
\t\t\tconst auto key = std::pair<uint8_t, uint64_t>{request.stream_index, request.packet_sequence};
\t\t\tauto it = dropped_packets.find(key);
\t\t\tif (it == dropped_packets.end() || !retransmitted_sequences.insert(key).second)
\t\t\t\tcontinue;
\t\t\tconst auto & rr = it->second;
\t\t\tto_headset::video_stream_data_shard packet{};
\t\t\tpacket.stream_item_idx = rr.stream;
\t\t\tpacket.frame_idx = rr.frame;
\t\t\tpacket.packet_sequence = request.packet_sequence;
\t\t\tpacket.retransmission = true;
\t\t\tpacket.shard_idx = rr.shard;
\t\t\tif (rr.shard == 0) packet.view_info = make_trace_view_info();
\t\t\tif (rr.shard == rr.shards - 1) packet.timing_info = to_headset::video_stream_data_shard::timing_info_t{};
\t\t\tconst size_t overhead = serialized_size(packet.view_info) + serialized_size(packet.timing_info);
\t\t\tconst size_t limit = to_headset::video_stream_data_shard::max_payload_size > overhead
\t\t\t                             ? to_headset::video_stream_data_shard::max_payload_size - overhead : 0;
\t\t\tif (rr.bytes > limit) throw std::runtime_error("trace retransmission payload would clamp");
\t\t\tpacket.payload = std::span<uint8_t>{filler.data(), rr.bytes};
\t\t\tconnection.send_stream(std::move(packet));
\t\t\t++rtx_retransmissions;
\t\t\t++retransmitted_by_frame[{rr.stream, rr.frame}];
\t\t}
\t};
\tstd::vector<int64_t> lateness_us;
''', 'RTX state insertion')
t = one(t,
'''\t\tif (row.drop)
\t\t{
\t\t\t++path_dropped;
\t\t\tcontinue;
\t\t}
''',
'''\t\tif (row.drop)
\t\t{
\t\t\t++path_dropped;
\t\t\tdropped_packets[{row.stream, seq}] = row;
\t\t\t++dropped_by_frame[{row.stream, row.frame}];
\t\t\tcontinue;
\t\t}
''', 'drop cache')
t = one(t, '\t\t\t\tconnection.poll(absorb, 0);\n', '\t\t\t\tconnection.poll(absorb, 0);\n\t\t\t\tprocess_rtx();\n', 'wait-loop RTX service')
t = one(t,
'''\t\tconst size_t length = std::min<size_t>(row.bytes, limit);
\t\tclamped_bytes += row.bytes - length;
\t\tpacket.payload = std::span<uint8_t>{filler.data(), length};
''',
'''\t\tif (row.bytes > limit)
\t\t{
\t\t\tU_LOG_E("HELIX_VRCHAT_TRACE_INVALID payload_would_clamp stream=%u frame=%llu shard=%u bytes=%u limit=%zu",
\t\t\t        row.stream, static_cast<unsigned long long>(row.frame), row.shard, row.bytes, limit);
\t\t\treturn 2;
\t\t}
\t\tpacket.payload = std::span<uint8_t>{filler.data(), row.bytes};
''', 'reject payload clamp')
t = one(t,
'\tcollect(connection, obs, std::chrono::duration_cast<std::chrono::milliseconds>(trace_drain_time));\n',
'''\t{
\t\tconst auto deadline = clock::now() + trace_drain_time;
\t\twhile (clock::now() < deadline)
\t\t{
\t\t\tconnection.poll(absorb, 10);
\t\t\tprocess_rtx();
\t\t}
\t}
''', 'RTX-aware drain')
old_start = t.find('\tuint64_t frames_total = 0, ok_complete = 0, ok_incomplete = 0, false_complete = 0, false_incomplete = 0;')
old_end_marker = '\treturn pass ? 0 : 1;\n'
old_end = t.find(old_end_marker, old_start)
if old_start < 0 or old_end < 0:
    raise SystemExit('FAIL: old result block not found')
old_end += len(old_end_marker)
new_result = '''\tuint64_t frames_total = 0, clean_complete = 0, clean_failed = 0;
\tuint64_t damaged_recovered = 0, damaged_unrecovered = 0, false_complete = 0;
\tstd::vector<double> assembly_ms;
\tfor (const auto & [key, info]: tr.frames)
\t{
\t\t++frames_total;
\t\tconst auto it = obs.feedback.find(key);
\t\tconst bool complete = it != obs.feedback.end() && it->second.sent_to_decoder != 0;
\t\tif (!info.has_drop)
\t\t{
\t\t\tif (complete) ++clean_complete; else ++clean_failed;
\t\t}
\t\telse
\t\t{
\t\t\tconst uint64_t dropped = dropped_by_frame[key];
\t\t\tconst uint64_t resent = retransmitted_by_frame[key];
\t\t\tif (complete && resent == dropped && dropped != 0) ++damaged_recovered;
\t\t\telse if (complete) ++false_complete;
\t\t\telse ++damaged_unrecovered;
\t\t}
\t\tif (complete && it->second.received_first_packet != 0 && it->second.received_last_packet >= it->second.received_first_packet)
\t\t\tassembly_ms.push_back(double(it->second.received_last_packet - it->second.received_first_packet) / 1e6);
\t}
\tauto percentile = [](std::vector<double> v, double q) {
\t\tif (v.empty()) return 0.0;
\t\tstd::sort(v.begin(), v.end());
\t\treturn v[std::min(v.size() - 1, size_t(q * double(v.size())))];
\t};
\tstd::vector<double> late_ms;
\tlate_ms.reserve(lateness_us.size());
\tfor (auto l: lateness_us) late_ms.push_back(double(l) / 1e3);
\tconst bool pass = clean_failed == 0 && false_complete == 0 && !obs.rtx.empty() &&
\t                  rtx_retransmissions != 0 && damaged_recovered != 0;
\tU_LOG_I("HELIX_VRCHAT_TRACE_RESULT pass=%d phase=characterization frames=%llu sent=%llu path_dropped=%llu "
\t        "clean_complete=%llu clean_failed=%llu damaged_recovered=%llu damaged_unrecovered=%llu false_complete=%llu "
\t        "gap_reports=%zu rtx_requests=%zu rtx_retransmissions=%llu "
\t        "assembly_ms(p50/p99/max)=%.3f/%.3f/%.3f send_lateness_ms(p50/p99/max)=%.3f/%.3f/%.3f",
\t        pass, static_cast<unsigned long long>(frames_total), static_cast<unsigned long long>(sent),
\t        static_cast<unsigned long long>(path_dropped), static_cast<unsigned long long>(clean_complete),
\t        static_cast<unsigned long long>(clean_failed), static_cast<unsigned long long>(damaged_recovered),
\t        static_cast<unsigned long long>(damaged_unrecovered), static_cast<unsigned long long>(false_complete),
\t        obs.gaps.size(), obs.rtx.size(), static_cast<unsigned long long>(rtx_retransmissions),
\t        percentile(assembly_ms, 0.5), percentile(assembly_ms, 0.99), percentile(assembly_ms, 1.0),
\t        percentile(late_ms, 0.5), percentile(late_ms, 0.99), percentile(late_ms, 1.0));
\treturn pass ? 0 : 1;
'''
t = t[:old_start] + new_result + t[old_end:]
SERVER.write_text(pre + t + post)

# Documentation: first runs are characterization; promotion threshold is intentionally not frozen yet.
d = DOC.read_text()
old_doc = '''Result line: `HELIX_VRCHAT_TRACE_RESULT`. `false_complete` must be 0. `false_incomplete` plus
`silent_expected_complete` must stay under 0.5% of frames; that budget is my provisional
number, not a measured one.'''
new_doc = '''Result line: `HELIX_VRCHAT_TRACE_RESULT`. This lane starts as characterization, not promotion.
Clean frames are strict: `clean_failed` must be 0. A damaged frame counts recovered only when
all modeled drops for that frame were retransmitted. `false_complete` must be 0, and the run
must exercise RTX and recover at least one damaged frame. No damaged-frame recovery percentage
is frozen until repeated characterization runs are collected.'''
d = one(d, old_doc, new_doc, 'documentation oracle')
d += '''\n\n## Representative-lane repair notes\n\nThe repaired lane intentionally differs from the original patch: trace replay enables RTX,\nserves actual Quest retransmission requests from a dropped-packet cache, forbids payload\nclamping, reserves first/last-shard metadata headroom, and relies on an external SHA-256\nseal/audit for exact trace identity. It is separate from the frozen live8/burst8 lane.\n'''
DOC.write_text(d)

print('PASS: representative trace repair v2 applied')
print('STATUS: source transformed only; build/runtime not executed')
