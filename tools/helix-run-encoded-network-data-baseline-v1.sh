#!/usr/bin/env bash
set -euo pipefail

PINNED_RUNNER_COMMIT="b2111b38e734c3c22c65ca0a3450008afc016edc"
PINNED_RUNNER_PATH="tools/helix-run-encoded-nvenc-torture-network-promotion-v1.sh"
RUNS="${HELIX_RUNS:-10}"
INTER_RUN_DELAY="${HELIX_INTER_RUN_DELAY:-5}"
POSITION_LABEL="${HELIX_POSITION_LABEL:-fixed_baseline}"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/helix-encoded-network-data-$STAMP"
RUNNER="$OUT/frozen-runner.sh"
mkdir -p "$OUT/runs"

fail(){ echo "FAIL: $*" >&2; echo "batch_evidence=$OUT" >&2; exit 2; }
for c in git bash python3 awk grep sed tee date sleep mkdir cp sha256sum; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
[[ "$RUNS" =~ ^[1-9][0-9]*$ ]] || fail "HELIX_RUNS must be a positive integer"
[[ "$INTER_RUN_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_INTER_RUN_DELAY must be a nonnegative integer"

git cat-file -e "${PINNED_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_RUNNER_COMMIT"
git show "${PINNED_RUNNER_COMMIT}:${PINNED_RUNNER_PATH}" > "$RUNNER"
chmod +x "$RUNNER"
bash -n "$RUNNER"
RUNNER_SHA256="$(sha256sum "$RUNNER" | awk '{print $1}')"

cat > "$OUT/batch-metadata.txt" <<EOF
batch_version=encoded-network-data-baseline-v1
pinned_runner_commit=$PINNED_RUNNER_COMMIT
pinned_runner_path=$PINNED_RUNNER_PATH
pinned_runner_sha256=$RUNNER_SHA256
runs_requested=$RUNS
inter_run_delay_seconds=$INTER_RUN_DELAY
position_label=$POSITION_LABEL
started_at=$(date --iso-8601=seconds)
EOF

# Full strict audit once, with no runtime. Every real trial below reruns the same
# runner's own gates, but this prevents entering the batch if the frozen
# instrument/artifact/LAN composition is not currently valid.
echo '[audit] Frozen encoded-network measurement instrument'
HELIX_PRECHECK_ONLY=1 bash "$RUNNER" | tee "$OUT/precheck.log"
grep -Fq 'ENCODED_NETWORK_AUDIT_A=PASS' "$OUT/precheck.log" || fail "Audit A precheck missing"
grep -Fq 'ENCODED_NETWORK_AUDIT_B=PASS' "$OUT/precheck.log" || fail "Audit B precheck missing"
grep -Fq 'ENCODED_NETWORK_PATH_GATE=PASS' "$OUT/precheck.log" || fail "network path precheck missing"

echo 'run,status,evidence,started_at,finished_at' > "$OUT/run-index.csv"

for ((i=1; i<=RUNS; i++)); do
    n="$(printf '%02d' "$i")"
    log="$OUT/runs/run-$n.console.txt"
    started="$(date --iso-8601=seconds)"
    echo "[$i/$RUNS] encoded NVENC network trial position=$POSITION_LABEL"
    set +e
    bash "$RUNNER" 2>&1 | tee "$log"
    status=${PIPESTATUS[0]}
    set -e
    finished="$(date --iso-8601=seconds)"
    evidence="$(sed -n 's/^evidence=//p' "$log" | tail -1)"
    if [[ -z "$evidence" ]]; then
        evidence="$(sed -n 's/^EVIDENCE=//p' "$log" | tail -1)"
    fi
    printf '%s,%s,%s,%s,%s\n' "$i" "$status" "$evidence" "$started" "$finished" >> "$OUT/run-index.csv"
    if [[ "$i" -lt "$RUNS" && "$INTER_RUN_DELAY" -gt 0 ]]; then
        sleep "$INTER_RUN_DELAY"
    fi
done

python3 - "$OUT" <<'PY'
from pathlib import Path
import csv,re,sys
root=Path(sys.argv[1])
index=list(csv.DictReader((root/'run-index.csv').open()))
scenario_rows=[]
summary_rows=[]

def kv(line):
    return dict(re.findall(r'([A-Za-z_]+)=([^\s]+)', line))

for row in index:
    run=int(row['run'])
    ev=Path(row['evidence']) if row['evidence'] else None
    status=int(row['status'])
    result=''
    server=''
    if ev and ev.is_dir():
        rp=ev/'result.txt'
        sp=ev/'server-log.txt'
        if rp.exists(): result=rp.read_text(errors='replace')
        if sp.exists(): server=sp.read_text(errors='replace')
    verdict='UNKNOWN'
    m=re.search(r'^verdict=(\S+)',result,re.M)
    if m: verdict=m.group(1)
    counts=re.search(r'^injections=(\d+) feedback=(\d+) recoveries=(\d+) invalidations=(\d+)',result,re.M)
    errors=re.search(r'^errors=(.*)$',result,re.M)
    summary_rows.append({
        'run':run,'exit_status':status,'verdict':verdict,
        'injections':counts.group(1) if counts else '',
        'feedback':counts.group(2) if counts else '',
        'recoveries':counts.group(3) if counts else '',
        'invalidations':counts.group(4) if counts else '',
        'errors':errors.group(1) if errors else '',
        'evidence':str(ev) if ev else '',
    })
    lines=server.splitlines()
    inj={}; done={}; fb={}; rec={}; inv=[]
    for line in lines:
        d=kv(line)
        if 'HELIX_ENCODED_INJECT scenario=' in line: inj[d.get('scenario')]=d
        elif 'HELIX_ENCODED_INJECT_DONE' in line: done[d.get('scenario')]=d
        elif 'HELIX_ENCODED_FEEDBACK' in line: fb[d.get('scenario')]=d
        elif 'HELIX_ENCODED_RECOVERY' in line: rec[d.get('scenario')]=d
        elif 'HELIX_ENCODED_INVALIDATION' in line: inv.append(d)
    for scenario in ('rtx8','gap9','full_reference'):
        a=inj.get(scenario,{}) ; b=done.get(scenario,{}) ; c=fb.get(scenario,{}) ; d=rec.get(scenario,{})
        frame=a.get('frame','')
        inv_match=next((x for x in inv if x.get('stream')=='0' and x.get('frame')==frame),{})
        scenario_rows.append({
            'run':run,'scenario':scenario,'run_verdict':verdict,
            'inject_frame':frame,'encoded_bytes':a.get('encoded_bytes',''),
            'drop_first':a.get('drop_first',''),'drop_count':a.get('drop_count',''),
            'dropped':b.get('dropped',''),'total_shards':b.get('total_shards',''),
            'sent_to_decoder':c.get('sent_to_decoder',''),
            'recovered_frame':d.get('recovered_frame',''),'recovery_delta':d.get('delta',''),
            'recovery_mode':d.get('mode',''),'invalidation_action':inv_match.get('action',''),
            'evidence':str(ev) if ev else '',
        })

with (root/'run-summary.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(summary_rows[0].keys()) if summary_rows else ['run'])
    w.writeheader(); w.writerows(summary_rows)
with (root/'scenario-data.csv').open('w',newline='') as f:
    w=csv.DictWriter(f,fieldnames=list(scenario_rows[0].keys()) if scenario_rows else ['run'])
    w.writeheader(); w.writerows(scenario_rows)

passed=sum(1 for r in summary_rows if r['exit_status']==0 and r['verdict']=='PASS')
print(f'BASELINE_DATA_BATCH_COMPLETE runs={len(summary_rows)} passed={passed} failed={len(summary_rows)-passed}')
print(f'run_summary={root/"run-summary.csv"}')
print(f'scenario_data={root/"scenario-data.csv"}')
print(f'batch_evidence={root}')
PY
