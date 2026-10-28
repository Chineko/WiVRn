#!/usr/bin/env python3
import collections
import ipaddress
import struct
from dataclasses import dataclass


@dataclass
class Packet:
    ts: float
    src: str
    dst: str
    sport: int
    dport: int
    udp_len: int
    payload: bytes

    def fingerprint(self):
        return (self.src, self.dst, self.sport, self.dport, self.udp_len, self.payload[:16])


def pcap_format(header: bytes):
    if len(header) != 24:
        raise ValueError("truncated PCAP global header")
    formats = {
        b"\xd4\xc3\xb2\xa1": ("<", 1_000_000),
        b"\xa1\xb2\xc3\xd4": (">", 1_000_000),
        b"\x4d\x3c\xb2\xa1": ("<", 1_000_000_000),
        b"\xa1\xb2\x3c\x4d": (">", 1_000_000_000),
    }
    if header[:4] not in formats:
        raise ValueError(f"unsupported capture format/magic {header[:4].hex()}")
    endian, scale = formats[header[:4]]
    linktype = struct.unpack(endian + "I", header[20:24])[0]
    if linktype != 1:
        raise ValueError(f"unsupported PCAP linktype {linktype}; expected Ethernet (1)")
    return endian, scale


def iter_pcap(path):
    with path.open("rb") as f:
        header = f.read(24)
        endian, scale = pcap_format(header)
        packet_header = struct.Struct(endian + "IIII")
        while True:
            raw = f.read(16)
            if not raw:
                return
            if len(raw) != 16:
                raise ValueError(f"truncated packet header in {path}")
            sec, frac, incl_len, _orig_len = packet_header.unpack(raw)
            data = f.read(incl_len)
            if len(data) != incl_len:
                raise ValueError(f"truncated packet payload in {path}")
            yield sec + frac / scale, raw, data


def decode_udp(ts, data):
    if len(data) < 14:
        return None
    off = 14
    ethertype = struct.unpack("!H", data[12:14])[0]
    while ethertype in (0x8100, 0x88A8):
        if len(data) < off + 4:
            return None
        ethertype = struct.unpack("!H", data[off + 2:off + 4])[0]
        off += 4
    if ethertype != 0x0800 or len(data) < off + 28:
        return None
    version_ihl = data[off]
    if version_ihl >> 4 != 4:
        return None
    ihl = (version_ihl & 0x0F) * 4
    if ihl < 20 or len(data) < off + ihl + 8 or data[off + 9] != 17:
        return None
    frag = struct.unpack("!H", data[off + 6:off + 8])[0]
    if frag & 0x1FFF:
        return None
    src = str(ipaddress.IPv4Address(data[off + 12:off + 16]))
    dst = str(ipaddress.IPv4Address(data[off + 16:off + 20]))
    uoff = off + ihl
    sport, dport, udp_len = struct.unpack("!HHH", data[uoff:uoff + 6])
    return Packet(ts, src, dst, sport, dport, udp_len, data[uoff + 8:])


def load_udp(path):
    result = []
    for ts, _raw, data in iter_pcap(path):
        packet = decode_udp(ts, data)
        if packet:
            result.append(packet)
    return result


def trim_pcap(src, dst, windows):
    kept = total = 0
    with src.open("rb") as fin, dst.open("wb") as fout:
        header = fin.read(24)
        endian, scale = pcap_format(header)
        fout.write(header)
        packet_header = struct.Struct(endian + "IIII")
        while True:
            raw = fin.read(16)
            if not raw:
                break
            if len(raw) != 16:
                raise ValueError(f"truncated packet header in {src}")
            sec, frac, incl_len, _orig_len = packet_header.unpack(raw)
            data = fin.read(incl_len)
            if len(data) != incl_len:
                raise ValueError(f"truncated packet payload in {src}")
            total += 1
            ts = sec + frac / scale
            if any(start <= ts <= end for start, end in windows):
                fout.write(raw)
                fout.write(data)
                kept += 1
    return total, kept


def marker_map(packets, marker_port, nonce):
    prefix = f"HXMK|{nonce}|".encode()
    result = {}
    for packet in packets:
        if packet.dport != marker_port or not packet.payload.startswith(prefix):
            continue
        try:
            key = packet.payload.decode("ascii", errors="strict")
        except UnicodeDecodeError:
            continue
        result.setdefault(key, packet.ts)
    return result


def _median(values):
    values = sorted(values)
    if not values:
        raise ValueError("median of empty sequence")
    middle = len(values) // 2
    if len(values) % 2:
        return values[middle]
    return (values[middle - 1] + values[middle]) / 2


def build_clock_model(host_markers, quest_markers):
    shared = set(host_markers) & set(quest_markers)
    starts = sorted(k for k in shared if "|S|" in k)
    ends = sorted(k for k in shared if "|E|" in k)
    if len(starts) < 2 or len(ends) < 2:
        raise ValueError(f"matched start/end markers={len(starts)}/{len(ends)}; expected >=2 each")
    start_delta = _median([quest_markers[k] - host_markers[k] for k in starts])
    end_delta = _median([quest_markers[k] - host_markers[k] for k in ends])
    start_host = _median([host_markers[k] for k in starts])
    end_host = _median([host_markers[k] for k in ends])
    if end_host <= start_host:
        raise ValueError("clock alignment markers are not ordered")

    def align(host_ts):
        fraction = min(1.0, max(0.0, (host_ts - start_host) / (end_host - start_host)))
        delta = start_delta + fraction * (end_delta - start_delta)
        return host_ts + delta

    return align, start_delta, end_delta, starts, ends


def select(packets, start, end, src=None, dst=None, marker_port=None):
    result = []
    for packet in packets:
        if not start <= packet.ts <= end:
            continue
        if src is not None and packet.src != src:
            continue
        if dst is not None and packet.dst != dst:
            continue
        if marker_port is not None and (packet.sport == marker_port or packet.dport == marker_port):
            continue
        result.append(packet)
    return result


def match_count(host_packets, quest_packets):
    available = collections.Counter(packet.fingerprint() for packet in quest_packets)
    matched = 0
    for packet in host_packets:
        fp = packet.fingerprint()
        if available[fp]:
            available[fp] -= 1
            matched += 1
    return matched
