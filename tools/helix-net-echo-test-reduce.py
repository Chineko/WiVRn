#!/usr/bin/env python3
import argparse
import math
import statistics
import struct
import tarfile
from pathlib import Path

HEADER = struct.Struct("<8sIIQQ")
RECORD = struct.Struct("<QQQQQQiI")
MAGIC = b"HLXECH1\0"
REC_ECHO = 1 << 0
REC_TX_TS = 1 << 1


def read_kv(path):
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def pct(values, p):
    values = sorted(values)
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    x = (len(values) - 1) * p
    lo = math.floor(x)
    hi = math.ceil(x)
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (x - lo)


def ms(v):
    return v / 1e6


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path)
    args = ap.parse_args()
    src = args.run_dir.expanduser().resolve()
    meta = read_kv(src / "metadata.txt")
    host_status = read_kv(src / "host-status.txt")
    quest_status = read_kv(src / "quest-status.txt")

    log = src / "host.bin"
    rows = []
    with log.open("rb") as f:
        raw = f.read(HEADER.size)
        if len(raw) != HEADER.size:
            raise SystemExit("truncated host log header")
        magic, version, rec_size, _a, _b = HEADER.unpack(raw)
        if magic != MAGIC or version != 1 or rec_size != RECORD.size:
            raise SystemExit(f"unsupported host log header: magic={magic!r} version={version} record_size={rec_size}")
        while True:
            raw = f.read(RECORD.size)
            if not raw:
                break
            if len(raw) != RECORD.size:
                raise SystemExit("truncated host record")
            rows.append(RECORD.unpack(raw))

    if not rows:
        raise SystemExit("host log contains no records")

    echoes = [r for r in rows if r[7] & REC_ECHO]
    txrows = [r for r in rows if r[7] & REC_TX_TS]
    if not echoes:
        raise SystemExit("no echoes received")

    # Cross-device realtime clocks have an unknown constant offset. Subtracting
    # a low-percentile baseline makes changes in each one-way component useful.
    rtt_vals = [r[5] - r[1] for r in echoes]
    forward_vals = [r[3] - (r[2] if r[7] & REC_TX_TS else r[1]) for r in echoes]
    reverse_vals = [r[5] - r[4] for r in echoes]
    quest_proc_vals = [r[4] - r[3] for r in echoes]
    txq_vals = [r[2] - r[1] for r in txrows]

    rtt_base = pct(rtt_vals, 0.01)
    fwd_base = pct(forward_vals, 0.01)
    rev_base = pct(reverse_vals, 0.01)
    proc_base = pct(quest_proc_vals, 0.01)
    txq_base = pct(txq_vals, 0.01) if txq_vals else None

    enriched = []
    for r in echoes:
        seq, hs, htx, qrx, qtx, hrx, _send_result, flags = r
        rtt_ex = ms((hrx - hs) - rtt_base)
        fwd_raw = qrx - (htx if flags & REC_TX_TS else hs)
        fwd_ex = ms(fwd_raw - fwd_base)
        rev_ex = ms((hrx - qtx) - rev_base)
        proc_ex = ms((qtx - qrx) - proc_base)
        txq_ex = None
        if flags & REC_TX_TS and txq_base is not None:
            txq_ex = ms((htx - hs) - txq_base)
        enriched.append((seq, rtt_ex, fwd_ex, rev_ex, proc_ex, txq_ex))

    hot = [x for x in enriched if x[1] >= 15.0]
    events = []
    i = 0
    while i < len(enriched):
        if enriched[i][1] < 15.0:
            i += 1
            continue
        start = i
        while i + 1 < len(enriched) and enriched[i + 1][0] == enriched[i][0] + 1 and enriched[i + 1][1] >= 15.0:
            i += 1
        block = enriched[start:i + 1]
        peak = max(block, key=lambda x: x[1])
        med_fwd = statistics.median(x[2] for x in block)
        med_rev = statistics.median(x[3] for x in block)
        med_proc = statistics.median(x[4] for x in block)
        txvals = [x[5] for x in block if x[5] is not None]
        med_txq = statistics.median(txvals) if txvals else None
        if med_txq is not None and med_txq >= 10.0:
            cls = "host_tx_queue"
        elif med_proc >= 10.0:
            cls = "quest_userspace_processing"
        elif med_fwd >= 10.0 and med_rev < 5.0:
            cls = "host_to_quest"
        elif med_rev >= 10.0 and med_fwd < 5.0:
            cls = "quest_to_host"
        elif med_fwd >= 10.0 and med_rev >= 10.0:
            cls = "bidirectional_or_shared_link"
        else:
            cls = "mixed_or_unresolved"
        events.append({
            "start": block[0][0],
            "end": block[-1][0],
            "count": len(block),
            "peak_rtt": peak[1],
            "med_fwd": med_fwd,
            "med_rev": med_rev,
            "med_proc": med_proc,
            "med_txq": med_txq,
            "class": cls,
        })
        i += 1

    total = len(rows)
    missing_echo = total - len(echoes)
    max_rtt = max(x[1] for x in enriched)
    max_fwd = max(x[2] for x in enriched)
    max_rev = max(x[3] for x in enriched)
    max_proc = max(x[4] for x in enriched)
    max_txq = max((x[5] for x in enriched if x[5] is not None), default=None)

    integrity = []
    if meta.get("wifi_endpoint_state_consistent") != "true":
        integrity.append("Quest BSSID or 6-GHz endpoint changed or was unavailable")
    if host_status.get("send_errors", "1") != "0":
        integrity.append("host send errors were reported")
    if host_status.get("echo_rx_kernel_timestamp_supported") != "true":
        integrity.append("host echo kernel RX timestamps unsupported")
    if host_status.get("echo_rx_timestamp_missing", "1") != "0":
        integrity.append("host echo RX kernel timestamps missing")
    if quest_status.get("rx_kernel_timestamp_supported") != "true":
        integrity.append("Quest kernel RX timestamps unsupported")
    if quest_status.get("rx_timestamp_missing", "1") != "0":
        integrity.append("Quest RX kernel timestamps missing")
    if quest_status.get("echo_send_errors", "1") != "0":
        integrity.append("Quest echo send errors were reported")

    max_txq_text = "na" if max_txq is None else f"{max_txq:.3f}"
    summary = [
        f"source={src}",
        "experiment=bidirectional_low_load_udp_echo_localization",
        f"duration_s={host_status.get('duration_s', 'unknown')}",
        f"hz={host_status.get('hz', 'unknown')}",
        f"payload_bytes={host_status.get('payload_bytes', 'unknown')}",
        f"host_total_packets={total}",
        f"echoes_received={len(echoes)}",
        f"missing_echoes={missing_echo}",
        f"tx_kernel_timestamp_supported={host_status.get('tx_kernel_timestamp_supported', 'false')}",
        f"tx_kernel_timestamp_count={len(txrows)}",
        f"rtt_baseline_ms={ms(rtt_base):.3f}",
        f"max_rtt_excess_ms={max_rtt:.3f}",
        f"max_forward_excess_ms={max_fwd:.3f}",
        f"max_reverse_excess_ms={max_rev:.3f}",
        f"max_quest_processing_excess_ms={max_proc:.3f}",
        f"max_host_tx_queue_excess_ms={max_txq_text}",
        f"samples_over_15ms_rtt_excess={len(hot)}",
        f"stall_event_count={len(events)}",
        f"wifi_endpoint_state_consistent={meta.get('wifi_endpoint_state_consistent', 'unknown')}",
        f"decision_capable={'true' if not integrity else 'false'}",
    ]
    for n, reason in enumerate(integrity, 1):
        summary.append(f"decision_blocker_{n}={reason}")
    for n, e in enumerate(sorted(events, key=lambda x: x["peak_rtt"], reverse=True)[:20], 1):
        med_txq_text = "na" if e["med_txq"] is None else f"{e['med_txq']:.3f}"
        summary.append(
            f"event_{n}=start:{e['start']} end:{e['end']} count:{e['count']} "
            f"peak_rtt_excess_ms:{e['peak_rtt']:.3f} median_forward_excess_ms:{e['med_fwd']:.3f} "
            f"median_reverse_excess_ms:{e['med_rev']:.3f} median_quest_processing_excess_ms:{e['med_proc']:.3f} "
            f"median_host_tx_queue_excess_ms:{med_txq_text} classification:{e['class']}"
        )

    (src / "reduction-summary.txt").write_text("\n".join(summary) + "\n")
    with (src / "timeline.csv").open("w") as f:
        f.write("seq,rtt_excess_ms,forward_excess_ms,reverse_excess_ms,quest_processing_excess_ms,host_tx_queue_excess_ms\n")
        for seq, rtt, fwd, rev, proc, txq in enriched:
            txq_text = "" if txq is None else f"{txq:.6f}"
            f.write(f"{seq},{rtt:.6f},{fwd:.6f},{rev:.6f},{proc:.6f},{txq_text}\n")

    reduced = src.with_name(src.name + "-reduced")
    reduced.mkdir(exist_ok=True)
    for name in (
        "metadata.txt",
        "host-status.txt",
        "host-stderr.txt",
        "quest-status.txt",
        "quest-stderr.txt",
        "reduction-summary.txt",
        "timeline.csv",
    ):
        p = src / name
        if p.exists():
            (reduced / name).write_bytes(p.read_bytes())
    archive = reduced.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz") as tf:
        for p in sorted(reduced.iterdir()):
            tf.add(p, arcname=p.name)

    print("\n".join(summary))
    print(f"reduced_archive={archive}")


if __name__ == "__main__":
    main()
