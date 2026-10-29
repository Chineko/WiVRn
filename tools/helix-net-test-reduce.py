#!/usr/bin/env python3
import argparse
import array
import math
import statistics
import struct
import tarfile
from pathlib import Path

LOG_HEADER = struct.Struct("<8sIIQQ")
TX_RECORD = struct.Struct("<QQQIi")
RX_RECORD = struct.Struct("<QQQQII")
TX_MAGIC = b"HLXTX1\0\0"
RX_MAGIC = b"HLXRX1\0\0"
SENTINEL = -(1 << 63)


def read_kv(path: Path):
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def need_int(d, key):
    try:
        return int(d[key])
    except (KeyError, ValueError):
        raise SystemExit(f"missing/invalid {key}")


def read_header(f, expected_magic, record_size, path):
    raw = f.read(LOG_HEADER.size)
    if len(raw) != LOG_HEADER.size:
        raise SystemExit(f"{path}: truncated log header")
    magic, version, rec_size, _r0, _r1 = LOG_HEADER.unpack(raw)
    if magic != expected_magic:
        raise SystemExit(f"{path}: wrong magic {magic!r}")
    if version != 1:
        raise SystemExit(f"{path}: unsupported version {version}")
    if rec_size != record_size:
        raise SystemExit(f"{path}: record size {rec_size} != expected {record_size}")


def bit_get(bits, n):
    return (bits[n >> 3] >> (n & 7)) & 1


def bit_set(bits, n):
    bits[n >> 3] |= 1 << (n & 7)


def percentile_sorted(values, p):
    if not values:
        return None
    if len(values) == 1:
        return values[0]
    x = (len(values) - 1) * p
    lo = int(math.floor(x))
    hi = int(math.ceil(x))
    if lo == hi:
        return values[lo]
    return values[lo] + (values[hi] - values[lo]) * (x - lo)


def median_excess(delay, start, step, count, baseline):
    vals = []
    i = start
    n = len(delay)
    while 0 <= i < n and len(vals) < count:
        if delay[i] != SENTINEL:
            vals.append((delay[i] - baseline) / 1e6)
        i += step
    return statistics.median(vals) if vals else None


def max_excess(delay, start, step, count, baseline):
    vals = []
    i = start
    n = len(delay)
    while 0 <= i < n and len(vals) < count:
        if delay[i] != SENTINEL:
            vals.append((delay[i] - baseline) / 1e6)
        i += step
    return max(vals) if vals else None


