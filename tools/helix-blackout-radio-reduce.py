#!/usr/bin/env python3
import bisect
import collections
import importlib.util
import re
import statistics
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BASE_REDUCER = ROOT / "tools/helix-blackout-reduce.py"
spec = importlib.util.spec_from_file_location("helix_blackout_reduce", BASE_REDUCER)
base = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(base)

TRACE_RE = re.compile(
    r"(?P<ts>\d+\.\d+):\s+dp_rx_udp_pkt:\s+.*?"
    r"\bip_id=(?P<ip>\d+)\s+srcport=(?P<src>\d+)\s+dstport=(?P<dst>-?\d+)"
)
TRACE_ALIGN_MAX_MAD = 0.010
TRACE_LOOKUP_SLOP = 0.020
QUEST_SEARCH_SLOP = 0.250
QUEST_LOOKUP_SLOP = 0.100
LOCAL_CONTEXT_SECONDS = 0.500
MIN_LOCAL_UNIQUE_MATCHES = 50
MIN_LOCAL_MATCH_RATIO = 0.90
MIN_BASELINE_PACKETS = 50
MIN_BASELINE_TRACE_RATIO = 0.90
MIN_MISSING_PACKETS = 10
MIN_STREAM_PORT_PAIR_PACKETS = 100
DRIVER_PRESENT_DECISIVE_RATIO = 0.80
DRIVER_ABSENT_DECISIVE_RATIO = 0.10
DECISIVE_CLASSES = {
    "quest_lower_receive_path_after_dp_rx_udp_pkt",
    "before_dp_rx_udp_pkt_ap_rf_radio_firmware_or_earlier_driver",
}


def driver_key(frame: bytes, host_ip: str, quest_ip: str):
    if len(frame) < 14:
        return None
    offset = 14
    ethertype = int.from_bytes(frame[12:14], "big")
    while ethertype in (0x8100, 0x88A8):
        if len(frame) < offset + 4:
            return None
        ethertype = int.from_bytes(frame[offset + 2:offset + 4], "big")
        offset += 4
    if ethertype != 0x0800 or len(frame) < offset + 28:
        return None
    ihl = (frame[offset] & 0x0F) * 4
    if ihl < 20 or len(frame) < offset + ihl + 8 or frame[offset + 9] != 17:
        return None
    src = ".".join(str(x) for x in frame[offset + 12:offset + 16])
    dst = ".".join(str(x) for x in frame[offset + 16:offset + 20])
    if src != host_ip or dst != quest_ip:
        return None
    ip_id = int.from_bytes(frame[offset + 4:offset + 6], "big")
    udp = offset + ihl
    src_port = int.from_bytes(frame[udp:udp + 2], "big")
    dst_port = int.from_bytes(frame[udp + 2:udp + 4], "big")
    return ip_id, src_port, dst_port


def parse_trace(path: Path):
    out = []
    for line in path.read_text(errors="replace").splitlines():
        m = TRACE_RE.search(line)
        if not m:
            continue
        dst = int(m.group("dst"))
        if dst < 0:
            dst += 65536
        out.append((float(m.group("ts")), (int(m.group("ip")), int(m.group("src")), dst)))
    return out


def parse_ports(raw: str):
    ports = []
    for item in raw.split(","):
        item = item.strip()
        if item.isdigit():
            ports.append(int(item))
    return ports


def pcap_port_pair_counts(path: Path, host_ip: str, quest_ip: str):
    counts = collections.Counter()
    for _ts, frame, *_ in base.iter_pcap(path):
        key = driver_key(frame, host_ip, quest_ip)
        if key is not None:
            counts[(key[1], key[2])] += 1
    return counts


