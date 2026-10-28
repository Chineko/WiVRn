#!/usr/bin/env python3
import argparse
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


def event_windows(events, pad, fallback_radius):
    windows = []
    for e in events:
        if e["first_send_epoch"] is not None:
            windows.append((e["first_send_epoch"] - pad, e["last_send_epoch"] + pad))
        else:
            windows.append((e["report_epoch"] - fallback_radius, e["report_epoch"] + fallback_radius))
    windows.sort()
    merged = []
    for start, end in windows:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return merged


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
    linktype = struct.unpack(endian + "I", header[20:24])[0]
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
    # Both validated interfaces report DLT_EN10MB. Handle one or more VLAN tags
    # defensively, then fingerprint the immutable UDP payload rather than L2/L3 headers.
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

    if src != host_ip or dst != quest_ip:
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
    abs_dev = [abs(x - median) for x in deltas]
    mad = statistics.median(abs_dev)
    return median, mad, len(deltas)


def shift_windows(windows, offset):
    return [(start + offset, end + offset) for start, end in windows]


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

    quest_offset = quest_mad = None
    alignment_matches = 0
    if not missing:
        host_ip = metadata.get("host_ip", "")
        quest_ip = metadata.get("quest_ip", "")
        if not host_ip or not quest_ip:
            raise SystemExit("metadata.txt lacks host_ip/quest_ip required for packet-based clock alignment")
        quest_offset, quest_mad, alignment_matches = derive_quest_clock_offset(host_pcap, quest_pcap, host_ip, quest_ip)
        quest_windows = shift_windows(host_windows, quest_offset)
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
        f"gap_events_current_run={len(events)}",
        f"pad_seconds={args.pad}",
        f"fallback_radius_seconds={args.fallback_radius}",
        f"merged_host_windows={len(host_windows)}",
        f"host_tz_offset={metadata.get('host_tz_offset', 'legacy-local-time')}",
        f"quest_clock_offset_seconds={quest_offset}",
        f"quest_clock_alignment_mad_seconds={quest_mad}",
        f"quest_clock_alignment_matches={alignment_matches}",
    ]
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
        if quest_offset is not None:
            summary.append(f"quest_window_{i}_epoch={start + quest_offset:.6f}..{end + quest_offset:.6f}")

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
            raise SystemExit(f"{name} contains no packets; refusing to produce a misleading reduced bundle")
        if stats["kept"] == 0:
            raise SystemExit(f"{name} kept zero packets around real gap windows; timestamp/capture correlation is invalid")
        for start, end in windows:
            if stats["first"] is None or stats["last"] is None or start < stats["first"] - 0.050 or end > stats["last"] + 0.050:
                raise SystemExit(f"{name} does not cover every decision window; refusing to hide incomplete capture coverage")

    for label, stat_file in (("host", src / "host-tcpdump.txt"), ("quest", src / "quest-tcpdump.txt")):
        drops = tcpdump_kernel_drops(stat_file)
        summary.append(f"{label}_tcpdump_kernel_drops={drops}")
        if drops is None and not args.allow_missing_capture:
            raise SystemExit(f"Could not verify {label} tcpdump kernel-drop count; capture integrity is ambiguous")
        if drops not in (None, 0):
            raise SystemExit(f"{label} tcpdump reports {drops} packets dropped by kernel; cannot use absence from the PCAP as path-loss evidence")

    (out / "reduction-summary.txt").write_text("\n".join(summary) + "\n")

    archive = out.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz", compresslevel=6) as tar:
        tar.add(out, arcname=out.name)

    print(f"Found {len(events)} current-run Helix gap event(s); retained reconstructed sender windows with ±{args.pad:g}s padding.")
    if quest_offset is not None:
        print(f"Aligned Quest capture from {alignment_matches} identical UDP packets (median offset {quest_offset:+.6f}s, MAD {quest_mad:.6f}s).")
    print(f"Reduced bundle: {archive}")
    print(f"Size: {archive.stat().st_size / (1024 * 1024):.1f} MiB")


if __name__ == "__main__":
    main()
