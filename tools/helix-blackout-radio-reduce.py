#!/usr/bin/env python3
import argparse
import collections
import importlib.util
import math
import re
import statistics
import struct
import tarfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
BASE_PATH = HERE / "helix-blackout-reduce.py"
spec = importlib.util.spec_from_file_location("helix_blackout_base_reduce", BASE_PATH)
base = importlib.util.module_from_spec(spec)
spec.loader.exec_module(base)

TRACE_RE = re.compile(r"\s(?P<ts>\d+\.\d+):\s+(?:wlan:)?dp_rx_udp_pkt:\s+(?P<body>.*)$")
FIELD_RE = re.compile(r"\b(?P<name>ip_id|srcport|dstport)=(?P<value>0x[0-9a-fA-F]+|\d+)")
MARKER_PAYLOAD_PREFIX = b"helix-radio-sync:"
MARKER_PORT_BASE = 65000
MARKER_PORT_COUNT = 200
MIN_SYNC_POINTS = 3
MAX_SYNC_RESIDUAL_SECONDS = 0.010
MIN_CONTROL_MATCH_RATIO = 0.90
MAX_KEY_DUPLICATE_RATIO = 0.005
EVENT_PAD_SECONDS = 0.005
CONTROL_PAD_SECONDS = 1.0
MARKER_BRACKET_SECONDS = 15.0


def parse_int(raw):
    return int(raw, 16) if raw.lower().startswith("0x") else int(raw)


def parse_ipv4_udp(frame: bytes, host_ip: str, quest_ip: str):
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
    srcport = int.from_bytes(frame[udp:udp + 2], "big")
    dstport = int.from_bytes(frame[udp + 2:udp + 4], "big")
    udp_len = int.from_bytes(frame[udp + 4:udp + 6], "big")
    payload_end = min(len(frame), udp + max(8, udp_len))
    payload = bytes(frame[udp + 8:payload_end])
    return ip_id, srcport, dstport, payload


def pcap_packets(path: Path, host_ip: str, quest_ip: str):
    out = []
    for ts, frame, *_ in base.iter_pcap(path):
        parsed = parse_ipv4_udp(frame, host_ip, quest_ip)
        if parsed is None:
            continue
        ip_id, srcport, dstport, payload = parsed
        out.append((ts, (ip_id, srcport, dstport), payload))
    return out


def trace_packets(path: Path):
    out = []
    malformed = 0
    for line in path.read_text(errors="replace").splitlines():
        m = TRACE_RE.search(line)
        if not m:
            continue
        fields = {x.group("name"): parse_int(x.group("value")) for x in FIELD_RE.finditer(m.group("body"))}
        if not all(k in fields for k in ("ip_id", "srcport", "dstport")):
            malformed += 1
            continue
        out.append((float(m.group("ts")), (fields["ip_id"], fields["srcport"], fields["dstport"])))
    return out, malformed


def marker_seq(dstport: int):
    seq = dstport - MARKER_PORT_BASE
    return seq if 0 <= seq < MARKER_PORT_COUNT else None


