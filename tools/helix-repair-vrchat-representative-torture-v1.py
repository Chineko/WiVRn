#!/usr/bin/env python3
from pathlib import Path
import sys

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

# --- generator: preserve measured middle-shard size but reserve first/last headroom.
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
# Make calibration actually re-pin cadence from measured inter-frame gap.
g = one(g,
'''    means, maxes, smax = [], [], []
''',
'''    means, maxes, smax, gaps = [], [], [], []
''', 'calibration accumulators')
g = one(g,
'''                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4]))
''',
'''                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4])); gaps.append(int(m[5]))
''', 'calibration parse')
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

# --- server replay: enable trace RTX, retransmit modeled drops, reject clamping,
# and use a recovery-aware oracle.
s = SERVER.read_text()
s = one(s, '#include <map>\n', '#include <map>\n#include <limits>\n', 'limits include')
anchor = '''// ---------------------------------------------------------------------------------------\n// Sustained VRChat-like trace replay (HELIX_SYNTHETIC_TRACE=<file>).\n'''
trace_view = '''to_headset::video_stream_data_shard::view_info_t make_trace_view_info()\n{\n\tauto view = make_view_info();\n\t// Test-only eligibility sentinel: unlike ordinary synthetic cases, trace replay must\n\t// keep RTX eligible. It intentionally does not model a real predicted display time.\n\tview.display_time = std::numeric_limits<decltype(view.display_time)>::max() / 4;\n\treturn view;\n}\n\n'''
s = one(s, anchor, trace_view + anchor, 'trace view-info insertion')
s = one(s,
'''// its own oracle: a frame is expected complete iff none of its rows is path-dropped.\n''',
'''// its own oracle: clean frames must complete; damaged frames are characterized as\n// recovered only when every modeled drop for that frame was actually retransmitted.\n''', 'trace oracle comment')
s = one(s,
'''constexpr double trace_false_incomplete_budget = 0.005; // provisional: 0.5% of frames\n''', '', 'remove arbitrary budget')
s = one(s, 'packet.view_info = make_view_info();', 'packet.view_info = make_trace_view_info();', 'trace original view info')
# The first occurrence changed above must be the one inside run_trace; ordinary sender uses remain.
# Undo accidental earlier replacement if necessary by requiring trace function now contains sentinel call.
trace_pos = s.find('int run_trace(')
if trace_pos < 0 or 'packet.view_info = make_trace_view_info();' not in s[trace_pos:]:
    raise SystemExit('FAIL: trace view-info replacement did not land in run_trace')

