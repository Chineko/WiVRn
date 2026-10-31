#!/usr/bin/env python3
"""Deterministic VRChat-like workload + path-impairment trace generator for Helix.

Why this exists
---------------
The existing synthetic transport battery (server/helix_synthetic_transport.cpp) runs
isolated cases: 64 equal shards per frame, ~120 us real spacing, one clean omission
per case, 300 ms idle between cases. It never produces a sustained two-eye 90 Hz stream,
variable frame sizes, producer stalls, or "hold then release" path stalls. Those are the
conditions under which the real failures were measured.

This tool writes a trace that the synthetic server mode replays
(HELIX_SYNTHETIC_TRACE=<file> wivrn-server --helix-synthetic-transport ...).

Trace model
-----------
  1. Frame production: two eyes at 90 Hz, per-frame size from an AR(1) log-normal
     process (scene-complexity phases), IDR spikes, rare producer stalls (frame gaps
     of 40-170 ms), rare slow sends.
  2. Packetisation: ~1385 B payload shards, 50 us production pacer spacing.
  3. Shared-path impairment applied to BOTH eyes' merged packet stream, FIFO:
       erasure_hold   L ms of contiguous loss, then the path holds H ms and drains
                      (the paired-pcap signature: lost run, then survivors 15-43 ms late)
       hold           no loss, everything delayed up to H ms and released in a burst
                      (the low-load 89 ms excursion with 0 loss)
       short_erasure  a few contiguous packets lost
     Events cluster (follow-ups within 5-80 ms), as seen in the blackout capture.

Every number is tagged with its source below. Shape parameters that are NOT pinned by
measurements are marked ASSUMED and are meant to be refit; use --calibrate-from with a
server log containing "Helix pacing baseline" lines to re-pin the size/cadence numbers.

Row format (CSV, '#' lines are header):
  P,t_gen_us,t_send_us,stream,frame_idx,shard_idx,shards_in_frame,payload_bytes,fate
fate: K = send at t_send_us, D = path-dropped (t_send_us = -1; still consumes a packet sequence number).
Rows are in generation order; t_send is non-decreasing over K rows (FIFO, no reordering).
A frame is expected complete at the receiver iff none of its rows is D.
"""
import argparse
import hashlib
import json
import math
import random
import re
import sys

RAW_FRAME_BYTES = 256 * 160 * 3 // 2  # raw_decoder buffer used by the synthetic mode (61440)

# --------------------------------------------------------------------------------------
# Calibration. Source A = server log 2026-10-28 17:24-17:40 ("Helix pacing baseline",
# VRChat, 60-person torture world), 86 387 / 86 391 frames per eye.
# --------------------------------------------------------------------------------------
CAL = {
    "fps": 90.0,                       # A: target_fps=90, inter_frame_gap avg 11116 us
    "frame_bytes_mean": 28430.0,       # A: avg 28319 (s0) / 28540 (s1)
    "frame_bytes_max": 60134,          # A: max 59905 (s0) / 60134 (s1)
    "shard_payload": 1385,             # A: 2465551855 B / 1820992 shards = 1354 B avg incl. partial shards
    "shards_mean": 21.0,               # A: 20.9 / 21.1 (avg shards per frame)
    "shards_max": 44,                  # A: max 44
    "pacer_spacing_us": 50,            # A: version=fixed-50us-v1
    "stream1_offset_ms": (2.0, 4.5),   # B: blackout capture, stream0/stream1 gap reports ~3-6 ms apart
    "slow_send_p": 0.0015,             # A: hist_send_span 2-4 ms bucket 130/86387
    "slow_send_ms": (2.0, 4.0),
    "producer_stall_per_min": 0.25,    # A: 4 frame gaps (43-66 ms) in 16 min; B had one of 165 ms
    "producer_stall_ms": (40.0, 170.0),
    "producer_stall_median_ms": 55.0,
    # ASSUMED shapes (only mean/max are pinned): AR(1) log-size, IDR multiplier.
    "size_sigma": 0.18,                # fit so that max over ~86k frames ~ 60 KB for the pinned mean
    "size_rho": 0.98,
    "idr_multiplier": (1.8, 2.4),
    "idr_after_stall_p": 0.5,
    "idr_after_net_event_p": 0.8,
    "idr_delay_ms": (50.0, 180.0),     # A: report/IDR delay after gaps 13-182 ms
    # Path impairment priors, fitted to: B = paired pcap (90-packet/18.2 ms run, survivors
    # +30.6/+20/+15..25/+17/+43/+33 ms), C = no-WiVRn 1-packet/burst run (89.3 ms, 0 loss).
    "event_mix": (0.60, 0.25, 0.15),   # erasure_hold, hold, short_erasure
    "followup_mix": (0.35, 0.0, 0.65), # B: after the 90-packet run came 4/2/2-packet runs, then one 48-packet run
    "erasure_L_ms": (10.0, 19.0),
    "hold_after_loss_ms": (15.0, 60.0),
    "hold_after_loss_median_ms": 30.0,
    "hold_only_ms": (30.0, 90.0),
    "short_L_ms": (0.1, 3.0),
    "cluster_p": 0.5,
    "cluster_followups": (1, 3),
    "cluster_gap_ms": (5.0, 80.0),
    "drain_gap_us": 14,                # ASSUMED: ~1400 B at ~800 Mbit/s effective release rate
    "warmup_s": 3.0,
}