def fit_trace_to_quest(trace, quest):
    quest_markers = {}
    marker_srcports = set()
    for ts, key, payload in quest:
        _ip_id, srcport, dstport = key
        seq = marker_seq(dstport)
        if seq is None or not payload.startswith(MARKER_PAYLOAD_PREFIX):
            continue
        try:
            payload_seq = int(payload[len(MARKER_PAYLOAD_PREFIX):].split(b"\x00", 1)[0])
        except ValueError:
            continue
        if payload_seq != seq:
            continue
        quest_markers[seq] = ts
        marker_srcports.add(srcport)
    if not marker_srcports:
        raise ValueError("no Quest-PCAP radio synchronization markers were found")

    trace_markers = {}
    for ts, key in trace:
        _ip_id, srcport, dstport = key
        seq = marker_seq(dstport)
        if seq is None or srcport not in marker_srcports:
            continue
        trace_markers.setdefault(seq, ts)

    shared = sorted(set(quest_markers) & set(trace_markers))
    if len(shared) < MIN_SYNC_POINTS:
        raise ValueError(f"only {len(shared)} shared trace/Quest-PCAP synchronization markers were retained")
    xs = [trace_markers[s] for s in shared]
    ys = [quest_markers[s] for s in shared]
    xbar = statistics.mean(xs)
    ybar = statistics.mean(ys)
    denom = sum((x - xbar) ** 2 for x in xs)
    if denom <= 0:
        raise ValueError("trace synchronization markers do not span time")
    slope = sum((x - xbar) * (y - ybar) for x, y in zip(xs, ys)) / denom
    intercept = ybar - slope * xbar
    residuals = [y - (intercept + slope * x) for x, y in zip(xs, ys)]
    residual_mad = statistics.median(abs(r - statistics.median(residuals)) for r in residuals)
    residual_max = max(abs(r) for r in residuals)
    return intercept, slope, residual_mad, residual_max, shared, quest_markers


def in_window(ts, start, end):
    return start <= ts <= end


def key_counter(records, start, end):
    return collections.Counter(key for ts, key, *rest in records if in_window(ts, start, end))


def duplicate_ratio(counter):
    total = sum(counter.values())
    return (total - len(counter)) / total if total else 1.0


def counter_match(a, b):
    matched = sum((a & b).values())
    total = sum(a.values())
    return matched, total, (matched / total if total else 0.0)


def append_summary(path: Path, lines):
    existing = path.read_text(errors="replace") if path.exists() else ""
    if existing and not existing.endswith("\n"):
        existing += "\n"
    path.write_text(existing + "\n".join(lines) + "\n")


def rebuild_archive(reduced: Path):
    archive = reduced.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz", compresslevel=6) as tar:
        tar.add(reduced, arcname=reduced.name)
    return archive


