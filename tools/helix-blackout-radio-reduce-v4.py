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
TRACE_SYNC_MAX_MAD = 0.010
TRACE_CLOCK_DRIFT_MAX = 0.010
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
DRIVER_PRESENT_RATIO = 0.80
DRIVER_ABSENT_RATIO = 0.10


def driver_key(frame: bytes, host_ip: str, quest_ip: str):
    if len(frame) < 14:
        return None
    off = 14
    ethertype = int.from_bytes(frame[12:14], "big")
    while ethertype in (0x8100, 0x88A8):
        if len(frame) < off + 4:
            return None
        ethertype = int.from_bytes(frame[off + 2:off + 4], "big")
        off += 4
    if ethertype != 0x0800 or len(frame) < off + 28:
        return None
    ihl = (frame[off] & 0x0F) * 4
    if ihl < 20 or len(frame) < off + ihl + 8 or frame[off + 9] != 17:
        return None
    src = ".".join(str(x) for x in frame[off + 12:off + 16])
    dst = ".".join(str(x) for x in frame[off + 16:off + 20])
    if src != host_ip or dst != quest_ip:
        return None
    ip_id = int.from_bytes(frame[off + 4:off + 6], "big")
    udp = off + ihl
    src_port = int.from_bytes(frame[udp:udp + 2], "big")
    dst_port = int.from_bytes(frame[udp + 2:udp + 4], "big")
    return ip_id, src_port, dst_port


def parse_trace(path: Path):
    rows = []
    for line in path.read_text(errors="replace").splitlines():
        m = TRACE_RE.search(line)
        if not m:
            continue
        dst = int(m.group("dst"))
        if dst < 0:
            dst += 65536
        rows.append((float(m.group("ts")), (int(m.group("ip")), int(m.group("src")), dst)))
    return rows


def parse_ports(raw: str):
    result = []
    for item in raw.split(","):
        item = item.strip()
        if item.isdigit():
            result.append(int(item))
    return result


def pcap_port_pair_counts(path: Path, host_ip: str, quest_ip: str):
    counts = collections.Counter()
    for _ts, frame, *_ in base.iter_pcap(path):
        key = driver_key(frame, host_ip, quest_ip)
        if key is not None:
            counts[(key[1], key[2])] += 1
    return counts


def sync_offset(raw_trace, quest_pcap, host_ip, quest_ip, ports):
    quest_marker = {}
    for ts, frame, *_ in base.iter_pcap(quest_pcap):
        key = driver_key(frame, host_ip, quest_ip)
        if key is not None and key[2] in ports:
            quest_marker[key[2]] = (ts, key)

    trace_by_key = collections.defaultdict(list)
    for ts, key in raw_trace:
        trace_by_key[key].append(ts)

    offsets = []
    used = []
    for port in ports:
        marker = quest_marker.get(port)
        if marker is None:
            continue
        quest_ts, key = marker
        candidates = trace_by_key.get(key, ())
        if not candidates:
            continue
        offsets.append(quest_ts - candidates[-1])
        used.append(port)
    if len(used) != len(ports) or len(used) != 3:
        return None, None, used
    median = statistics.median(offsets)
    mad = statistics.median(abs(x - median) for x in offsets)
    return median, mad, used


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
    dropped = [int(x) for x in re.findall(r"\bdropped events:\s*(\d+)", text)]
    return overruns, dropped