PROFILES = {
    # events/min from: RTX run 6 clusters/16.4 min = 0.37; blackout run 2/8 min = 0.25; low-load 1/5 min = 0.2
    "measured": {"net_events_per_min": 0.35, "producer_stall_per_min": 0.25},
    # 4x impairment rate and 4x producer stalls: same shapes, denser.
    "torture": {"net_events_per_min": 1.40, "producer_stall_per_min": 1.00},
}


def clip(x, lo, hi):
    return max(lo, min(hi, x))


def poisson_times(rng, rate_per_min, t0_us, t1_us):
    out, t = [], t0_us
    lam = rate_per_min / 60e6  # per us
    while lam > 0:
        t += rng.expovariate(lam)
        if t >= t1_us:
            break
        out.append(int(t))
    return out


def make_frame_times(rng, cal, prof, dur_us):
    """Frame production times shared by both eyes, plus producer-stall bookkeeping."""
    period = 1e6 / cal["fps"]
    stalls = poisson_times(rng, prof["producer_stall_per_min"], int(cal["warmup_s"] * 1e6), dur_us)
    stall_spans = []
    for s in stalls:
        d = clip(rng.lognormvariate(math.log(cal["producer_stall_median_ms"]), 0.35), *cal["producer_stall_ms"]) * 1000
        stall_spans.append((s, int(s + d)))
    times, after_stall = [], set()
    t, si = 0.0, 0
    while t < dur_us:
        times.append(int(t))
        nxt = t + period + rng.gauss(0, 150.0)
        nxt = max(nxt, t + 0.5 * period)
        while si < len(stall_spans) and stall_spans[si][1] <= t:
            si += 1
        if si < len(stall_spans) and t < stall_spans[si][0] <= nxt:
            nxt = float(stall_spans[si][1])
            after_stall.add(len(times))  # index of the next frame
            si += 1
        t = nxt
    return times, after_stall, stall_spans


def sample_net_events(rng, cal, prof, dur_us):
    starts = poisson_times(rng, prof["net_events_per_min"], int(cal["warmup_s"] * 1e6) + 500_000, dur_us - 500_000)
    events = []

    def one(t, mix=None):
        mix = mix or cal["event_mix"]
        u = rng.random()
        if u < mix[0]:
            kind = "erasure_hold"
            L = rng.uniform(*cal["erasure_L_ms"]) * 1000
            H = clip(rng.lognormvariate(math.log(cal["hold_after_loss_median_ms"]), 0.35), *cal["hold_after_loss_ms"]) * 1000
        elif u < mix[0] + mix[1]:
            kind, L, H = "hold", 0.0, rng.uniform(*cal["hold_only_ms"]) * 1000
        else:
            kind, L, H = "short_erasure", rng.uniform(*cal["short_L_ms"]) * 1000, 0.0
        return {"kind": kind, "s": int(t), "L": int(L), "e": int(t + L + H)}

    for t in starts:
        ev = one(t)
        events.append(ev)
        if rng.random() < cal["cluster_p"]:
            last = ev
            for _ in range(rng.randint(*cal["cluster_followups"])):
                nt = last["e"] + rng.uniform(*cal["cluster_gap_ms"]) * 1000
                follow = one(nt, cal["followup_mix"])
                events.append(follow)
                last = follow
    events.sort(key=lambda e: e["s"])
    for i in range(1, len(events)):  # keep events disjoint
        if events[i]["s"] <= events[i - 1]["e"]:
            shift = events[i - 1]["e"] + 1000 - events[i]["s"]
            for k in ("s", "e"):
                events[i][k] += shift
    return events