def main():
    ap = argparse.ArgumentParser(description="Validate and correlate Quest WLAN dp_rx_udp_pkt trace with Helix blackout captures.")
    ap.add_argument("capture_dir", type=Path)
    args = ap.parse_args()
    src = args.capture_dir.expanduser().resolve()
    reduced = src.with_name(src.name + "-reduced")
    summary_path = reduced / "reduction-summary.txt"
    metadata = base.read_metadata(src / "metadata.txt")
    blockers = []

    required = {
        "host.pcap": src / "host.pcap",
        "quest.pcap": src / "quest.pcap",
        "server-log.txt": src / "server-log.txt",
        "quest-wlan-dp-rx-udp.trace": src / "quest-wlan-dp-rx-udp.trace",
        "quest-wlan-dp-rx-udp-format.txt": src / "quest-wlan-dp-rx-udp-format.txt",
        "quest-wlan-trace-stats.txt": src / "quest-wlan-trace-stats.txt",
        "trace-sync-host.txt": src / "trace-sync-host.txt",
    }
    for name, path in required.items():
        if not path.exists() or path.stat().st_size == 0:
            blockers.append(f"missing or empty {name}")
    if blockers:
        append_summary(summary_path, ["radio_decision_capable=false"] + [f"radio_decision_blocker_{i+1}={x}" for i, x in enumerate(blockers)])
        archive = rebuild_archive(reduced)
        print("Radio decision gate: NON-DECISIVE — required trace evidence is missing.")
        print(f"Reduced bundle: {archive}")
        return 2

    trace_format = required["quest-wlan-dp-rx-udp-format.txt"].read_text(errors="replace")
    for field in ("ip_id", "srcport", "dstport"):
        if field not in trace_format:
            blockers.append(f"trace format lacks required field {field}")

    host_ip = metadata.get("host_ip", "")
    quest_ip = metadata.get("quest_ip", "")
    if not host_ip or not quest_ip:
        blockers.append("metadata lacks host_ip or quest_ip")

    trace, malformed = trace_packets(required["quest-wlan-dp-rx-udp.trace"])
    host = pcap_packets(required["host.pcap"], host_ip, quest_ip) if host_ip and quest_ip else []
    quest = pcap_packets(required["quest.pcap"], host_ip, quest_ip) if host_ip and quest_ip else []
    if not trace:
        blockers.append("driver trace contains no parseable dp_rx_udp_pkt events")

    sync = None
    if trace and quest:
        try:
            sync = fit_trace_to_quest(trace, quest)
        except ValueError as e:
            blockers.append(str(e))
    if sync is not None:
        intercept, slope, sync_mad, sync_max, shared_markers, quest_markers = sync
        if sync_max > MAX_SYNC_RESIDUAL_SECONDS:
            blockers.append(f"trace/Quest-PCAP synchronization max residual {sync_max:.6f}s exceeds {MAX_SYNC_RESIDUAL_SECONDS:.3f}s")
    else:
        intercept = slope = sync_mad = sync_max = None
        shared_markers = []
        quest_markers = {}

    tz = base.parse_offset(metadata.get("host_tz_offset", ""))
    start_ns = base.epoch_ns(metadata, "capture_start_epoch_ns")
    end_ns = base.epoch_ns(metadata, "capture_end_epoch_ns")
    events = base.parse_events(
        required["server-log.txt"], tz,
        start_ns / 1e9 if start_ns is not None else None,
        end_ns / 1e9 if end_ns is not None else None,
    )
    events = [e for e in events if e["first_send_epoch"] is not None and e["last_send_epoch"] is not None]
    if not events:
        blockers.append("no fully mapped current-run Helix gap events are available for radio attribution")

    coarse_offset = None
    if host and quest:
        try:
            coarse_offset, _coarse_mad, _coarse_matches = base.derive_quest_clock_offset(required["host.pcap"], required["quest.pcap"], host_ip, quest_ip)
        except SystemExit as e:
            blockers.append(f"host/Quest packet-clock alignment failed: {e}")

    event_lines = []
    if sync is not None and coarse_offset is not None:
        trace_quest = [(intercept + slope * ts, key) for ts, key in trace]
        marker_times = sorted(quest_markers.values())
        for idx, event in enumerate(events, 1):
            control_host_start = event["first_send_epoch"] - CONTROL_PAD_SECONDS
            control_host_end = event["last_send_epoch"] + CONTROL_PAD_SECONDS
            coarse_q_start = control_host_start + coarse_offset - base.LOCAL_SEARCH_SLACK
            coarse_q_end = control_host_end + coarse_offset + base.LOCAL_SEARCH_SLACK
            host_control = [(ts, key) for ts, key, _payload in host if control_host_start <= ts <= control_host_end]
            quest_control = [(ts, key) for ts, key, _payload in quest if coarse_q_start <= ts <= coarse_q_end]
            hfp = collections.Counter(key for _ts, key in host_control)
            qfp = collections.Counter(key for _ts, key in quest_control)
            shared_keys = set(k for k, v in hfp.items() if v == 1) & set(k for k, v in qfp.items() if v == 1)
            deltas = []
            host_unique_time = {key: ts for ts, key in host_control if hfp[key] == 1}
            quest_unique_time = {key: ts for ts, key in quest_control if qfp[key] == 1}
            for key in shared_keys:
                deltas.append(quest_unique_time[key] - host_unique_time[key])
            if len(deltas) < base.MIN_LOCAL_UNIQUE_MATCHES:
                blockers.append(f"event {idx}: only {len(deltas)} unique local host/Quest matches")
                continue
            local_offset = statistics.median(deltas)
            local_mad = statistics.median(abs(d - local_offset) for d in deltas)
            if local_mad > base.MAX_LOCAL_MAD_SECONDS:
                blockers.append(f"event {idx}: local host/Quest timing MAD {local_mad:.6f}s is too large")
                continue

            q_event_start = event["first_send_epoch"] + local_offset - EVENT_PAD_SECONDS
            q_event_end = event["last_send_epoch"] + local_offset + EVENT_PAD_SECONDS
            before = [t for t in marker_times if t <= q_event_start]
            after = [t for t in marker_times if t >= q_event_end]
            if not before or not after or q_event_start - before[-1] > MARKER_BRACKET_SECONDS or after[0] - q_event_end > MARKER_BRACKET_SECONDS:
                blockers.append(f"event {idx}: no retained synchronization markers bracket the event within {MARKER_BRACKET_SECONDS:g}s")
                continue

            host_event = collections.Counter(key for ts, key, _payload in host if event["first_send_epoch"] - EVENT_PAD_SECONDS <= ts <= event["last_send_epoch"] + EVENT_PAD_SECONDS)
            quest_event = collections.Counter(key for ts, key, _payload in quest if q_event_start <= ts <= q_event_end)
            trace_event = collections.Counter(key for ts, key in trace_quest if q_event_start <= ts <= q_event_end)
            trace_control = collections.Counter(key for ts, key in trace_quest if control_host_start + local_offset <= ts <= control_host_end + local_offset)
            quest_control_exact = collections.Counter(key for ts, key, _payload in quest if control_host_start + local_offset <= ts <= control_host_end + local_offset)

            if duplicate_ratio(host_event) > MAX_KEY_DUPLICATE_RATIO:
                blockers.append(f"event {idx}: host driver-correlation key duplicate ratio {duplicate_ratio(host_event):.6f} is too high")
            q_trace_match, q_trace_total, q_trace_ratio = counter_match(quest_control_exact, trace_control)
            if q_trace_ratio < MIN_CONTROL_MATCH_RATIO:
                blockers.append(f"event {idx}: surrounding Quest-PCAP -> driver-trace match ratio {q_trace_ratio:.3f} < {MIN_CONTROL_MATCH_RATIO:.2f}")

            host_trace_match = sum((host_event & trace_event).values())
            host_quest_match = sum((host_event & quest_event).values())
            driver_only = sum(((host_event & trace_event) - quest_event).values())
            missing_both = sum((host_event - trace_event - quest_event).values())
            event_lines.append(
                f"radio_event_{idx}=host:{sum(host_event.values())} driver:{host_trace_match} quest:{host_quest_match} "
                f"driver_present_quest_absent:{driver_only} absent_driver_and_quest:{missing_both} "
                f"quest_to_trace_control:{q_trace_match}/{q_trace_total} local_offset:{local_offset:.9f} local_mad:{local_mad:.9f}"
            )

    base_summary = base.read_metadata(summary_path)
    if base_summary.get("decision_capable") != "true":
        blockers.append("base paired-PCAP decision gate did not pass")

    radio_capable = not blockers and len(event_lines) == len(events) and len(events) > 0
    lines = [
        f"radio_trace_events_parsed={len(trace)}",
        f"radio_trace_events_malformed={malformed}",
        f"radio_sync_points={len(shared_markers)}",
        f"radio_sync_slope={slope}",
        f"radio_sync_mad_seconds={sync_mad}",
        f"radio_sync_max_residual_seconds={sync_max}",
    ]
    lines.extend(event_lines)
    lines.append(f"radio_decision_capable={'true' if radio_capable else 'false'}")
    for i, reason in enumerate(blockers, 1):
        lines.append(f"radio_decision_blocker_{i}={reason}")
    append_summary(summary_path, lines)
    archive = rebuild_archive(reduced)

    if radio_capable:
        print("Radio decision gate: PASS — Quest WLAN driver trace, Quest wlan0 capture, and host capture are synchronized and locally cross-checked.")
    else:
        print("Radio decision gate: NON-DECISIVE — evidence preserved; see radio_decision_blocker_* in reduction-summary.txt.")
    print(f"Reduced bundle: {archive}")
    return 0 if radio_capable else 2


if __name__ == "__main__":
    raise SystemExit(main())