s = one(s,
'''\tstd::array<uint64_t, 2> sequence{};\n\tstd::vector<int64_t> lateness_us;\n''',
'''\tstd::array<uint64_t, 2> sequence{};\n\tstd::map<std::pair<uint8_t, uint64_t>, helix_vrchat_trace::row> dropped_packets;\n\tstd::map<std::pair<uint8_t, uint64_t>, uint64_t> dropped_by_frame;\n\tstd::map<std::pair<uint8_t, uint64_t>, uint64_t> retransmitted_by_frame;\n\tstd::set<std::pair<uint8_t, uint64_t>> retransmitted_sequences;\n\tsize_t rtx_cursor = 0;\n\tuint64_t rtx_retransmissions = 0;\n\tauto process_rtx = [&]() {\n\t\twhile (rtx_cursor < obs.rtx.size())\n\t\t{\n\t\t\tconst auto & request = obs.rtx[rtx_cursor++];\n\t\t\tconst auto key = std::pair<uint8_t, uint64_t>{request.stream_index, request.packet_sequence};\n\t\t\tauto it = dropped_packets.find(key);\n\t\t\tif (it == dropped_packets.end() || !retransmitted_sequences.insert(key).second)\n\t\t\t\tcontinue;\n\t\t\tconst auto & rr = it->second;\n\t\t\tto_headset::video_stream_data_shard packet{};\n\t\t\tpacket.stream_item_idx = rr.stream;\n\t\t\tpacket.frame_idx = rr.frame;\n\t\t\tpacket.packet_sequence = request.packet_sequence;\n\t\t\tpacket.retransmission = true;\n\t\t\tpacket.shard_idx = rr.shard;\n\t\t\tif (rr.shard == 0)\n\t\t\t\tpacket.view_info = make_trace_view_info();\n\t\t\tif (rr.shard == rr.shards - 1)\n\t\t\t\tpacket.timing_info = to_headset::video_stream_data_shard::timing_info_t{};\n\t\t\tconst size_t overhead = serialized_size(packet.view_info) + serialized_size(packet.timing_info);\n\t\t\tconst size_t limit = to_headset::video_stream_data_shard::max_payload_size > overhead\n\t\t\t                             ? to_headset::video_stream_data_shard::max_payload_size - overhead\n\t\t\t                             : 0;\n\t\t\tif (rr.bytes > limit)\n\t\t\t\tthrow std::runtime_error("trace retransmission payload would clamp");\n\t\t\tpacket.payload = std::span<uint8_t>{filler.data(), rr.bytes};\n\t\t\tconnection.send_stream(std::move(packet));\n\t\t\t++rtx_retransmissions;\n\t\t\t++retransmitted_by_frame[{rr.stream, rr.frame}];\n\t\t}\n\t};\n\tstd::vector<int64_t> lateness_us;\n''', 'RTX state insertion')
s = one(s,
'''\t\tif (row.drop)\n\t\t{\n\t\t\t++path_dropped;\n\t\t\tcontinue;\n\t\t}\n''',
'''\t\tif (row.drop)\n\t\t{\n\t\t\t++path_dropped;\n\t\t\tdropped_packets[{row.stream, seq}] = row;\n\t\t\t++dropped_by_frame[{row.stream, row.frame}];\n\t\t\tcontinue;\n\t\t}\n''', 'drop cache')
s = one(s, '\t\t\t\tconnection.poll(absorb, 0);\n', '\t\t\t\tconnection.poll(absorb, 0);\n\t\t\t\tprocess_rtx();\n', 'wait-loop RTX service')
s = one(s,
'''\t\tconst size_t length = std::min<size_t>(row.bytes, limit);\n\t\tclamped_bytes += row.bytes - length;\n\t\tpacket.payload = std::span<uint8_t>{filler.data(), length};\n''',
'''\t\tif (row.bytes > limit)\n\t\t{\n\t\t\tU_LOG_E("HELIX_VRCHAT_TRACE_INVALID payload_would_clamp stream=%u frame=%llu shard=%u bytes=%u limit=%zu",\n\t\t\t        row.stream, static_cast<unsigned long long>(row.frame), row.shard, row.bytes, limit);\n\t\t\treturn 2;\n\t\t}\n\t\tpacket.payload = std::span<uint8_t>{filler.data(), row.bytes};\n''', 'reject payload clamp')
s = one(s, 'uint64_t sent = 0, path_dropped = 0, clamped_bytes = 0;', 'uint64_t sent = 0, path_dropped = 0;', 'remove clamp counter')
s = one(s,
'''\tcollect(connection, obs, std::chrono::duration_cast<std::chrono::milliseconds>(trace_drain_time));\n''',
'''\t{\n\t\tconst auto deadline = clock::now() + trace_drain_time;\n\t\twhile (clock::now() < deadline)\n\t\t{\n\t\t\tconnection.poll(absorb, 10);\n\t\t\tprocess_rtx();\n\t\t}\n\t}\n''', 'RTX-aware drain')

start = s.find('\tuint64_t frames_total = 0, ok_complete = 0, ok_incomplete = 0, false_complete = 0, false_incomplete = 0;')
end_marker = '\treturn pass ? 0 : 1;\n'
end = s.find(end_marker, start)
if start < 0 or end < 0:
    raise SystemExit('FAIL: result/oracle block anchors missing')