def generate(seed, duration_s, profile, cal=CAL):
    rng = random.Random(seed)
    prof = PROFILES[profile]
    dur_us = int(duration_s * 1e6)
    ftimes, after_stall, stall_spans = make_frame_times(rng, cal, prof, dur_us)
    events = sample_net_events(rng, cal, prof, dur_us)

    sigma, rho = cal["size_sigma"], cal["size_rho"]
    mu = math.log(cal["frame_bytes_mean"]) - sigma * sigma / 2
    cap = min(cal["frame_bytes_max"], RAW_FRAME_BYTES)
    x = [rng.gauss(0, sigma), rng.gauss(0, sigma)]
    idr_pending = [None, None]  # frame time at/after which the stream emits an IDR
    net_end_times = [e["e"] for e in events]
    idr_due = []
    for e in net_end_times:
        if rng.random() < cal["idr_after_net_event_p"]:
            idr_due.append(e + int(rng.uniform(*cal["idr_delay_ms"]) * 1000))
    idr_due.sort()
    idr_i = 0

    packets = []  # (t_gen, stream, frame, shard, shards, bytes)
    frame_meta = []
    nframes = [0, 0]
    for k, ft in enumerate(ftimes):
        idr = k in after_stall and rng.random() < cal["idr_after_stall_p"]
        while idr_i < len(idr_due) and idr_due[idr_i] <= ft:
            idr = True
            idr_i += 1
        base_off = rng.uniform(*cal["stream1_offset_ms"]) * 1000
        for s in (0, 1):
            x[s] = rho * x[s] + math.sqrt(1 - rho * rho) * rng.gauss(0, sigma)
            size = math.exp(mu + x[s])
            if idr:
                size *= rng.uniform(*cal["idr_multiplier"])
            nbytes = int(clip(size, 4000, cap))
            nshards = -(-nbytes // cal["shard_payload"])
            nshards = min(nshards, cal["shards_max"])
            nbytes = min(nbytes, nshards * cal["shard_payload"])
            spacing = cal["pacer_spacing_us"]
            if rng.random() < cal["slow_send_p"]:
                spacing = rng.uniform(*cal["slow_send_ms"]) * 1000 / nshards
            t0 = ft + (0 if s == 0 else base_off)
            f = nframes[s]
            nframes[s] += 1
            frame_meta.append((s, f, nbytes, nshards, int(t0), idr))
            rem = nbytes
            for sh in range(nshards):
                pb = min(cal["shard_payload"], rem)
                rem -= pb
                packets.append((int(t0 + sh * spacing), s, f, sh, nshards, pb))
    packets.sort(key=lambda p: (p[0], p[1], p[3]))

    # FIFO path model.
    rows, out_free, ei = [], 0, 0
    drop_frames = set()
    max_delay = 0
    for (tg, s, f, sh, ns, pb) in packets:
        while ei < len(events) and events[ei]["e"] <= tg:
            ei += 1
        ev = events[ei] if ei < len(events) and events[ei]["s"] <= tg < events[ei]["e"] else None
        if ev is not None and tg < ev["s"] + ev["L"]:
            rows.append((tg, None, s, f, sh, ns, pb))
            drop_frames.add((s, f))
            continue
        ready = ev["e"] if ev is not None else tg
        ts = max(ready, out_free)
        out_free = ts + cal["drain_gap_us"]
        max_delay = max(max_delay, ts - tg)
        rows.append((tg, ts, s, f, sh, ns, pb))
    return {
        "rows": rows, "events": events, "stall_spans": stall_spans, "frame_meta": frame_meta,
        "drop_frames": drop_frames, "max_delay_us": max_delay, "seed": seed,
        "duration_s": duration_s, "profile": profile,
    }


def write_trace(tr, path):
    h = hashlib.sha256()
    lines = []
    for (tg, ts, s, f, sh, ns, pb) in tr["rows"]:
        line = f"P,{tg},{-1 if ts is None else ts},{s},{f},{sh},{ns},{pb},{'D' if ts is None else 'K'}"
        lines.append(line)
        h.update(line.encode() + b"\n")
    with open(path, "w") as fh:
        fh.write("# helix-vrchat-trace v1\n")
        fh.write(f"# seed={tr['seed']} duration_s={tr['duration_s']} profile={tr['profile']}\n")
        fh.write(f"# rows={len(lines)} rows_sha256={h.hexdigest()}\n")
        fh.write("# P,t_gen_us,t_send_us,stream,frame_idx,shard_idx,shards_in_frame,payload_bytes,fate\n")
        fh.write("\n".join(lines) + "\n")
    return h.hexdigest()


def stats(tr, cal=CAL):
    fm = tr["frame_meta"]
    per = {0: [], 1: []}
    for (s, f, nbytes, ns, t0, idr) in fm:
        per[s].append((t0, nbytes, ns, idr))
    out = {}
    for s in (0, 1):
        v = per[s]
        gaps = [(v[i + 1][0] - v[i][0]) / 1000 for i in range(len(v) - 1)]
        out[f"s{s}"] = {
            "frames": len(v),
            "bytes_mean": sum(x[1] for x in v) / len(v),
            "bytes_max": max(x[1] for x in v),
            "shards_mean": sum(x[2] for x in v) / len(v),
            "shards_max": max(x[2] for x in v),
            "gap_mean_ms": sum(gaps) / len(gaps),
            "gap_max_ms": max(gaps),
            "idr_frames": sum(1 for x in v if x[3]),
        }
    rows = tr["rows"]
    kept = [r for r in rows if r[1] is not None]
    dur = tr["duration_s"]
    out["packets"] = len(rows)
    out["dropped_packets"] = len(rows) - len(kept)
    out["pps_total"] = len(rows) / dur
    out["frames_expected_incomplete"] = len(tr["drop_frames"])
    out["max_path_delay_ms"] = tr["max_delay_us"] / 1000
    out["delayed_gt15ms"] = sum(1 for r in kept if r[1] - r[0] > 15000)
    out["delayed_gt30ms"] = sum(1 for r in kept if r[1] - r[0] > 30000)
    out["net_events"] = len(tr["events"])
    out["producer_stalls"] = len(tr["stall_spans"])
    ts = [r[1] for r in kept]
    out["send_monotonic"] = all(ts[i] <= ts[i + 1] for i in range(len(ts) - 1))
    return out


def calibration_failures(st, cal=CAL):
    """Compare generated aggregates with the pinned measurements. Returns failure strings."""
    bad = []
    for s in ("s0", "s1"):
        v = st[s]
        if abs(v["bytes_mean"] / cal["frame_bytes_mean"] - 1) > 0.04:
            bad.append(f"{s} bytes_mean {v['bytes_mean']:.0f} vs {cal['frame_bytes_mean']:.0f}")
        if not 0.75 * cal["frame_bytes_max"] <= v["bytes_max"] <= RAW_FRAME_BYTES:
            bad.append(f"{s} bytes_max {v['bytes_max']}")
        if not cal["shards_mean"] - 0.8 <= v["shards_mean"] <= cal["shards_mean"] + 0.8:
            bad.append(f"{s} shards_mean {v['shards_mean']:.2f}")
        if v["shards_max"] > cal["shards_max"]:
            bad.append(f"{s} shards_max {v['shards_max']}")
        if abs(v["gap_mean_ms"] - 1000 / cal["fps"]) > 0.03:
            bad.append(f"{s} gap_mean_ms {v['gap_mean_ms']:.3f}")
    if not st["send_monotonic"]:
        bad.append("t_send not monotonic (reordering)")
    return bad


def parse_pacing_log(path):
    """Re-pin size/cadence numbers from 'Helix pacing baseline stream N:' lines."""
    rx = re.compile(r"frame_bytes\(avg/max\)=(\d+)/(\d+) frame_shards\(avg/max\)=(\d+)/(\d+).*?inter_frame_gap\(avg/max\)=(\d+)/(\d+)us")
    means, maxes, smax = [], [], []
    for line in open(path, errors="replace"):
        if "Helix pacing baseline stream" in line:
            m = rx.search(line)
            if m:
                means.append(int(m[1])); maxes.append(int(m[2])); smax.append(int(m[4]))
    if not means:
        raise SystemExit(f"no 'Helix pacing baseline' lines parsed in {path}")
    cal = dict(CAL)
    cal["frame_bytes_mean"] = sum(means) / len(means)
    cal["frame_bytes_max"] = max(maxes)
    cal["shards_max"] = max(smax)
    return cal


def self_test():
    ok = True
    a = generate(1, 120, "measured")
    b = generate(1, 120, "measured")
    h = lambda t: hashlib.sha256(repr(t["rows"]).encode()).hexdigest()
    c = generate(2, 120, "measured")
    det = h(a) == h(b) and h(a) != h(c)
    print(f"[1] determinism (same seed identical, different seed differs): {'PASS' if det else 'FAIL'}"); ok &= det

    full = generate(7, 900, "measured")
    st = stats(full)
    bad = calibration_failures(st)
    print(f"[2] calibration vs pinned measurements (900 s, measured profile): {'PASS' if not bad else 'FAIL ' + str(bad)}"); ok &= not bad
    print(f"    s0 mean {st['s0']['bytes_mean']:.0f} B max {st['s0']['bytes_max']} shards {st['s0']['shards_mean']:.2f}/{st['s0']['shards_max']} gap {st['s0']['gap_mean_ms']:.3f} ms")
    print(f"    {st['pps_total']:.0f} pps, {st['net_events']} path events, {st['producer_stalls']} producer stalls, max delay {st['max_path_delay_ms']:.1f} ms")

    need = st["producer_stalls"] >= 1 and st["net_events"] >= 1 and st["dropped_packets"] > 0 and st["delayed_gt15ms"] > 0
    print(f"[3] workload exercises stalls, drops and late survivors: {'PASS' if need else 'FAIL'}"); ok &= need

    # Mutation checks: deliberately wrong workloads must be rejected by the calibration gate.
    mut = []
    for name, over in (("2x frame size", {"frame_bytes_mean": CAL["frame_bytes_mean"] * 2.0}),
                       ("72 Hz cadence", {"fps": 72.0}),
                       ("tiny shards", {"shard_payload": 700})):
        m = dict(CAL); m.update(over)
        mst = stats(generate(7, 120, "measured", m))
        rejected = bool(calibration_failures(mst))  # judged against the pinned CAL, not the mutated one
        mut.append((name, rejected))
    all_rej = all(r for _, r in mut)
    print(f"[4] mutation checks rejected: {mut} -> {'PASS' if all_rej else 'FAIL'}"); ok &= all_rej

    # Event counts are Poisson, so compare over the maximum duration with a margin well below the 4x rate ratio.
    m_long = stats(generate(7, 1800, "measured"))
    t_long = stats(generate(7, 1800, "torture"))
    dens = t_long["net_events"] >= 2 * m_long["net_events"] and t_long["producer_stalls"] >= 2 * m_long["producer_stalls"]
    print(f"[5] torture profile denser than measured over 1800 s (events {t_long['net_events']} vs {m_long['net_events']}, "
          f"producer stalls {t_long['producer_stalls']} vs {m_long['producer_stalls']}): {'PASS' if dens else 'FAIL'}"); ok &= dens
    print("SELF-TEST", "PASS" if ok else "FAIL")
    return 0 if ok else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", help="trace file to write")
    ap.add_argument("--summary-json", help="write generation summary here")
    ap.add_argument("--seed", type=int, default=20261031)
    ap.add_argument("--duration", type=float, default=300.0, help="seconds (max 1800)")
    ap.add_argument("--profile", choices=sorted(PROFILES), default="torture")
    ap.add_argument("--calibrate-from", help="server log with 'Helix pacing baseline' lines")
    ap.add_argument("--self-test", action="store_true")
    a = ap.parse_args()
    if a.self_test:
        return self_test()
    if not a.out:
        ap.error("--out is required unless --self-test")
    if not 10 <= a.duration <= 1800:
        ap.error("--duration must be 10..1800 s")
    cal = parse_pacing_log(a.calibrate_from) if a.calibrate_from else CAL
    tr = generate(a.seed, a.duration, a.profile, cal)
    st = stats(tr, cal)
    bad = calibration_failures(st, cal)
    if bad:
        print("CALIBRATION GATE FAILED:", bad, file=sys.stderr)
        return 2
    digest = write_trace(tr, a.out)
    st["rows_sha256"] = digest
    st["events"] = tr["events"]
    st["producer_stall_spans_us"] = tr["stall_spans"]
    if a.summary_json:
        json.dump(st, open(a.summary_json, "w"), indent=1)
    print(f"wrote {a.out}: {st['packets']} packets, {st['dropped_packets']} path-dropped, "
          f"{st['frames_expected_incomplete']} frames expected incomplete, {st['net_events']} path events, "
          f"{st['producer_stalls']} producer stalls, max delay {st['max_path_delay_ms']:.1f} ms, sha256 {digest[:16]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