def global_quality(metadata, src):
    blockers = []
    expected = {
        "runtime_source_equivalent": "true",
        "usb_detached_during_workload": "true",
        "wifi_endpoint_state_consistent": "true",
        "attribution_scope": "host_capture_to_quest_driver_trace_to_wlan",
    }
    for key, value in expected.items():
        if metadata.get(key) != value:
            blockers.append(f"{key}:{metadata.get(key, 'missing')}")
    for label in ("host", "quest"):
        drops = base.tcpdump_kernel_drops(src / f"{label}-tcpdump.txt")
        if drops is None:
            blockers.append(f"{label}_tcpdump_kernel_drops_unavailable")
        elif drops != 0:
            blockers.append(f"{label}_tcpdump_kernel_drops:{drops}")
    return blockers


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: helix-blackout-radio-reduce-v4.py <capture-dir>")
    src = Path(sys.argv[1]).expanduser().resolve()
    metadata = base.read_metadata(src / "metadata.txt")
    blockers = global_quality(metadata, src)
    notes = []

    host_ip = metadata.get("host_ip", "")
    quest_ip = metadata.get("quest_ip", "")
    host_pcap = src / "host.pcap"
    quest_pcap = src / "quest.pcap"
    trace_path = src / "quest-wlan-dp-rx-udp.trace"
    format_path = src / "quest-wlan-dp-rx-udp-format.txt"
    stats_path = src / "quest-wlan-trace-stats.txt"
    server_log = src / "server-log.txt"

    for p in (host_pcap, quest_pcap, trace_path, format_path, stats_path, server_log):
        if not p.exists() or p.stat().st_size == 0:
            blockers.append(f"missing_or_empty:{p.name}")
    if not host_ip or not quest_ip:
        blockers.append("metadata_missing_host_or_quest_ip")

    fmt = format_path.read_text(errors="replace") if format_path.exists() else ""
    for field in ("ip_id", "srcport", "dstport"):
        if field not in fmt:
            blockers.append(f"trace_format_missing:{field}")

    overruns, dropped = trace_stats(stats_path)
    if not dropped:
        blockers.append("trace_dropped_event_counters_unavailable")
    elif any(x != 0 for x in dropped):
        blockers.append("trace_buffer_reported_dropped_events")

    raw_trace = parse_trace(trace_path) if trace_path.exists() else []
    if not raw_trace:
        blockers.append("no_parseable_dp_rx_udp_pkt_records")

    start_ports = parse_ports(metadata.get("quest_driver_trace_sync_start_ports", ""))
    end_ports = parse_ports(metadata.get("quest_driver_trace_sync_end_ports", ""))
    if len(start_ports) != 3:
        blockers.append("trace_sync_start_ports_missing_or_invalid")
    if len(end_ports) != 3:
        blockers.append("trace_sync_end_ports_missing_or_invalid")

    end_offset = end_mad = None
    end_used = []
    if raw_trace and quest_pcap.exists() and host_ip and quest_ip and len(end_ports) == 3:
        end_offset, end_mad, end_used = sync_offset(raw_trace, quest_pcap, host_ip, quest_ip, end_ports)
        if end_offset is None:
            blockers.append(f"trace_end_sync_ports_seen:{','.join(map(str, end_used)) or 'none'}")
        elif end_mad is None or end_mad > TRACE_SYNC_MAX_MAD:
            blockers.append(f"trace_end_sync_mad:{end_mad}")

    start_offset = start_mad = None
    start_used = []
    if raw_trace and quest_pcap.exists() and host_ip and quest_ip and len(start_ports) == 3:
        start_offset, start_mad, start_used = sync_offset(raw_trace, quest_pcap, host_ip, quest_ip, start_ports)
        if start_offset is None:
            notes.append("trace_start_sync_not_retained_expected_with_overwrite")
        elif start_mad is None or start_mad > TRACE_SYNC_MAX_MAD:
            blockers.append(f"trace_start_sync_mad:{start_mad}")
        elif end_offset is not None and abs(start_offset - end_offset) > TRACE_CLOCK_DRIFT_MAX:
            blockers.append(f"trace_clock_offset_drift:{abs(start_offset-end_offset)}")

    port_counts = collections.Counter()
    if quest_pcap.exists() and host_ip and quest_ip:
        port_counts = pcap_port_pair_counts(quest_pcap, host_ip, quest_ip)
    stream_pairs = {pair for pair, count in port_counts.items() if count >= MIN_STREAM_PORT_PAIR_PACKETS}
    if not stream_pairs:
        blockers.append("no_high_volume_pc_to_quest_udp_port_pairs")

    trace_rows = [r for r in raw_trace if (r[1][1], r[1][2]) in stream_pairs]
    if not trace_rows:
        blockers.append("no_driver_records_for_high_volume_pc_to_quest_udp_ports")

    tz = base.parse_offset(metadata.get("host_tz_offset", ""))
    start_ns = base.epoch_ns(metadata, "capture_start_epoch_ns")
    end_ns = base.epoch_ns(metadata, "capture_end_epoch_ns")
    capture_start = start_ns / 1e9 if start_ns is not None else None
    capture_end = end_ns / 1e9 if end_ns is not None else None
    events = base.parse_events(server_log, tz, capture_start, capture_end) if server_log.exists() else []
    events = [e for e in events if e["first_send_epoch"] is not None and e["last_send_epoch"] is not None]
    if not events:
        blockers.append("no_fully_mapped_gap_events")

    quest_offset = None
    if host_pcap.exists() and quest_pcap.exists() and host_ip and quest_ip:
        try:
            quest_offset, _mad, _matches = base.derive_quest_clock_offset(host_pcap, quest_pcap, host_ip, quest_ip)
        except SystemExit as exc:
            blockers.append(f"quest_pcap_alignment:{exc}")

    event_rows = []
    decisive = []
    skipped = []
    if end_offset is not None and quest_offset is not None and trace_rows:
        trace_by_key = collections.defaultdict(list)
        for ts, key in trace_rows:
            trace_by_key[key].append(ts)
        retained_first = trace_rows[0][0] + end_offset
        retained_last = trace_rows[-1][0] + end_offset

        for idx, event in enumerate(events, 1):
            event_start = event["first_send_epoch"] - 0.005
            event_end = event["last_send_epoch"] + 0.005
            context_start = event_start - LOCAL_CONTEXT_SECONDS
            context_end = event_end + LOCAL_CONTEXT_SECONDS
            if context_start < retained_first - TRACE_LOOKUP_SLOP or context_end > retained_last + TRACE_LOOKUP_SLOP:
                skipped.append((idx, "outside_retained_driver_trace"))
                continue

            host_ctx = collect_pcap_window(host_pcap, context_start, context_end, host_ip, quest_ip)
            quest_ctx = collect_pcap_window(
                quest_pcap,
                context_start + quest_offset - QUEST_SEARCH_SLOP,
                context_end + quest_offset + QUEST_SEARCH_SLOP,
                host_ip,
                quest_ip,
            )
            local = base.correlate_window(
                [(ts, fp) for ts, fp, _ in host_ctx],
                [(ts, fp) for ts, fp, _ in quest_ctx],
                quest_offset,
            )
            local_q_offset = local["local_offset"]
            local_good = (
                local["unique_matches"] >= MIN_LOCAL_UNIQUE_MATCHES
                and local["match_ratio"] >= MIN_LOCAL_MATCH_RATIO
                and local["local_mad"] is not None
                and local["local_mad"] <= base.MAX_LOCAL_MAD_SECONDS
                and local["host_duplicate_ratio"] <= base.MAX_DUPLICATE_RATIO
                and local["quest_duplicate_ratio"] <= base.MAX_DUPLICATE_RATIO
            )

            quest_fp_times = collections.defaultdict(list)
            for qts, fp, _ in quest_ctx:
                quest_fp_times[fp].append(qts)

            baseline = baseline_trace = missing = missing_trace = 0
            for hts, fp, key in host_ctx:
                if (key[1], key[2]) not in stream_pairs:
                    continue
                q_present = has_time(quest_fp_times.get(fp), hts + local_q_offset, QUEST_LOOKUP_SLOP)
                t_present = has_time(trace_by_key.get(key), hts + local_q_offset - end_offset, TRACE_LOOKUP_SLOP)
                if event_start <= hts <= event_end:
                    if not q_present:
                        missing += 1
                        missing_trace += int(t_present)
                elif q_present:
                    baseline += 1
                    baseline_trace += int(t_present)

            baseline_ratio = baseline_trace / baseline if baseline else 0.0
            missing_ratio = missing_trace / missing if missing else None
            good = (
                local_good
                and baseline >= MIN_BASELINE_PACKETS
                and baseline_ratio >= MIN_BASELINE_TRACE_RATIO
                and missing >= MIN_MISSING_PACKETS
                and missing_ratio is not None
            )
            event_rows.append((idx, local, baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_ratio, good))
            if good:
                decisive.append((idx, missing_ratio))

    if not decisive:
        blockers.append("no_decisive_gap_event_covered_by_retained_driver_trace")

    classification = "non_decisive"
    if decisive and not blockers:
        ratios = [ratio for _idx, ratio in decisive]
        if all(r >= DRIVER_PRESENT_RATIO for r in ratios):
            classification = "quest_lower_receive_path_after_dp_rx_udp_pkt"
        elif all(r <= DRIVER_ABSENT_RATIO for r in ratios):
            classification = "before_dp_rx_udp_pkt_ap_rf_radio_firmware_or_earlier_driver"
        else:
            classification = "mixed_driver_visibility"

    decision_capable = not blockers and classification in {
        "quest_lower_receive_path_after_dp_rx_udp_pkt",
        "before_dp_rx_udp_pkt_ap_rf_radio_firmware_or_earlier_driver",
    }

    lines = [
        f"source={src}",
        "trace_event=wlan:dp_rx_udp_pkt",
        f"trace_records_all_udp={len(raw_trace)}",
        f"trace_records_stream_ports={len(trace_rows)}",
        f"stream_port_pairs={','.join(f'{a}:{b}' for a,b in sorted(stream_pairs)) if stream_pairs else 'unavailable'}",
        f"trace_end_sync_ports={','.join(map(str,end_ports)) if end_ports else 'unavailable'}",
        f"trace_end_sync_ports_seen={','.join(map(str,end_used)) if end_used else 'unavailable'}",
        f"trace_end_offset_seconds={end_offset}",
        f"trace_end_sync_mad_seconds={end_mad}",
        f"trace_start_offset_seconds={start_offset}",
        f"trace_start_sync_mad_seconds={start_mad}",
        f"trace_overrun_samples={','.join(map(str,overruns)) if overruns else 'unavailable'}",
        f"trace_dropped_event_samples={','.join(map(str,dropped)) if dropped else 'unavailable'}",
        f"mapped_gap_events={len(events)}",
        f"covered_gap_events={len(event_rows)}",
        f"decisive_gap_events={len(decisive)}",
    ]
    for idx, reason in skipped:
        lines.append(f"event_{idx}_skipped={reason}")
    for row in event_rows:
        idx, local, baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_ratio, good = row
        local_mad_text = "unavailable" if local["local_mad"] is None else f"{local['local_mad']:.9f}"
        missing_ratio_text = "unavailable" if missing_ratio is None else f"{missing_ratio:.6f}"
        lines.append(
            f"event_{idx}=local_unique_matches:{local['unique_matches']} local_match_ratio:{local['match_ratio']:.6f} "
            f"local_mad:{local_mad_text} host_duplicate_ratio:{local['host_duplicate_ratio']:.6f} "
            f"quest_duplicate_ratio:{local['quest_duplicate_ratio']:.6f} local_quest_offset:{local['local_offset']:.9f} "
            f"baseline_packets:{baseline} baseline_trace:{baseline_trace} baseline_trace_ratio:{baseline_ratio:.6f} "
            f"missing_at_wlan:{missing} missing_seen_in_driver:{missing_trace} missing_driver_ratio:{missing_ratio_text} "
            f"decisive:{str(good).lower()}"
        )
    for i, note in enumerate(notes, 1):
        lines.append(f"radio_note_{i}={note}")
    lines.append(f"radio_decision_capable={'true' if decision_capable else 'false'}")
    lines.append(f"radio_classification={classification}")
    for i, blocker in enumerate(blockers, 1):
        lines.append(f"radio_decision_blocker_{i}={blocker}")

    out = src / "radio-attribution-summary.txt"
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