end += len(end_marker)
new_tail = r'''\tuint64_t frames_total = 0, clean_complete = 0, clean_failed = 0;\n\tuint64_t damaged_recovered = 0, damaged_unrecovered = 0, false_complete = 0;\n\tstd::vector<double> assembly_ms;\n\tfor (const auto & [key, info]: tr.frames)\n\t{\n\t\t++frames_total;\n\t\tconst auto it = obs.feedback.find(key);\n\t\tconst bool complete = it != obs.feedback.end() && it->second.sent_to_decoder != 0;\n\t\tif (!info.has_drop)\n\t\t{\n\t\t\tif (complete) ++clean_complete; else ++clean_failed;\n\t\t}\n\t\telse\n\t\t{\n\t\t\tconst uint64_t dropped = dropped_by_frame[key];\n\t\t\tconst uint64_t resent = retransmitted_by_frame[key];\n\t\t\tif (complete && resent == dropped && dropped != 0) ++damaged_recovered;\n\t\t\telse if (complete) ++false_complete;\n\t\t\telse ++damaged_unrecovered;\n\t\t}\n\t\tif (complete && it->second.received_first_packet != 0 && it->second.received_last_packet >= it->second.received_first_packet)\n\t\t\tassembly_ms.push_back(double(it->second.received_last_packet - it->second.received_first_packet) / 1e6);\n\t}\n\n\tauto percentile = [](std::vector<double> v, double q) {\n\t\tif (v.empty()) return 0.0;\n\t\tstd::sort(v.begin(), v.end());\n\t\treturn v[std::min(v.size() - 1, size_t(q * double(v.size())))];\n\t};\n\tstd::vector<double> late_ms;\n\tlate_ms.reserve(lateness_us.size());\n\tfor (auto l: lateness_us) late_ms.push_back(double(l) / 1e3);\n\n\t// Characterization gate: no arbitrary damaged-frame recovery percentage is frozen yet.\n\t// Strict invariants are clean-frame correctness, no unexplained complete damaged frame,\n\t// and proof that the live RTX path was exercised and successfully rescued at least one frame.\n\tconst bool pass = clean_failed == 0 && false_complete == 0 && !obs.rtx.empty() &&\n\t                  rtx_retransmissions != 0 && damaged_recovered != 0;\n\n\tU_LOG_I("HELIX_VRCHAT_TRACE_RESULT pass=%d phase=characterization frames=%llu sent=%llu path_dropped=%llu "\n\t        "clean_complete=%llu clean_failed=%llu damaged_recovered=%llu damaged_unrecovered=%llu false_complete=%llu "\n\t        "gap_reports=%zu rtx_requests=%zu rtx_retransmissions=%llu "\n\t        "assembly_ms(p50/p99/max)=%.3f/%.3f/%.3f send_lateness_ms(p50/p99/max)=%.3f/%.3f/%.3f",\n\t        pass, static_cast<unsigned long long>(frames_total), static_cast<unsigned long long>(sent),\n\t        static_cast<unsigned long long>(path_dropped), static_cast<unsigned long long>(clean_complete),\n\t        static_cast<unsigned long long>(clean_failed), static_cast<unsigned long long>(damaged_recovered),\n\t        static_cast<unsigned long long>(damaged_unrecovered), static_cast<unsigned long long>(false_complete),\n\t        obs.gaps.size(), obs.rtx.size(), static_cast<unsigned long long>(rtx_retransmissions),\n\t        percentile(assembly_ms, 0.5), percentile(assembly_ms, 0.99), percentile(assembly_ms, 1.0),\n\t        percentile(late_ms, 0.5), percentile(late_ms, 0.99), percentile(late_ms, 1.0));\n\treturn pass ? 0 : 1;\n'''.replace('\\n','\n').replace('\\t','\t')
s = s[:start] + new_tail + s[end:]
SERVER.write_text(s)

# --- docs: make the lane/status claims match the repaired semantics.
d = DOC.read_text()
d = d.replace('Result line: `HELIX_VRCHAT_TRACE_RESULT`. `false_complete` must be 0. `false_incomplete` plus\n`silent_expected_complete` must stay under 0.5% of frames; that budget is my provisional\nnumber, not a measured one.',
'''Result line: `HELIX_VRCHAT_TRACE_RESULT`. This first lane is characterization, not promotion.\nClean frames are strict: `clean_failed` must be 0. Damaged frames count as recovered only when\nall modeled dropped sequences for that frame were retransmitted. `false_complete` must be 0,\nand the run must exercise RTX and recover at least one damaged frame. No damaged-frame recovery\npercentage is frozen until repeated characterization runs are collected.''')
d += '''\n\n## Representative-lane repair notes\n\nThe repaired lane intentionally differs from the original patch in four ways:\n\n1. trace replay uses an RTX-eligible test-only display-time sentinel instead of the ordinary\n   synthetic `display_time=0`;\n2. dropped rows are cached and retransmitted only in response to actual Quest RTX requests;\n3. payload clamping is forbidden (the generator reserves first/last-shard headroom and the\n   server aborts if any row would still clamp);\n4. trace identity is frozen externally by the seal/audit scripts using whole-file SHA-256.\n\nThis is a separate representative/integration lane. It does not alter or supersede the frozen\nlive8/burst8 deterministic checkpoint.\n'''
DOC.write_text(d)

print('PASS: representative trace repair applied')
print('STATUS: source transformed only; build/runtime not executed')
