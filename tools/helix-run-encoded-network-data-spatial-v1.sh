#!/usr/bin/env bash
set -euo pipefail

PINNED_BATCH_COMMIT="633d92ada967d64ae00c657ae80baa73ec861f79"
PINNED_BATCH_PATH="tools/helix-run-encoded-network-data-baseline-v1.sh"
START_DELAY="${HELIX_START_DELAY:-20}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 sleep seq printf; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
[[ "$START_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_START_DELAY must be a nonnegative integer"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git cat-file -e "${PINNED_BATCH_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_BATCH_COMMIT"
git show "${PINNED_BATCH_COMMIT}:${PINNED_BATCH_PATH}" > "$tmp"

python3 - "$tmp" "$START_DELAY" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); delay=sys.argv[2]
s=p.read_text()
old='''position_label=$POSITION_LABEL\nstarted_at=$(date --iso-8601=seconds)\nEOF\n\necho '[audit] Frozen encoded-network measurement instrument'\n'''
new=f'''position_label=$POSITION_LABEL\nstart_delay_seconds={delay}\nstarted_at=$(date --iso-8601=seconds)\nEOF\n\necho '[audit] Frozen encoded-network measurement instrument'\n'''
if s.count(old) != 1:
    raise SystemExit('FAIL: metadata insertion anchor count='+str(s.count(old)))
s=s.replace(old,new,1)
old2='''grep -Fq 'ENCODED_NETWORK_PATH_GATE=PASS' "$OUT/precheck.log" || fail "network path precheck missing"\n\necho 'run,status,evidence,started_at,finished_at' > "$OUT/run-index.csv"\n'''
new2=f'''grep -Fq 'ENCODED_NETWORK_PATH_GATE=PASS' "$OUT/precheck.log" || fail "network path precheck missing"\n\necho "SPATIAL_START_DELAY seconds={delay}"\nfor ((remaining={delay}; remaining>0; remaining--)); do\n    printf '\\rStarting spatial batch in %2d s ' "$remaining"\n    sleep 1\ndone\nprintf '\\rStarting spatial batch now      \\n'\n\necho 'run,status,evidence,started_at,finished_at' > "$OUT/run-index.csv"\n'''
if s.count(old2) != 1:
    raise SystemExit('FAIL: countdown insertion anchor count='+str(s.count(old2)))
s=s.replace(old2,new2,1)
# Verify only orchestration text was added around the frozen batch logic.
for required in [
    'PINNED_RUNNER_COMMIT="b2111b38e734c3c22c65ca0a3450008afc016edc"',
    'HELIX_PRECHECK_ONLY=1 bash "$RUNNER"',
    'bash "$RUNNER" 2>&1 | tee "$log"',
    'scenario-data.csv',
    f'SPATIAL_START_DELAY seconds={delay}',
]:
    if required not in s:
        raise SystemExit('FAIL: spatial wrapper requirement missing: '+required)
p.write_text(s)
PY

bash -n "$tmp"
echo "SPATIAL_TIMER_AUDIT=PASS pinned-batch=$PINNED_BATCH_COMMIT delay=${START_DELAY}s harness-unchanged"
exec bash "$tmp"
