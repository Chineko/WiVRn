#!/usr/bin/env python3
from __future__ import annotations
import argparse, json, random
from dataclasses import dataclass, asdict

FRAME_MS=11.1
SHARDS_PER_FRAME=21.0
SOURCE_SHARDS_PER_MS=SHARDS_PER_FRAME/FRAME_MS
RECEIVER_WINDOW_MS=2.0*FRAME_MS
EVENTS=((1,1,23,10.254,28.655),(2,0,38,12.014,31.769),(3,0,42,22.099,32.998),(4,1,48,14.480,39.243),(5,1,29,14.580,13.628),(6,0,31,21.775,16.707),(7,0,59,23.420,56.901),(8,1,47,12.854,64.543),(9,1,33,10.789,19.825),(10,0,46,11.959,14.086))
INCOMPLETE_FRAMES=36
ZERO_SHARD_INCOMPLETE_FRAMES=31
INTRA_REFRESH_SCHEDULES=((100,50),(30,5),(20,4),(15,3),(10,2))

@dataclass(frozen=True)
class EventResult:
    event_id:int; stream:int; missing_shards:int; send_span_ms:float; report_delay_ms:float
    earliest_age_at_report_ms:float; report_before_deadline:bool; post_burst_budget_ms:float
    max_post_burst_symbols:dict[str,float]

EXP=[0]*512; LOG=[0]*256
x=1
for i in range(255):
    EXP[i]=x; LOG[x]=i; x <<= 1
    if x & 0x100: x ^= 0x11D
for i in range(255,512): EXP[i]=EXP[i-255]
def gf_mul(a,b): return 0 if a==0 or b==0 else EXP[LOG[a]+LOG[b]]
def gf_inv(a):
    if a==0: raise ZeroDivisionError
    return EXP[255-LOG[a]]
def solve_gf256(a,b):
    n=len(a)
    if n==0 or any(len(r)!=n for r in a): raise ValueError("A must be non-empty square")
    width=len(b[0])
    if len(b)!=n or any(len(r)!=width for r in b): raise ValueError("B shape mismatch")
    aug=[a[i][:]+b[i][:] for i in range(n)]
    for col in range(n):
        pivot=next((r for r in range(col,n) if aug[r][col]),None)
        if pivot is None: raise ValueError("rank deficient")
        aug[col],aug[pivot]=aug[pivot],aug[col]
        inv=gf_inv(aug[col][col]); aug[col]=[gf_mul(v,inv) for v in aug[col]]
        for r in range(n):
            if r==col: continue
            factor=aug[r][col]
            if factor: aug[r]=[v ^ gf_mul(factor,p) for v,p in zip(aug[r],aug[col])]
    return [row[n:] for row in aug]
def matrix_self_test(cases=1000,seed=0x48454C4958):
    rng=random.Random(seed)
    for _ in range(cases):
        n=rng.randint(1,8); width=rng.randint(1,32)
        a=[[1 if r==c else 0 for c in range(n)] for r in range(n)]
        for _ in range(n*4):
            if n>1: r1,r2=rng.sample(range(n),2)
            else: r1=r2=0
            if n>1 and rng.random()<0.5: a[r1],a[r2]=a[r2],a[r1]
            else:
                f=rng.randint(1,255)
                if r1==r2: a[r1]=[gf_mul(v,f) for v in a[r1]]
                else: a[r1]=[v ^ gf_mul(f,w) for v,w in zip(a[r1],a[r2])]
        x_true=[[rng.randrange(256) for _ in range(width)] for _ in range(n)]
        b=[]
        for row in a:
            out=[0]*width
            for coeff,src in zip(row,x_true):
                if coeff: out=[v ^ gf_mul(coeff,s) for v,s in zip(out,src)]
            b.append(out)
        if solve_gf256(a,b)!=x_true: raise AssertionError("GF256 reconstruction mismatch")

def analyze_prediction_recovery():
    schedules=[]
    for period,count in INTRA_REFRESH_SCHEDULES:
        avg_frames=period/2.0+count
        worst_frames=period+count
        schedules.append({
            "period_frames":period,
            "refresh_count_frames":count,
            "equivalent_intra_area_fraction":1.0/period,
            "average_full_refresh_ms_bound":avg_frames*FRAME_MS,
            "worst_full_refresh_ms_bound":worst_frames*FRAME_MS,
        })
    events=[]
    for eid,stream,missing,span,delay in EVENTS:
        age=span+delay
        events.append({
            "event_id":eid,
            "stream":stream,
            "report_age_ms":age,
            "ltr_invalidation_future_containment_ms_bound":age+FRAME_MS,
        })
    ages=[e["report_age_ms"] for e in events]
    contain=[e["ltr_invalidation_future_containment_ms_bound"] for e in events]
    return {
        "model_note":"Reference invalidation cannot reconstruct frames already damaged before feedback. If an older decoded short/long-term reference is available, future frames can stop using the invalidated reference; +1 frame is a conservative simulator allowance, not a runtime measurement.",
        "gap_report_age_ms":{"min":min(ages),"max":max(ages),"average":sum(ages)/len(ages)},
        "ltr_invalidation_future_containment_ms_bound":{"min":min(contain),"max":max(contain),"average":sum(contain)/len(contain)},
        "events":events,
        "intra_refresh_schedules":schedules,
    }

