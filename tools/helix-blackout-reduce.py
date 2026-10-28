#!/usr/bin/env python3
import argparse
import datetime as dt
import re
import shutil
import struct
import tarfile
from pathlib import Path

GAP_RE = re.compile(r"^\[(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+)\].*Helix gap timing event")


def gap_windows(server_log: Path, radius: float):
    stamps = []
    for line in server_log.read_text(errors="replace").splitlines():
        m = GAP_RE.search(line)
        if not m:
            continue
        # WiVRn server log timestamps are local wall-clock timestamps. A naive
        # datetime.timestamp() intentionally uses the host's local timezone.
        stamps.append(dt.datetime.fromisoformat(m.group(1)).timestamp())
    if not stamps:
        raise SystemExit("No 'Helix gap timing event' lines found in server-log.txt; not reducing PCAPs blindly.")

    windows = sorted((t - radius, t + radius) for t in stamps)
    merged = []
    for start, end in windows:
        if merged and start <= merged[-1][1]:
            merged[-1] = (merged[-1][0], max(merged[-1][1], end))
        else:
            merged.append((start, end))
    return stamps, merged


def pcap_endian_and_scale(header: bytes):
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
    return formats[magic]


def in_windows(ts: float, windows):
    return any(start <= ts <= end for start, end in windows)


def trim_pcap(src: Path, dst: Path, windows):
    kept = total = 0
    with src.open("rb") as fin, dst.open("wb") as fout:
        global_header = fin.read(24)
        endian, scale = pcap_endian_and_scale(global_header)
        fout.write(global_header)
        packet_header = struct.Struct(endian + "IIII")

        while True:
            raw = fin.read(16)
            if not raw:
                break
            if len(raw) != 16:
                raise ValueError(f"truncated packet header in {src}")
            sec, frac, incl_len, orig_len = packet_header.unpack(raw)
            payload = fin.read(incl_len)
            if len(payload) != incl_len:
                raise ValueError(f"truncated packet payload in {src}")
            total += 1
            ts = sec + frac / scale
            if in_windows(ts, windows):
                fout.write(raw)
                fout.write(payload)
                kept += 1
    return total, kept


def newest_capture_dir(home: Path):
    candidates = [p for p in home.glob("helix-blackout-*") if p.is_dir() and (p / "server-log.txt").exists()]
    if not candidates:
        raise SystemExit("No ~/helix-blackout-* capture directory containing server-log.txt was found.")
    return max(candidates, key=lambda p: p.stat().st_mtime)


def main():
    parser = argparse.ArgumentParser(description="Reduce a Helix blackout capture to short PCAP windows around real Helix gap events.")
    parser.add_argument("capture_dir", nargs="?", type=Path, help="capture directory; defaults to newest ~/helix-blackout-* directory")
    parser.add_argument("--radius", type=float, default=3.0, help="seconds before/after each gap report to retain (default: 3)")
    args = parser.parse_args()

    src = (args.capture_dir or newest_capture_dir(Path.home())).expanduser().resolve()
    server_log = src / "server-log.txt"
    if not server_log.exists():
        raise SystemExit(f"missing {server_log}")

    stamps, windows = gap_windows(server_log, args.radius)
    out = src.with_name(src.name + "-reduced")
    if out.exists():
        shutil.rmtree(out)
    out.mkdir()

    # Preserve all small textual evidence; only the high-volume PCAPs are trimmed.
    for p in src.iterdir():
        if p.is_file() and p.suffix != ".pcap":
            shutil.copy2(p, out / p.name)

    summary = [
        f"source={src}",
        f"gap_events={len(stamps)}",
        f"radius_seconds={args.radius}",
        f"merged_windows={len(windows)}",
    ]
    for i, (start, end) in enumerate(windows, 1):
        summary.append(
            f"window_{i}={dt.datetime.fromtimestamp(start).isoformat(timespec='milliseconds')}.."
            f"{dt.datetime.fromtimestamp(end).isoformat(timespec='milliseconds')}"
        )

    for name in ("host.pcap", "quest.pcap"):
        p = src / name
        if not p.exists():
            summary.append(f"{name}=missing")
            continue
        total, kept = trim_pcap(p, out / name, windows)
        summary.append(f"{name}_packets_total={total}")
        summary.append(f"{name}_packets_kept={kept}")
        summary.append(f"{name}_bytes_reduced={(out / name).stat().st_size}")

    (out / "reduction-summary.txt").write_text("\n".join(summary) + "\n")

    archive = out.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz", compresslevel=6) as tar:
        tar.add(out, arcname=out.name)

    print(f"Found {len(stamps)} Helix gap event(s); kept ±{args.radius:g}s around them.")
    print(f"Reduced bundle: {archive}")
    print(f"Size: {archive.stat().st_size / (1024 * 1024):.1f} MiB")


if __name__ == "__main__":
    main()
