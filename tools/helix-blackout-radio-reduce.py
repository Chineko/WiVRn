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
TRACE_ALIGN_MIN_MATCHES = 100
TRACE_ALIGN_MAX_MAD = 0.010
TRACE_LOOKUP_SLOP = 0.020
QUEST_LOOKUP_SLOP = 0.100
MIN_BASELINE_PACKETS = 50
MIN_BASELINE_TRACE_RATIO = 0.90
MIN_MISSING_PACKETS = 10
DRIVER_PRESENT_DECISIVE_RATIO = 0.80
DRIVER_ABSENT_DECISIVE_RATIO = 0.10


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


def signature_map(records):
    result = collections.defaultdict(list)
    for i in range(1, len(records) - 1):
        sig = (records[i - 1][1], records[i][1], records[i + 1][1])
        result[sig].append(records[i][0])
    return result


def align_trace_to_quest(trace_records, quest_pcap, host_ip, quest_ip):
    trace_sigs = signature_map(trace_records)
    wanted = set(trace_sigs)
    quest_matches = collections.defaultdict(list)
    prev2 = prev1 = None
    for ts, frame, *_ in base.iter_pcap(quest_pcap):
        key = driver_key(frame, host_ip, quest_ip)
        if key is None:
            continue
        cur = (ts, key)
        if prev2 is not None and prev1 is not None:
            sig = (prev2[1], prev1[1], cur[1])
            if sig in wanted:
                quest_matches[sig].append(prev1[0])
        prev2, prev1 = prev1, cur

    offsets = []
    for sig, trace_times in trace_sigs.items():
        quest_times = quest_matches.get(sig, ())
        if len(trace_times) == 1 and len(quest_times) == 1:
            offsets.append(quest_times[0] - trace_times[0])
    if len(offsets) < TRACE_ALIGN_MIN_MATCHES:
        return None, None, len(offsets)
    offset = statistics.median(offsets)
    mad = statistics.median(abs(x - offset) for x in offsets)
    return offset, mad, len(offsets)


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

    trace_records = parse_trace(trace_path) if trace_path.exists() else []
    if not trace_records:
        blockers.append("no_parseable_dp_rx_udp_pkt_records")

    tz = base.parse_offset(metadata.get("host_tz_offset", ""))
    capture_start_ns = base.epoch_ns(metadata, "capture_start_epoch_ns")
    capture_end_ns = base.epoch_ns(metadata, "capture_end_epoch_ns")
    capture_start = capture_start_ns / 1e9 if capture_start_ns is not None else None
    capture_end = capture_end_ns / 1e9 if capture_end_ns is not None else None
    events = base.parse_events(server_log, tz, capture_start, capture_end) if server_log.exists() else []
    mapped_events = [e for e in events if e["first_send_epoch"] is not None and e["last_send_epoch"] is not None]
    if not mapped_events:
        blockers.append("no_fully_mapped_gap_events")

    trace_offset = trace_mad = None
    trace_align_matches = 0
    quest_offset = None
    if not blockers or all(x.startswith("trace_format_missing:") is False for x in blockers):
        if trace_records and quest_pcap.exists() and host_ip and quest_ip:
            trace_offset, trace_mad, trace_align_matches = align_trace_to_quest(trace_records, quest_pcap, host_ip, quest_ip)
            if trace_offset is None:
                blockers.append(f"trace_alignment_matches:{trace_align_matches}<{TRACE_ALIGN_MIN_MATCHES}")
            elif trace_mad is None or trace_mad > TRACE_ALIGN_MAX_MAD:
                blockers.append(f"trace_alignment_mad:{trace_mad}")
        if host_pcap.exists() and quest_pcap.exists() and host_ip and quest_ip:
            try:
                quest_offset, _qmad, _qm = base.derive_quest_clock_offset(host_pcap, quest_pcap, host_ip, quest_ip)
            except SystemExit as exc:
                blockers.append(f"quest_pcap_alignment:{exc}")

    overruns, dropped = trace_stats(stats_path)
    if dropped and any(x != 0 for x in dropped):
        blockers.append("trace_buffer_reported_dropped_events")

    event_results = []
    if trace_offset is not None and quest_offset is not None:
        trace_times_by_key = collections.defaultdict(list)
        for ts, key in trace_records:
            trace_times_by_key[key].append(ts)

        mapped_trace_first = trace_records[0][0] + trace_offset
        mapped_trace_last = trace_records[-1][0] + trace_offset

        for idx, event in enumerate(mapped_events, 1):
            start = event["first_send_epoch"] - 0.005
            end = event["last_send_epoch"] + 0.005
            if start < mapped_trace_first - 0.020 or end > mapped_trace_last + 0.020:
                blockers.append(f"event_{idx}:outside_retained_driver_trace")
                continue

            host_rows = collect_pcap_window(host_pcap, start, end, host_ip, quest_ip)
            quest_rows = collect_pcap_window(
                quest_pcap,
                start + quest_offset - QUEST_LOOKUP_SLOP,
                end + quest_offset + QUEST_LOOKUP_SLOP,
                host_ip,
                quest_ip,
            )
            quest_fp_times = collections.defaultdict(list)
            for qts, fp, _key in quest_rows:
                quest_fp_times[fp].append(qts)

            baseline = baseline_trace = missing = missing_trace = 0
            for hts, fp, key in host_rows:
                predicted_q = hts + quest_offset
                q_present = has_time(quest_fp_times.get(fp), predicted_q, QUEST_LOOKUP_SLOP)
                predicted_trace = predicted_q - trace_offset
                t_present = has_time(trace_times_by_key.get(key), predicted_trace, TRACE_LOOKUP_SLOP)
                if q_present:
                    baseline += 1
                    baseline_trace += int(t_present)
                else:
                    missing += 1
                    missing_trace += int(t_present)

            baseline_ratio = baseline_trace / baseline if baseline else 0.0
            missing_trace_ratio = missing_trace / missing if missing else None
            event_results.append((idx, baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_trace_ratio))
            if baseline < MIN_BASELINE_PACKETS:
                blockers.append(f"event_{idx}:driver_baseline_packets:{baseline}<{MIN_BASELINE_PACKETS}")
            elif baseline_ratio < MIN_BASELINE_TRACE_RATIO:
                blockers.append(f"event_{idx}:driver_baseline_ratio:{baseline_ratio:.3f}<{MIN_BASELINE_TRACE_RATIO:.2f}")
            if missing < MIN_MISSING_PACKETS:
                blockers.append(f"event_{idx}:quest_missing_packets:{missing}<{MIN_MISSING_PACKETS}")

    decisive_results = [r for r in event_results if r[1] >= MIN_BASELINE_PACKETS and r[3] >= MIN_BASELINE_TRACE_RATIO and r[4] >= MIN_MISSING_PACKETS]
    classification = "non_decisive"
    if decisive_results and not blockers:
        ratios = [r[6] for r in decisive_results if r[6] is not None]
        if ratios and all(r >= DRIVER_PRESENT_DECISIVE_RATIO for r in ratios):
            classification = "quest_lower_receive_path_after_dp_rx_udp_pkt"
        elif ratios and all(r <= DRIVER_ABSENT_DECISIVE_RATIO for r in ratios):
            classification = "before_dp_rx_udp_pkt_ap_rf_radio_firmware_or_earlier_driver"
        else:
            classification = "mixed_driver_visibility"

    lines = [
        f"source={src}",
        f"trace_event=wlan:dp_rx_udp_pkt",
        f"trace_records={len(trace_records)}",
        f"trace_to_quest_pcap_offset_seconds={trace_offset}",
        f"trace_alignment_mad_seconds={trace_mad}",
        f"trace_alignment_unique_triples={trace_align_matches}",
        f"trace_overrun_samples={','.join(map(str, overruns)) if overruns else 'unavailable'}",
        f"trace_dropped_samples={','.join(map(str, dropped)) if dropped else 'unavailable'}",
        f"mapped_gap_events={len(mapped_events)}",
    ]
    for idx, baseline, baseline_trace, baseline_ratio, missing, missing_trace, missing_ratio in event_results:
        lines.append(
            f"event_{idx}=baseline_packets:{baseline} baseline_trace:{baseline_trace} baseline_ratio:{baseline_ratio:.6f} "
            f"missing_at_wlan:{missing} missing_seen_in_driver:{missing_trace} "
            f"missing_driver_ratio:{'unavailable' if missing_ratio is None else f'{missing_ratio:.6f}'}"
        )
    lines.append(f"radio_decision_capable={'true' if not blockers and classification != 'non_decisive' else 'false'}")
    lines.append(f"radio_classification={classification}")
    for i, blocker in enumerate(blockers, 1):
        lines.append(f"radio_decision_blocker_{i}={blocker}")

    out = src / "radio-attribution-summary.txt"
    out.write_text("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main()