def analyze(rates):
    results=[]
    for eid,stream,missing,span,delay in EVENTS:
        age=span+delay
        post=max(0.0,RECEIVER_WINDOW_MS-span)
        symbols={f"{int(rate*100)}%":post*SOURCE_SHARDS_PER_MS*rate for rate in rates}
        results.append(EventResult(eid,stream,missing,span,delay,age,age<RECEIVER_WINDOW_MS,post,symbols))
    z=ZERO_SHARD_INCOMPLETE_FRAMES/INCOMPLETE_FRAMES
    return {
        "assumptions":{"frame_ms":FRAME_MS,"shards_per_frame":SHARDS_PER_FRAME,"receiver_window_ms":RECEIVER_WINDOW_MS,"source_shards_per_ms":SOURCE_SHARDS_PER_MS,"information_bound":"N arbitrary missing source shards require at least N independent repair symbols"},
        "prediction_recovery":analyze_prediction_recovery(),
        "recorded_receiver_outcomes":{"incomplete_frames":INCOMPLETE_FRAMES,"zero_shard_incomplete_frames":ZERO_SHARD_INCOMPLETE_FRAMES,"zero_shard_fraction":z},
        "events":[asdict(r) for r in results],
        "summary":{"event_count":len(results),"reports_before_current_next_deadline":sum(r.report_before_deadline for r in results),"reports_too_late":sum(not r.report_before_deadline for r in results),"smallest_missing_shards":min(r.missing_shards for r in results),"largest_missing_shards":max(r.missing_shards for r in results),"max_best_case_post_burst_symbols":{f"{int(rate*100)}%":max(r.max_post_burst_symbols[f"{int(rate*100)}%"] for r in results) for rate in rates},"decision":"Existing gap-report-triggered full repair is too late for all recorded events. Low-rate matrix coding remains useful for partial/edge losses, while full-frame erasure needs prediction-chain containment. Reference invalidation/LTR can bound future dependency after feedback without a steady-state network tax; faster intra refresh is a bandwidth-neutral CBR trade of compression quality for recovery speed."}
    }
def main():
    p=argparse.ArgumentParser(); p.add_argument("--json",action="store_true"); p.add_argument("--self-test-cases",type=int,default=1000); args=p.parse_args()
    matrix_self_test(args.self_test_cases); report=analyze((0.04,0.08,0.10,0.20))
    if args.json:
        print(json.dumps(report,indent=2,sort_keys=True)); return 0
    print(f"GF256 self-test: PASS ({args.self_test_cases} cases)")
    a=report["assumptions"]; o=report["recorded_receiver_outcomes"]; s=report["summary"]; pr=report["prediction_recovery"]
    print(f"receiver window={a['receiver_window_ms']:.1f}ms; source rate={a['source_shards_per_ms']:.3f} shards/ms")
    print(f"recorded incomplete frames={o['incomplete_frames']}; zero-shard={o['zero_shard_incomplete_frames']} ({o['zero_shard_fraction']:.1%})")
    print("id miss span_ms report_ms age_at_report deadline? postburst_ms 4%eq 8%eq 20%eq")
    for e in report["events"]:
        print(f"{e['event_id']:2d} {e['missing_shards']:4d} {e['send_span_ms']:7.3f} {e['report_delay_ms']:9.3f} {e['earliest_age_at_report_ms']:13.3f} {'yes' if e['report_before_deadline'] else 'NO ':>8} {e['post_burst_budget_ms']:11.3f} {e['max_post_burst_symbols']['4%']:4.1f} {e['max_post_burst_symbols']['8%']:4.1f} {e['max_post_burst_symbols']['20%']:5.1f}")
    print(f"gap reports before deadline: {s['reports_before_current_next_deadline']}/{s['event_count']}")
    ages=pr["gap_report_age_ms"]; ltr=pr["ltr_invalidation_future_containment_ms_bound"]
    print(f"gap report age min/avg/max={ages['min']:.1f}/{ages['average']:.1f}/{ages['max']:.1f}ms")
    print(f"LTR invalidation future-containment bound min/avg/max={ltr['min']:.1f}/{ltr['average']:.1f}/{ltr['max']:.1f}ms")
    print("intra-refresh schedule bounds (period/count, intra-area, avg/worst full-clean):")
    for ir in pr["intra_refresh_schedules"]:
        print(f"  {ir['period_frames']}/{ir['refresh_count_frames']}: {ir['equivalent_intra_area_fraction']:.1%}, {ir['average_full_refresh_ms_bound']:.1f}/{ir['worst_full_refresh_ms_bound']:.1f}ms")
    print("Decision:",s["decision"]); return 0
if __name__=="__main__": raise SystemExit(main())
