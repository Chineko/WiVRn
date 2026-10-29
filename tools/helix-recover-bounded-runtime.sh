#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

OUT=${1:-}
if [[ -z "$OUT" ]]; then
    OUT=$(find "$HOME" -maxdepth 1 -type d -name 'helix-bounded-recovery-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[[ -n "$OUT" && -d "$OUT" ]] || { echo "error: bounded-recovery output directory not found" >&2; exit 2; }

DASH_OUT="$OUT/dashboard-stdout.txt"
QUEST_LOG="$OUT/quest-logcat.txt"
RESULT="$OUT/result.txt"
[[ -s "$DASH_OUT" ]] || { echo "error: missing $DASH_OUT" >&2; exit 2; }
[[ -s "$QUEST_LOG" ]] || { echo "error: missing $QUEST_LOG; completed run cannot be salvaged without Quest logcat" >&2; exit 2; }

SERVER_LOG=$(python3 - "$DASH_OUT" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
matches = re.findall(r'Saving logs in\s+"([^"]*server_logs_[^"]+\.txt)"', text)
if not matches:
    raise SystemExit(2)
print(matches[-1])
PY
) || { echo "error: dashboard output did not contain authoritative 'Saving logs in ...' path" >&2; exit 2; }
[[ -s "$SERVER_LOG" ]] || { echo "error: dashboard-reported server log is missing/empty: $SERVER_LOG" >&2; exit 2; }
cp "$SERVER_LOG" "$OUT/server-log.txt"
printf 'server_log_source=%s\nrecovered_utc=%s\n' "$SERVER_LOG" "$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

RUNTIME_HEAD=$(awk -F= '$1=="runtime_head"{print $2; exit}' "$OUT/metadata.txt" 2>/dev/null || true)
[[ -n "$RUNTIME_HEAD" ]] || { echo "error: runtime_head missing from metadata" >&2; exit 2; }
RUNTIME_SHORT=${RUNTIME_HEAD:0:8}

grep -F "$RUNTIME_SHORT" "$OUT/server-log.txt" >/dev/null || { echo "error: server log does not contain runtime id $RUNTIME_SHORT" >&2; exit 2; }
grep -F "$RUNTIME_SHORT" "$QUEST_LOG" >/dev/null || { echo "error: Quest log does not contain runtime id $RUNTIME_SHORT" >&2; exit 2; }

python3 - "$OUT/server-log.txt" "$QUEST_LOG" "$RESULT" <<'PY'
import re, sys
from pathlib import Path
server = Path(sys.argv[1]).read_text(errors='replace')
quest = Path(sys.argv[2]).read_text(errors='replace')
out = Path(sys.argv[3])

def count(text, pattern):
    return len(re.findall(pattern, text, re.M))

vals = {
    'replay_events': count(server, r'Helix time-diverse replay '),
    'gap_events': count(server, r'Helix gap timing event '),
    'idr_needed': count(server, r'IDR frame needed'),
    'idr_retargeted': count(server, r'IDR frame retargeted'),
    'inconsistent_idr': count(server, r'inconsistent IDR state'),
    'idr_timeouts': count(server, r'IDR frame timeout'),
    'encoder_timeouts': count(server, r'Timeout on stream'),
    'quest_incomplete_frames': count(quest, r'was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
}
summary = re.findall(r'^.*Helix time-diverse summary.*$', server, re.M)
rtx_summary = re.findall(r'^.*Helix RTX.*summary.*$', quest, re.M | re.I)

if vals['replay_events'] == 0:
    verdict = 'NONDIAGNOSTIC: no time-diverse replay event occurred'
elif vals['inconsistent_idr'] or vals['idr_timeouts'] or vals['encoder_timeouts']:
    verdict = 'FAIL: recovery path executed but a hard recovery/encoder failure signal occurred'
else:
    verdict = 'PROVISIONAL_PASS: time-diverse path executed without hard failure signals; compare incomplete-frame/IDR fallout to baseline before promotion'

lines = [verdict, '']
lines += [f'{k}={v}' for k, v in vals.items()]
if summary:
    lines += ['', 'server_time_diverse_summary:', summary[-1]]
if rtx_summary:
    lines += ['', 'quest_rtx_summary:', rtx_summary[-1]]
out.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

echo
echo "Recovered existing runtime evidence: $OUT"
echo "Result: $RESULT"