def main():
    ap = argparse.ArgumentParser(description="Reduce a standalone Helix PC->Quest synthetic UDP run.")
    ap.add_argument("run_dir", type=Path)
    args = ap.parse_args()
    src = args.run_dir.expanduser().resolve()

    sender_status = read_kv(src / "sender-status.txt")
    receiver_status = read_kv(src / "receiver-status.txt")
    metadata = read_kv(src / "metadata.txt")

    total = need_int(sender_status, "total_packets")
    if total <= 0:
        raise SystemExit("sender reported no packets")
    if need_int(sender_status, "send_errors") != 0 or need_int(sender_status, "short_sends") != 0:
        raise SystemExit("sender reported UDP send failures; run is not path-decision-capable")
    if sender_status.get("log_flush_ok") != "true":
        raise SystemExit("sender log did not flush cleanly")
    if receiver_status.get("log_flush_ok") != "true":
        raise SystemExit("receiver log did not flush cleanly")

    kernel_drops = need_int(receiver_status, "socket_kernel_drops")
    invalid = need_int(receiver_status, "invalid_packets")
    truncated = need_int(receiver_status, "truncated_packets")
    timestamp_missing = need_int(receiver_status, "kernel_timestamp_missing")
    rxq_supported = receiver_status.get("rxq_ovfl_supported") == "true"
    timestamp_supported = receiver_status.get("kernel_timestamp_supported") == "true"

    tx_path = src / "sender.bin"
    rx_path = src / "receiver.bin"
    if not tx_path.exists() or not rx_path.exists():
        raise SystemExit("missing sender.bin or receiver.bin")

    sent_ns = array.array("Q", [0]) * total
    send_results = array.array("i", [0]) * total
    tx_count = 0
    with tx_path.open("rb") as f:
        read_header(f, TX_MAGIC, TX_RECORD.size, tx_path)
        while True:
            raw = f.read(TX_RECORD.size)
            if not raw:
                break
            if len(raw) != TX_RECORD.size:
                raise SystemExit("sender.bin has truncated record")
            seq, _burst, send_ns, _packet_index, result = TX_RECORD.unpack(raw)
            if seq >= total:
                raise SystemExit(f"sender sequence {seq} outside expected range")
            if sent_ns[seq] != 0:
                raise SystemExit(f"duplicate sender sequence {seq}")
            sent_ns[seq] = send_ns
            send_results[seq] = result
            tx_count += 1

    if tx_count != total or any(v == 0 for v in sent_ns):
        raise SystemExit(f"sender log coverage mismatch: records={tx_count}, expected={total}")
    nonzero_results = sum(1 for v in send_results if v != 0)
    if nonzero_results:
        raise SystemExit(f"sender log contains {nonzero_results} failed/short send records")

    seen = bytearray((total + 7) // 8)
    delay = array.array("q", [SENTINEL]) * total
    duplicates = 0
    out_of_range = 0
    rx_records = 0
    sample = []
    sample_stride = max(1, total // 200000)
    last_seq = -1
    arrival_reorders = 0
    max_recorded_kernel_drops = 0

    with rx_path.open("rb") as f:
        read_header(f, RX_MAGIC, RX_RECORD.size, rx_path)
        while True:
            raw = f.read(RX_RECORD.size)
            if not raw:
                break
            if len(raw) != RX_RECORD.size:
                raise SystemExit("receiver.bin has truncated record")
            seq, _burst, send_ns, recv_ns, _packet_index, drops = RX_RECORD.unpack(raw)
            rx_records += 1
            max_recorded_kernel_drops = max(max_recorded_kernel_drops, drops)
            if seq >= total:
                out_of_range += 1
                continue
            if bit_get(seen, seq):
                duplicates += 1
                continue
            bit_set(seen, seq)
            if recv_ns != 0:
                delay[seq] = int(recv_ns) - int(send_ns)
            if seq < last_seq:
                arrival_reorders += 1
            last_seq = max(last_seq, seq)
            if delay[seq] != SENTINEL and seq % sample_stride == 0:
                sample.append(delay[seq])

    sample.sort()
    baseline = percentile_sorted(sample, 0.01)
    if baseline is None:
        raise SystemExit("receiver captured no valid timestamped test packets")

    missing_runs = []
    i = 0
    received_unique = 0
    while i < total:
        if bit_get(seen, i):
            received_unique += 1
            i += 1
            continue
        start = i
        while i < total and not bit_get(seen, i):
            i += 1
        end = i - 1
        count = end - start + 1
        span_ms = (int(sent_ns[end]) - int(sent_ns[start])) / 1e6 if end > start else 0.0
        pre_med = median_excess(delay, start - 1, -1, 32, baseline)
        post_med = median_excess(delay, end + 1, 1, 32, baseline)
        post_max = max_excess(delay, end + 1, 1, 32, baseline)
        post_minus_pre = None if pre_med is None or post_med is None else post_med - pre_med
        missing_runs.append({
            "start": start,
            "end": end,
            "count": count,
            "span_ms": span_ms,
            "pre_median_excess_ms": pre_med,
            "post_median_excess_ms": post_med,
            "post_max_excess_ms": post_max,
            "post_minus_pre_median_ms": post_minus_pre,
        })

    observed_delays = [v for v in delay if v != SENTINEL]
    max_excess_ms = max((v - baseline) / 1e6 for v in observed_delays)
    over15 = sum(1 for v in observed_delays if (v - baseline) >= 15_000_000)
    over30 = sum(1 for v in observed_delays if (v - baseline) >= 30_000_000)

    longest_delay_run = 0
    current = 0
    for v in delay:
        if v != SENTINEL and (v - baseline) >= 15_000_000:
            current += 1
            longest_delay_run = max(longest_delay_run, current)
        else:
            current = 0

    ranked = sorted(missing_runs, key=lambda r: (r["count"], r["span_ms"]), reverse=True)
    candidates = [
        r for r in ranked
        if r["count"] >= 20
        and r["span_ms"] >= 8.0
        and r["post_minus_pre_median_ms"] is not None
        and r["post_minus_pre_median_ms"] >= 10.0
    ]

    integrity_reasons = []
    if metadata.get("wifi_endpoint_state_consistent") != "true":
        integrity_reasons.append("Quest BSSID or 6-GHz endpoint state changed or was unavailable")
    if not rxq_supported:
        integrity_reasons.append("receiver SO_RXQ_OVFL telemetry unsupported")
    if not timestamp_supported:
        integrity_reasons.append("receiver kernel receive timestamps unsupported")
    if timestamp_missing:
        integrity_reasons.append(f"receiver packets missing kernel timestamps={timestamp_missing}")
    if invalid:
        integrity_reasons.append(f"receiver invalid packets={invalid}")
    if truncated:
        integrity_reasons.append(f"receiver truncated packets={truncated}")
    if kernel_drops:
        integrity_reasons.append(f"receiver SO_RXQ_OVFL={kernel_drops}")
    if max_recorded_kernel_drops != kernel_drops:
        integrity_reasons.append(
            f"receiver kernel-drop telemetry mismatch status={kernel_drops} records={max_recorded_kernel_drops}"
        )
    if out_of_range:
        integrity_reasons.append(f"receiver out-of-range sequences={out_of_range}")

    decision_capable = not integrity_reasons
    loss_packets = total - received_unique
    loss_pct = loss_packets * 100.0 / total

    summary = [
        f"source={src}",
        "experiment=standalone_pc_to_quest_udp_no_wivrn_no_tcpdump",
        f"wifi_endpoint_state_consistent={metadata.get('wifi_endpoint_state_consistent', 'unknown')}",
        f"duration_s={sender_status.get('duration_s', 'unknown')}",
        f"hz={sender_status.get('hz', 'unknown')}",
        f"packets_per_burst={sender_status.get('packets_per_burst', 'unknown')}",
        f"spacing_us={sender_status.get('spacing_us', 'unknown')}",
        f"payload_bytes={sender_status.get('payload_bytes', 'unknown')}",
        f"sender_total_packets={total}",
        f"receiver_records={rx_records}",
        f"receiver_unique_packets={received_unique}",
        f"missing_packets={loss_packets}",
        f"loss_percent={loss_pct:.6f}",
        f"duplicate_packets={duplicates}",
        f"arrival_reorders={arrival_reorders}",
        f"receiver_socket_kernel_drops={kernel_drops}",
        f"receiver_rxq_ovfl_supported={'true' if rxq_supported else 'false'}",
        f"receiver_kernel_timestamp_supported={'true' if timestamp_supported else 'false'}",
        f"receiver_kernel_timestamp_missing={timestamp_missing}",
        f"receiver_effective_so_rcvbuf_bytes={receiver_status.get('effective_so_rcvbuf_bytes', 'unknown')}",
        f"relative_delay_baseline_ns={int(baseline)}",
        f"max_relative_delay_excess_ms={max_excess_ms:.3f}",
        f"packets_over_15ms_excess={over15}",
        f"packets_over_30ms_excess={over30}",
        f"longest_consecutive_received_run_over_15ms={longest_delay_run}",
        f"missing_run_count={len(missing_runs)}",
        f"wivrn_like_candidate_count={len(candidates)}",
        f"wivrn_like_candidate={'true' if candidates else 'false'}",
        f"decision_capable={'true' if decision_capable else 'false'}",
    ]
    for j, reason in enumerate(integrity_reasons, 1):
        summary.append(f"decision_blocker_{j}={reason}")

    for j, r in enumerate(ranked[:20], 1):
        summary.append(
            "gap_%d=start:%d end:%d count:%d sender_span_ms:%.3f pre32_median_excess_ms:%s "
            "post32_median_excess_ms:%s post_minus_pre_median_ms:%s post32_max_excess_ms:%s candidate:%s" % (
                j, r["start"], r["end"], r["count"], r["span_ms"],
                "na" if r["pre_median_excess_ms"] is None else f"{r['pre_median_excess_ms']:.3f}",
                "na" if r["post_median_excess_ms"] is None else f"{r['post_median_excess_ms']:.3f}",
                "na" if r["post_minus_pre_median_ms"] is None else f"{r['post_minus_pre_median_ms']:.3f}",
                "na" if r["post_max_excess_ms"] is None else f"{r['post_max_excess_ms']:.3f}",
                "true" if r in candidates else "false",
            )
        )

    (src / "reduction-summary.txt").write_text("\n".join(summary) + "\n")

    windows_csv = src / "event-windows.csv"
    selected = ranked[:20]
    with windows_csv.open("w") as f:
        f.write("event,start_seq,end_seq,seq,sent_ms_from_first,received,relative_delay_excess_ms\n")
        first_send = int(sent_ns[0])
        for event_index, gap in enumerate(selected, 1):
            lo = max(0, gap["start"] - 256)
            hi = min(total - 1, gap["end"] + 256)
            for seq in range(lo, hi + 1):
                recvd = bit_get(seen, seq)
                excess = ""
                if recvd and delay[seq] != SENTINEL:
                    excess = f"{(delay[seq] - baseline) / 1e6:.6f}"
                f.write(
                    f"{event_index},{gap['start']},{gap['end']},{seq},"
                    f"{(int(sent_ns[seq]) - first_send) / 1e6:.6f},{recvd},{excess}\n"
                )

    reduced_dir = src.with_name(src.name + "-reduced")
    reduced_dir.mkdir(exist_ok=True)
    for name in (
        "metadata.txt", "sender-status.txt", "sender-stderr.txt", "receiver-status.txt", "receiver-stderr.txt",
        "reduction-summary.txt", "event-windows.csv",
    ):
        p = src / name
        if p.exists():
            (reduced_dir / name).write_bytes(p.read_bytes())

    archive = reduced_dir.with_suffix(".tar.gz")
    with tarfile.open(archive, "w:gz", compresslevel=6) as tar:
        tar.add(reduced_dir, arcname=reduced_dir.name)

    print(f"Decision gate: {'PASS' if decision_capable else 'NON-DECISIVE'}")
    print(f"Loss: {loss_packets}/{total} packets ({loss_pct:.6f}%), {len(missing_runs)} contiguous missing run(s).")
    print(f"Max relative delay excess: {max_excess_ms:.3f} ms.")
    if candidates:
        top = candidates[0]
        print(
            "WiVRn-like stall/loss candidate: YES — "
            f"{top['count']} missing packets over {top['span_ms']:.3f} ms, "
            f"post-vs-pre median delay increase {top['post_minus_pre_median_ms']:.3f} ms."
        )
    else:
        print("WiVRn-like stall/loss candidate: NO under the current evidence thresholds.")
    print(f"Reduced bundle: {archive}")


if __name__ == "__main__":
    main()
