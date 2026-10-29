#!/usr/bin/env python3
import argparse
import collections
import datetime as dt
import ipaddress
import re
import shutil
import statistics
import struct
import tarfile
from pathlib import Path

GAP_RE = re.compile(
    r"^\[(?P<ts>\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)\].*"
    r"Helix gap timing event stream=(?P<stream>\d+) first=(?P<first>\d+) count=(?P<count>\d+) "
    r"exposing_sequence=(?P<exposing>\d+) exposing_frame=(?P<frame>\d+) "
    r"mapping=(?P<mapping>\w+) mapped=(?P<mapped>\d+) send_span=(?P<span>\d+)us "
    r"distinct_frames=(?P<frames>\d+) report_delay=(?P<delay>\d+)us"
)

LOCAL_SEARCH_SLACK = 0.250
MIN_LOCAL_MATCH_RATIO = 0.90
MAX_DUPLICATE_RATIO = 0.005
MAX_LOCAL_MAD_SECONDS = 0.010
MIN_LOCAL_UNIQUE_MATCHES = 50


def read_metadata(path: Path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            values[key] = value
    return values


def parse_offset(raw: str):
    if not raw or not re.fullmatch(r"[+-]\d{4}", raw):
        return None
    sign = 1 if raw[0] == "+" else -1
    return dt.timezone(sign * dt.timedelta(hours=int(raw[1:3]), minutes=int(raw[3:5])))


def epoch_ns(metadata, key):
    raw = metadata.get(key, "")
    return int(raw) if raw.isdigit() else None


def parse_events(server_log: Path, tz, capture_start, capture_end):
    events = []
    for line in server_log.read_text(errors="replace").splitlines():
        m = GAP_RE.search(line)
        if not m:
            continue
        local = dt.datetime.fromisoformat(m.group("ts"))
        if tz is not None:
            local = local.replace(tzinfo=tz)
        else:
            local = local.astimezone()
        report_epoch = local.timestamp()
        if capture_start is not None and report_epoch < capture_start - 1.0:
            continue
        if capture_end is not None and report_epoch > capture_end + 1.0:
            continue
        event = {
            "report_epoch": report_epoch,
            "stream": int(m.group("stream")),
            "first": int(m.group("first")),
            "count": int(m.group("count")),
            "exposing": int(m.group("exposing")),
            "frame": int(m.group("frame")),
            "mapping": m.group("mapping"),
            "mapped": int(m.group("mapped")),
            "span_us": int(m.group("span")),
            "frames": int(m.group("frames")),
            "delay_us": int(m.group("delay")),
        }
        if event["mapping"] == "full" and event["mapped"] == event["count"]:
            event["last_send_epoch"] = report_epoch - event["delay_us"] / 1_000_000.0
            event["first_send_epoch"] = event["last_send_epoch"] - event["span_us"] / 1_000_000.0
        else:
            event["first_send_epoch"] = None
            event["last_send_epoch"] = None
        events.append(event)
    return events


def merge_windows(windows):
    merged = []
    for start, end in sorted(windows):
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


def event_windows(events, pad, fallback_radius):
    windows = []
    for e in events:
        if e["first_send_epoch"] is not None:
            windows.append((e["first_send_epoch"] - pad, e["last_send_epoch"] + pad))
        else:
            windows.append((e["report_epoch"] - fallback_radius, e["report_epoch"] + fallback_radius))
    return merge_windows(windows)


def pcap_info(header: bytes):
    if len(header) != 24:
        raise ValueError("truncated PCAP global header")
    magic = header[:4]
    formats = {
        b"\xd4\xc3\xb2\xa1": ("<", 1_000_000),
        b"\xa1\xb2\xc3\xd4": (">", 1_000_000),
        b"\x4d\x3c\xb2\xa1": ("<", 1_000_000_000),
        b"\xa1\xb2\x3c\x4d": (">", 1_000_000_000),
    }
    if magic not in formats:
        raise ValueError(f"unsupported capture format/magic {magic.hex()} (expected classic PCAP)")
    endian, scale = formats[magic]
    raw_linktype = struct.unpack(endian + "I", header[20:24])[0]
    linktype = raw_linktype & 0xFFFF
    return endian, scale, linktype


def iter_pcap(path: Path):
    with path.open("rb") as fin:
        global_header = fin.read(24)
        endian, scale, linktype = pcap_info(global_header)
        packet_header = struct.Struct(endian + "IIII")
        while True:
            raw = fin.read(16)
            if not raw:
                break
            if len(raw) != 16:
                raise ValueError(f"truncated packet header in {path}")
            sec, frac, incl_len, orig_len = packet_header.unpack(raw)
            payload = fin.read(incl_len)
            if len(payload) != incl_len:
                raise ValueError(f"truncated packet payload in {path}")
            yield sec + frac / scale, payload, raw, orig_len, global_header, linktype


def udp_fingerprint(frame: bytes, host_ip: str, quest_ip: str):
    if len(frame) < 14:
        return None
    offset = 14
    ethertype = int.from_bytes(frame[12:14], "big")
    while ethertype in (0x8100, 0x88A8):
        if len(frame) < offset + 4:
            return None
        ethertype = int.from_bytes(frame[offset + 2:offset + 4], "big")
        offset += 4

    if ethertype == 0x0800:
        if len(frame) < offset + 20:
            return None
        ihl = (frame[offset] & 0x0F) * 4
        if ihl < 20 or len(frame) < offset + ihl + 8 or frame[offset + 9] != 17:
            return None
        src = str(ipaddress.IPv4Address(frame[offset + 12:offset + 16]))
        dst = str(ipaddress.IPv4Address(frame[offset + 16:offset + 20]))
        udp = offset + ihl
    elif ethertype == 0x86DD:
        if len(frame) < offset + 48 or frame[offset + 6] != 17:
            return None
        src = str(ipaddress.IPv6Address(frame[offset + 8:offset + 24]))
        dst = str(ipaddress.IPv6Address(frame[offset + 24:offset + 40]))
        udp = offset + 40
    else:
        return None

    if src != host_ip or dst != quest_ip or len(frame) < udp + 9:
        return None
    src_port = int.from_bytes(frame[udp:udp + 2], "big")
    dst_port = int.from_bytes(frame[udp + 2:udp + 4], "big")
    udp_len = int.from_bytes(frame[udp + 4:udp + 6], "big")
    prefix = bytes(frame[udp + 8:udp + 40])
    if not prefix:
        return None
    return src_port, dst_port, udp_len, prefix


def derive_quest_clock_offset(host_pcap: Path, quest_pcap: Path, host_ip: str, quest_ip: str, max_host_samples=50000, target_matches=1000):
    with host_pcap.open("rb") as f:
        _e, _s, host_linktype = pcap_info(f.read(24))
    with quest_pcap.open("rb") as f:
        _e, _s, quest_linktype = pcap_info(f.read(24))
    if host_linktype != 1 or quest_linktype != 1:
        raise SystemExit(f"Packet clock alignment expects Ethernet captures (DLT_EN10MB=1), got host={host_linktype} quest={quest_linktype}")

    host = {}
    for ts, frame, *_ in iter_pcap(host_pcap):
        fp = udp_fingerprint(frame, host_ip, quest_ip)
        if fp is None:
            continue
        host.setdefault(fp, ts)
        if len(host) >= max_host_samples:
            break
    if not host:
        raise SystemExit("Could not fingerprint any PC->Quest UDP packets in host.pcap")

    deltas = []
    seen = set()
    for qts, frame, *_ in iter_pcap(quest_pcap):
        fp = udp_fingerprint(frame, host_ip, quest_ip)
        if fp is None or fp in seen:
            continue
        hts = host.get(fp)
        if hts is None:
            continue
        seen.add(fp)
        deltas.append(qts - hts)
        if len(deltas) >= target_matches:
            break
    if len(deltas) < 50:
        raise SystemExit(f"Only {len(deltas)} identical UDP packets could be matched between host and Quest captures; cannot align clocks reliably")

    median = statistics.median(deltas)
    mad = statistics.median(abs(x - median) for x in deltas)
    return median, mad, len(deltas)


def collect_window_packets(path, windows, host_ip, quest_ip):
    buckets = [[] for _ in windows]
    for ts, frame, *_ in iter_pcap(path):
        fp = udp_fingerprint(frame, host_ip, quest_ip)
        if fp is None:
            continue
        for i, (start, end) in enumerate(windows):
            if start <= ts <= end:
                buckets[i].append((ts, fp))
                break
    return buckets


def correlate_window(host_records, quest_records, coarse_offset):
    host_counter = collections.Counter(fp for _, fp in host_records)
    quest_counter = collections.Counter(fp for _, fp in quest_records)
    matched = sum((host_counter & quest_counter).values())
    host_total = len(host_records)
    quest_total = len(quest_records)
    host_dup_ratio = (host_total - len(host_counter)) / host_total if host_total else 1.0
    quest_dup_ratio = (quest_total - len(quest_counter)) / quest_total if quest_total else 1.0

    host_unique = {fp: ts for ts, fp in host_records if host_counter[fp] == 1}
    quest_unique = {fp: ts for ts, fp in quest_records if quest_counter[fp] == 1}
    shared = host_unique.keys() & quest_unique.keys()
    deltas = [quest_unique[fp] - host_unique[fp] for fp in shared]
    if deltas:
        local_offset = statistics.median(deltas)
        local_mad = statistics.median(abs(x - local_offset) for x in deltas)
    else:
        local_offset = coarse_offset
        local_mad = None

    return {
        "host_total": host_total,
        "quest_total": quest_total,
        "matched": matched,
        "match_ratio": matched / host_total if host_total else 0.0,
        "host_duplicate_ratio": host_dup_ratio,
        "quest_duplicate_ratio": quest_dup_ratio,
        "unique_matches": len(deltas),
        "local_offset": local_offset,
        "local_mad": local_mad,
    }


def in_windows(ts: float, windows):
    return any(start <= ts <= end for start, end in windows)


def trim_pcap(src: Path, dst: Path, windows):
    kept = total = 0
    first_ts = last_ts = None
    with src.open("rb") as fin, dst.open("wb") as fout:
        global_header = fin.read(24)
        endian, scale, linktype = pcap_info(global_header)
        fout.write(global_header)
        packet_header = struct.Struct(endian + "IIII")
        while True:
            raw = fin.read(16)
            if not raw:
                break
            if len(raw) != 16:
                raise ValueError(f"truncated packet header in {src}")
            sec, frac, incl_len, _orig_len = packet_header.unpack(raw)
            payload = fin.read(incl_len)
            if len(payload) != incl_len:
                raise ValueError(f"truncated packet payload in {src}")
            ts = sec + frac / scale
            if first_ts is None:
                first_ts = ts
            last_ts = ts
            total += 1
            if in_windows(ts, windows):
                fout.write(raw)
                fout.write(payload)
                kept += 1
    return {"total": total, "kept": kept, "first": first_ts, "last": last_ts, "linktype": linktype}


def tcpdump_kernel_drops(path: Path):
    if not path.exists():
        return None
    matches = re.findall(r"(\d+) packets dropped by kernel", path.read_text(errors="replace"))
    return int(matches[-1]) if matches else None


def newest_capture_dir(home: Path):
    candidates = [
        p for p in home.glob("helix-blackout-*")
        if p.is_dir() and (p / "server-log.txt").exists() and not p.name.endswith("-reduced")
    ]
    if not candidates:
        raise SystemExit("No ~/helix-blackout-* capture directory containing server-log.txt was found.")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def fmt_epoch(value, tz):
    return dt.datetime.fromtimestamp(value, tz).isoformat(timespec="milliseconds")


def main():
    parser = argparse.ArgumentParser(description="Reduce a Helix blackout capture to decision-relevant packet windows.")
    parser.add_argument("capture_dir", nargs="?", type=Path, help="capture directory; defaults to newest ~/helix-blackout-* directory")
    parser.add_argument("--pad", type=float, default=1.0, help="seconds retained before/after each reconstructed sender loss interval (default: 1)")
    parser.add_argument("--fallback-radius", type=float, default=3.0, help="seconds around report time for partial/unmapped gaps (default: 3)")
    parser.add_argument("--allow-missing-capture", action="store_true", help="permit historical runs with a missing host or Quest PCAP")
    args = parser.parse_args()

    src = (args.capture_dir or newest_capture_dir(Path.home())).expanduser().resolve()
    server_log = src / "server-log.txt"
    if not server_log.exists():
        raise SystemExit(f"missing {server_log}")

    metadata = read_metadata(src / "metadata.txt")
    tz = parse_offset(metadata.get("host_tz_offset", ""))
    capture_start_ns = epoch_ns(metadata, "capture_start_epoch_ns")
    capture_end_ns = epoch_ns(metadata, "capture_end_epoch_ns")
    capture_start = capture_start_ns / 1e9 if capture_start_ns is not None else None
    capture_end = capture_end_ns / 1e9 if capture_end_ns is not None else None

    events = parse_events(server_log, tz, capture_start, capture_end)
    if not events:
        raise SystemExit("No current-run 'Helix gap timing event' lines found; the blackout was not reproduced, so there is nothing decision-relevant to reduce.")
    host_windows = event_windows(events, args.pad, args.fallback_radius)

    host_pcap = src / "host.pcap"
    quest_pcap = src / "quest.pcap"
    missing = [name for name, p in (("host.pcap", host_pcap), ("quest.pcap", quest_pcap)) if not p.exists() or p.stat().st_size < 24]
    if missing and not args.allow_missing_capture:
        raise SystemExit("Missing decisive capture(s): " + ", ".join(missing) + ". Use --allow-missing-capture only for historical/non-decisive runs.")

    decision_reasons = []
    if metadata.get("wifi_endpoint_state_consistent") != "true":
        decision_reasons.append("Quest start/end BSSID or 6-GHz endpoint state differed or was unavailable")

    quest_offset = quest_mad = None
    alignment_matches = 0
    local_stats = []
    host_ip = metadata.get("host_ip", "")
    quest_ip = metadata.get("quest_ip", "")
    if not missing:
        if not host_ip or not quest_ip:
            raise SystemExit("metadata.txt lacks host_ip/quest_ip required for packet-based clock alignment")
        quest_offset, quest_mad, alignment_matches = derive_quest_clock_offset(host_pcap, quest_pcap, host_ip, quest_ip)

        quest_search_windows = [
            (start + quest_offset - LOCAL_SEARCH_SLACK, end + quest_offset + LOCAL_SEARCH_SLACK)
            for start, end in host_windows
        ]
        host_buckets = collect_window_packets(host_pcap, host_windows, host_ip, quest_ip)
        quest_buckets = collect_window_packets(quest_pcap, quest_search_windows, host_ip, quest_ip)

        quest_windows = []
        for i, ((start, end), host_records, quest_records) in enumerate(zip(host_windows, host_buckets, quest_buckets), 1):
            stats = correlate_window(host_records, quest_records, quest_offset)
            stats["index"] = i
            local_stats.append(stats)
            if stats["unique_matches"] < MIN_LOCAL_UNIQUE_MATCHES:
                decision_reasons.append(f"window {i}: only {stats['unique_matches']} unique local packet matches")
            if stats["match_ratio"] < MIN_LOCAL_MATCH_RATIO:
                decision_reasons.append(f"window {i}: surrounding PC->Quest match ratio {stats['match_ratio']:.3f} < {MIN_LOCAL_MATCH_RATIO:.2f}")
            if stats["host_duplicate_ratio"] > MAX_DUPLICATE_RATIO or stats["quest_duplicate_ratio"] > MAX_DUPLICATE_RATIO:
                decision_reasons.append(
                    f"window {i}: fingerprint duplicate ratio host={stats['host_duplicate_ratio']:.4f} quest={stats['quest_duplicate_ratio']:.4f}"
                )
            if stats["local_mad"] is None or stats["local_mad"] > MAX_LOCAL_MAD_SECONDS:
                decision_reasons.append(f"window {i}: local clock/capture timing spread is too large or unavailable")
            quest_windows.append((start + stats["local_offset"], end + stats["local_offset"]))
        quest_windows = merge_windows(quest_windows)
    else:
        quest_windows = host_windows

    out = src.with_name(src.name + "-reduced")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()

    for p in src.iterdir():
        if p.is_file() and p.suffix != ".pcap":
            shutil.copy2(p, out / p.name)

    display_tz = tz or dt.datetime.now().astimezone().tzinfo
    summary = [
        f"source={src}",
        f"attribution_scope={metadata.get('attribution_scope', 'unknown')}",
        f"gap_events_current_run={len(events)}",
        f"pad_seconds={args.pad}",
        f"fallback_radius_seconds={args.fallback_radius}",
        f"merged_host_windows={len(host_windows)}",
        f"host_tz_offset={metadata.get('host_tz_offset', 'legacy-local-time')}",
        f"quest_clock_offset_coarse_seconds={quest_offset}",
        f"quest_clock_alignment_coarse_mad_seconds={quest_mad}",
        f"quest_clock_alignment_coarse_matches={alignment_matches}",
    ]

    for i, stats in enumerate(local_stats, 1):
        summary.append(
            "local_window_%d=host_packets:%d quest_packets:%d matched:%d match_ratio:%.6f unique_matches:%d "
            "host_duplicate_ratio:%.6f quest_duplicate_ratio:%.6f local_offset:%.9f local_mad:%s" % (
                i,
                stats["host_total"], stats["quest_total"], stats["matched"], stats["match_ratio"],
                stats["unique_matches"], stats["host_duplicate_ratio"], stats["quest_duplicate_ratio"],
                stats["local_offset"], "unavailable" if stats["local_mad"] is None else f"{stats['local_mad']:.9f}",
            )
        )

    for i, e in enumerate(events, 1):
        summary.append(
            "event_%d=stream:%d first:%d count:%d mapping:%s mapped:%d span_us:%d delay_us:%d report:%s send:%s..%s" % (
                i, e["stream"], e["first"], e["count"], e["mapping"], e["mapped"], e["span_us"], e["delay_us"],
                fmt_epoch(e["report_epoch"], display_tz),
                fmt_epoch(e["first_send_epoch"], display_tz) if e["first_send_epoch"] is not None else "unknown",
                fmt_epoch(e["last_send_epoch"], display_tz) if e["last_send_epoch"] is not None else "unknown",
            )
        )
    for i, (start, end) in enumerate(host_windows, 1):
        summary.append(f"host_window_{i}={fmt_epoch(start, display_tz)}..{fmt_epoch(end, display_tz)}")

    for name, p, windows in (("host.pcap", host_pcap, host_windows), ("quest.pcap", quest_pcap, quest_windows)):
        if name in missing:
            summary.append(f"{name}=missing_or_empty")
            continue
        stats = trim_pcap(p, out / name, windows)
        summary.extend([
            f"{name}_packets_total={stats['total']}",
            f"{name}_packets_kept={stats['kept']}",
            f"{name}_bytes_reduced={(out / name).stat().st_size}",
            f"{name}_linktype={stats['linktype']}",
            f"{name}_first_epoch={stats['first']}",
            f"{name}_last_epoch={stats['last']}",
        ])
        if stats["total"] == 0:
            decision_reasons.append(f"{name} contains no packets")
        if stats["kept"] == 0:
            decision_reasons.append(f"{name} retained zero packets around decision windows")
        for start, end in windows:
            if stats["first"] is None or stats["last"] is None or start < stats["first"] - 0.050 or end > stats["last"] + 0.050:
                decision_reasons.append(f"{name} does not fully cover every decision window")
                break

    for label, stat_file in (("host", src / "host-tcpdump.txt"), ("quest", src / "quest-tcpdump.txt")):
        drops = tcpdump_kernel_drops(stat_file)
        summary.append(f"{label}_tcpdump_kernel_drops={drops}")
        if drops is None and not args.allow_missing_capture:
            decision_reasons.append(f"{label} tcpdump kernel-drop count is unavailable")
        elif drops not in (None, 0):
            decision_reasons.append(f"{label} tcpdump reports {drops} packets dropped by kernel")

    decision_capable = not decision_reasons and not missing
    summary.append(f"decision_capable={'true' if decision_capable else 'false'}")
    for i, reason in enumerate(decision_reasons, 1):
        summary.append(f"decision_blocker_{i}={reason}")

    (out / "reduction-summary.txt").write_text("\n".join(summary) + "\n")

    archive = out.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz", compresslevel=6) as tar:
        tar.add(out, arcname=out.name)

    print(f"Found {len(events)} current-run Helix gap event(s); retained reconstructed sender windows with ±{args.pad:g}s padding.")
    if quest_offset is not None:
        print(f"Coarse Quest alignment: {alignment_matches} identical UDP packets, offset {quest_offset:+.6f}s, MAD {quest_mad:.6f}s.")
        print(f"Local correlation checked independently for {len(local_stats)} blackout window(s).")
    if decision_capable:
        print("Decision gate: PASS — paired captures are suitable for host-capture -> Quest-wlan attribution.")
    else:
        print("Decision gate: NON-DECISIVE — bundle preserved; see reduction-summary.txt for blockers.")
    print(f"Reduced bundle: {archive}")
    print(f"Size: {archive.stat().st_size / (1024 * 1024):.1f} MiB")


if __name__ == "__main__":
    main()