def sync_trace_to_quest(raw_trace_records, quest_pcap, host_ip, quest_ip, sync_ports):
    trace_by_port = collections.defaultdict(list)
    for ts, key in raw_trace_records:
        if key[2] in sync_ports:
            trace_by_port[key[2]].append(ts)

    quest_by_port = collections.defaultdict(list)
    for ts, frame, *_ in base.iter_pcap(quest_pcap):
        key = driver_key(frame, host_ip, quest_ip)
        if key is not None and key[2] in sync_ports:
            quest_by_port[key[2]].append(ts)

    offsets = []
    used = []
    for port in sync_ports:
        if not trace_by_port[port] or not quest_by_port[port]:
            continue
        # The end marker is emitted once per port immediately before trace stop.
        offsets.append(quest_by_port[port][-1] - trace_by_port[port][-1])
        used.append(port)
    if len(offsets) != len(sync_ports) or len(offsets) < 3:
        return None, None, used
    offset = statistics.median(offsets)
    mad = statistics.median(abs(x - offset) for x in offsets)
    return offset, mad, used


def collect_pcap_window(path, start, end, host_ip, quest_ip):
    rows = []
    for ts, frame, *_ in base.iter_pcap(path):
        if ts < start:
            continue
        if ts > end:
            break
        fp = base.udp_fingerprint(frame, host_ip, quest_ip)
        key = driver_key(frame, host_ip, quest_ip)
        if fp is not None and key is not None:
            rows.append((ts, fp, key))
    return rows


def has_time(times, target, slop):
    if not times:
        return False
    i = bisect.bisect_left(times, target - slop)
    return i < len(times) and times[i] <= target + slop


