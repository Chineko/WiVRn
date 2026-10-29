#!/usr/bin/env python3
import importlib.util
import socket
import struct
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
REDUCER = ROOT / "tools/helix-blackout-radio-reduce-v4.py"
spec = importlib.util.spec_from_file_location("radio_reduce", REDUCER)
radio = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(radio)

HOST = "192.168.0.44"
QUEST = "192.168.0.54"


def frame(ip_id, src_port, dst_port, payload=b"x"):
    eth = b"\x00" * 12 + b"\x08\x00"
    total = 20 + 8 + len(payload)
    ip = bytearray(20)
    ip[0] = 0x45
    ip[2:4] = total.to_bytes(2, "big")
    ip[4:6] = ip_id.to_bytes(2, "big")
    ip[8] = 64
    ip[9] = 17
    ip[12:16] = socket.inet_aton(HOST)
    ip[16:20] = socket.inet_aton(QUEST)
    udp = bytearray(8)
    udp[0:2] = src_port.to_bytes(2, "big")
    udp[2:4] = dst_port.to_bytes(2, "big")
    udp[4:6] = (8 + len(payload)).to_bytes(2, "big")
    return eth + bytes(ip) + bytes(udp) + payload


def write_pcap(path, records):
    with path.open("wb") as f:
        f.write(struct.pack("<IHHIIII", 0xA1B2C3D4, 2, 4, 0, 0, 65535, 1))
        for ts, data in records:
            sec = int(ts)
            usec = int(round((ts - sec) * 1_000_000))
            f.write(struct.pack("<IIII", sec, usec, len(data), len(data)))
            f.write(data)


assert radio.driver_key(frame(123, 9757, 58535), HOST, QUEST) == (123, 9757, 58535)
assert radio.driver_key(frame(123, 9757, 58535), QUEST, HOST) is None

with tempfile.TemporaryDirectory() as td:
    td = Path(td)
    pcap = td / "quest.pcap"
    ports = [49271, 49272, 49273]
    pcap_rows = []
    trace_rows = []
    for i, port in enumerate(ports):
        key = (40000 + i, 55000, port)
        qts = 1000.100 + i * 0.020
        pcap_rows.append((qts, frame(key[0], key[1], key[2], b"sync")))
        trace_rows.append((qts - 123.456, key))
        # Same destination port but a different tuple must not steal the marker.
        trace_rows.append((qts - 50.0, (key[0] + 1, key[1] + 1, key[2])))
    write_pcap(pcap, pcap_rows)
    offset, mad, used = radio.sync_offset(trace_rows, pcap, HOST, QUEST, ports)
    assert used == ports
    assert abs(offset - 123.456) < 0.00001
    assert mad < 0.00001

    trace_file = td / "trace.txt"
    trace_file.write_text(
        "task-1 [000] .... 12.345678: dp_rx_udp_pkt: skbaddr=0 ip_id=123 srcport=9757 dstport=58535 latency=7 status=0\n"
    )
    assert radio.parse_trace(trace_file) == [(12.345678, (123, 9757, 58535))]

    stats = td / "stats.txt"
    stats.write_text("entries: 10\noverrun: 2\ndropped events: 0\n")
    overruns, dropped = radio.trace_stats(stats)
    assert overruns == [2]
    assert dropped == [0]

assert radio.has_time([1.0, 2.0, 3.0], 2.01, 0.02)
assert not radio.has_time([1.0, 2.0, 3.0], 2.10, 0.02)
print("Radio attribution self-test PASS")