def trace_stats(path: Path):
    if not path.exists():
        return [], []
    text = path.read_text(errors="replace")
    overruns = [int(x) for x in re.findall(r"\boverrun:\s*(\d+)", text)]
    dropped = [int(x) for x in re.findall(r"\b(?:dropped events|dropped):\s*(\d+)", text)]
    return overruns, dropped


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: helix-blackout-radio-reduce.py <capture-dir>")
    src = Path(sys.argv[1]).expanduser().resolve()
    metadata = base.read_metadata(src / "metadata.txt")
    host_ip = metadata.get("host_ip", "")
    quest_ip = metadata.get("quest_ip", "")
    host_pcap = src / "host.pcap"
    quest_pcap = src / "quest.pcap"
    trace_path = src / "quest-wlan-dp-rx-udp.trace"
    format_path = src / "quest-wlan-dp-rx-udp-format.txt"
    stats_path = src / "quest-wlan-trace-stats.txt"
    server_log = src / "server-log.txt"

    blockers = []
    for p in (host_pcap, quest_pcap, trace_path, format_path, stats_path, server_log):
        if not p.exists() or p.stat().st_size == 0:
            blockers.append(f"missing_or_empty:{p.name}")
    if not host_ip or not quest_ip:
        blockers.append("metadata_missing_host_or_quest_ip")

    fmt = format_path.read_text(errors="replace") if format_path.exists() else ""
    for field in ("ip_id", "srcport", "dstport"):
        if field not in fmt:
            blockers.append(f"trace_format_missing:{field}")

    sync_end_ports = parse_ports(metadata.get("quest_driver_trace_sync_end_ports", ""))
    if len(sync_end_ports) != 3:
        blockers.append("trace_sync_end_ports_missing_or_invalid")

    raw_trace_records = parse_trace(trace_path) if trace_path.exists() else []
    if not raw_trace_records:
        blockers.append("no_parseable_dp_rx_udp_pkt_records")

    port_counts = collections.Counter()
    if quest_pcap.exists() and host_ip and quest_ip:
        port_counts = pcap_port_pair_counts(quest_pcap, host_ip, quest_ip)
    sync_set = set(sync_end_ports) | set(parse_ports(metadata.get("quest_driver_trace_sync_start_ports", "")))
    stream_pairs = {
        pair for pair, count in port_counts.items()
        if count >= MIN_STREAM_PORT_PAIR_PACKETS and pair[1] not in sync_set
    }
    if not stream_pairs:
        blockers.append("no_high_volume_pc_to_quest_udp_port_pairs")

    trace_records = [r for r in raw_trace_records if (r[1][1], r[1][2]) in stream_pairs]
    if not trace_records:
        blockers.append("no_driver_records_for_high_volume_pc_to_quest_udp_ports")

    trace_offset = trace_mad = None
    sync_used = []
    if raw_trace_records and quest_pcap.exists() and host_ip and quest_ip and sync_end_ports:
        trace_offset, trace_mad, sync_used = sync_trace_to_quest(
            raw_trace_records, quest_pcap, host_ip, quest_ip, sync_end_ports
        )
        if trace_offset is None:
            blockers.append(f"trace_sync_alignment_ports_seen:{','.join(map(str, sync_used))}")
        elif trace_mad is None or trace_mad > TRACE_ALIGN_MAX_MAD:
            blockers.append(f"trace_sync_alignment_mad:{trace_mad}")

    tz = base.parse_offset(metadata.get("host_tz_offset", ""))
    capture_start_ns = base.epoch_ns(metadata, "capture_start_epoch_ns")
    capture_end_ns = base.epoch_ns(metadata, "capture_end_epoch_ns")
    capture_start = capture_start_ns / 1e9 if capture_start_ns is not None else None
    capture_end = capture_end_ns / 1e9 if capture_end_ns is not None else None
    events = base.parse_events(server_log, tz, capture_start, capture_end) if server_log.exists() else []
    mapped_events = [e for e in events if e["first_send_epoch"] is not None and e["last_send_epoch"] is not None]
    if not mapped_events:
        blockers.append("no_fully_mapped_gap_events")

    quest_offset = None
    if host_pcap.exists() and quest_pcap.exists() and host_ip and quest_ip:
        try:
            quest_offset, _qmad, _qm = base.derive_quest_clock_offset(host_pcap, quest_pcap, host_ip, quest_ip)
        except SystemExit as exc:
            blockers.append(f"quest_pcap_alignment:{exc}")

    overruns, dropped = trace_stats(stats_path)
    if dropped and any(x != 0 for x in dropped):
        blockers.append("trace_buffer_reported_dropped_events")

    event_results = []
    if trace_offset is not None and quest_offset is not None and trace_records:
        trace_times_by_key = collections.defaultdict(list)
        for ts, key in trace_records:
            trace_times_by_key[key].append(ts)

        mapped_trace_first = trace_records[0][0] + trace_offset
        mapped_trace_last = trace_records[-1][0] + trace_offset

        for idx, event in enumerate(mapped_events, 1):
            event_start = event["first_send_epoch"] - 0.005
            event_end = event["last_send_epoch"] + 0.005
            context_start = event_start - LOCAL_CONTEXT_SECONDS
            context_end = event_end + LOCAL_CONTEXT_SECONDS
            if context_start < mapped_trace_first - 0.020 or context_end > mapped_trace_last + 0.020:
                blockers.append(f"event_{idx}:surrounding_context_outside_retained_driver_trace")
                continue

            host_context = collect_pcap_window(host_pcap, context_start, context_end, host_ip, quest_ip)
            quest_context = collect_pcap_window(
                quest_pcap,
                context_start + quest_offset - QUEST_SEARCH_SLOP,
                context_end + quest_offset + QUEST_SEARCH_SLOP,
                host_ip,
                quest_ip,
            )
            local = base.correlate_window(
                [(ts, fp) for ts, fp, _key in host_context],
                [(ts, fp) for ts, fp, _key in quest_context],
                quest_offset,
            )
            if local["unique_matches"] < MIN_LOCAL_UNIQUE_MATCHES:
                blockers.append(f"event_{idx}:local_unique_matches:{local['unique_matches']}<{MIN_LOCAL_UNIQUE_MATCHES}")
            if local["match_ratio"] < MIN_LOCAL_MATCH_RATIO:
                blockers.append(f"event_{idx}:local_match_ratio:{local['match_ratio']:.3f}<{MIN_LOCAL_MATCH_RATIO:.2f}")
            local_q_offset = local["local_offset"]

            quest_fp_times = collections.defaultdict(list)
            for qts, fp, _key in quest_context:
                quest_fp_times[fp].append(qts)

            baseline = baseline_trace = missing = missing_trace = 0
            for hts, fp, key in host_context:
                if (key[1], key[2]) not in stream_pairs:
                    continue
                predicted_q = hts + local_q_offset
                q_present = has_time(quest_fp_times.get(fp), predicted_q, QUEST_LOOKUP_SLOP)
                predicted_trace = predicted_q - trace_offset
                t_present = has_time(trace_times_by_key.get(key), predicted_trace, TRACE_LOOKUP_SLOP)
                inside_event = event_start <= hts <= event_end
                if inside_event:
                    if not q_present:
                        missing += 1
                        missing_trace += int(t_present)
                elif q_present:
                    baseline += 1
                    baseline_trace += int(t_present)

            baseline_ratio = baseline_trace / baseline if baseline else 0.0
            missing_trace_ratio = missing_trace / missing if missing else None
            event_results.append(
                (idx, local["unique_matches"], local["match_ratio"], local_q_offset,
                 baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_trace_ratio)
            )
            if baseline < MIN_BASELINE_PACKETS:
                blockers.append(f"event_{idx}:driver_baseline_packets:{baseline}<{MIN_BASELINE_PACKETS}")
            elif baseline_ratio < MIN_BASELINE_TRACE_RATIO:
                blockers.append(f"event_{idx}:driver_baseline_ratio:{baseline_ratio:.3f}<{MIN_BASELINE_TRACE_RATIO:.2f}")
            if missing < MIN_MISSING_PACKETS:
                blockers.append(f"event_{idx}:quest_missing_packets:{missing}<{MIN_MISSING_PACKETS}")

    decisive_results = [
        r for r in event_results
        if r[1] >= MIN_LOCAL_UNIQUE_MATCHES and r[2] >= MIN_LOCAL_MATCH_RATIO
        and r[4] >= MIN_BASELINE_PACKETS and r[6] >= MIN_BASELINE_TRACE_RATIO
        and r[7] >= MIN_MISSING_PACKETS
    ]
    classification = "non_decisive"
    if decisive_results and not blockers:
        ratios = [r[9] for r in decisive_results if r[9] is not None]
        if ratios and all(r >= DRIVER_PRESENT_DECISIVE_RATIO for r in ratios):
            classification = "quest_lower_receive_path_after_dp_rx_udp_pkt"
        elif ratios and all(r <= DRIVER_ABSENT_DECISIVE_RATIO for r in ratios):
            classification = "before_dp_rx_udp_pkt_ap_rf_radio_firmware_or_earlier_driver"
        else:
            classification = "mixed_driver_visibility"

    decision_capable = not blockers and classification in DECISIVE_CLASSES
    lines = [
        f"source={src}",
        f"trace_event=wlan:dp_rx_udp_pkt",
        f"trace_sync_end_ports={','.join(map(str, sync_end_ports)) if sync_end_ports else 'unavailable'}",
        f"trace_sync_ports_used={','.join(map(str, sync_used)) if sync_used else 'unavailable'}",
        f"trace_to_quest_pcap_offset_seconds={trace_offset}",
        f"trace_sync_alignment_mad_seconds={trace_mad}",
        f"pc_to_quest_stream_port_pairs={','.join(f'{a}:{b}' for a, b in sorted(stream_pairs)) if stream_pairs else 'unavailable'}",
        f"trace_records_all_udp={len(raw_trace_records)}",
        f"trace_records_stream_ports={len(trace_records)}",
        f"trace_overrun_samples={','.join(map(str, overruns)) if overruns else 'unavailable'}",
        f"trace_dropped_samples={','.join(map(str, dropped)) if dropped else 'unavailable'}",
        f"mapped_gap_events={len(mapped_events)}",
    ]
    for row in event_results:
        idx, unique_matches, local_match, local_offset, baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_ratio = row
        lines.append(
            f"event_{idx}=local_unique_matches:{unique_matches} local_match_ratio:{local_match:.6f} "
            f"local_quest_offset:{local_offset:.9f} baseline_packets:{baseline} baseline_trace:{baseline_trace} "
            f"baseline_trace_ratio:{baseline_ratio:.6f} missing_at_wlan:{missing} "
            f"missing_seen_in_driver:{missing_trace} missing_driver_ratio:"
            f"{'unavailable' if missing_ratio is None else f'{missing_ratio:.6f}'}"
        )
    lines.append(f"radio_decision_capable={'true' if decision_capable else 'false'}")
    lines.append(f"radio_classification={classification}")
    for i, blocker in enumerate(blockers, 1):
        lines.append(f"radio_decision_blocker_{i}={blocker}")

    out = src / "radio-attribution-summary.txt"
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
