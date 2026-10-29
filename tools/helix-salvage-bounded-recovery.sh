#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
EXPECTED_FAILED_HEAD="2e74030b5f03d63a665e96f70890a1b1d5b77141"

fail() { echo "Helix salvage: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in git grep python3 sort tail; do need "$cmd"; done

[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH"

# Find only completed evidence directories from the failed v2/v3 run class.
mapfile -t candidates < <(find "$HOME" -maxdepth 1 -type d -name 'helix-bounded-recovery-*' -printf '%T@ %p\n' 2>/dev/null | sort -n | awk '{print $2}')
[[ ${#candidates[@]} -gt 0 ]] || fail "no helix-bounded-recovery output directory found"
OUT=${candidates[-1]}
META="$OUT/metadata.txt"
SERVER="$OUT/server-log.txt"
QUEST="$OUT/quest-logcat.txt"
RESULT="$OUT/result-salvaged.txt"

for path in "$META" "$SERVER" "$QUEST"; do
    [[ -s "$path" ]] || fail "missing/empty required artifact: $path"
done

runtime_head=$(awk -F= '$1=="runtime_head" {print $2; exit}' "$META")
[[ "$runtime_head" == "$EXPECTED_FAILED_HEAD" ]] || fail "latest evidence is for $runtime_head, expected failed run $EXPECTED_FAILED_HEAD"
runtime_short=${runtime_head:0:8}
grep -Fq "$runtime_short" "$SERVER" || fail "server artifact does not contain runtime id $runtime_short"

# The original v2 control flow could reach RUNTIME TEST ARMED only after:
#   * clean APK rebuild,
#   * adb install of org.meumeu.wivrn.local,
#   * readback of installed base.apk,
#   * native-library scan finding runtime_short,
#   * force-stop + automated launch of that exact package.
# The missing end-of-run startup line is therefore treated as a retention failure,
# not as proof of a mismatched APK. This salvage does not claim self-contained
# Quest provenance; it records that limitation explicitly.
python3 - "$SERVER" "$QUEST" "$RESULT" "$runtime_head" <<'PY'
import re
import sys
from pathlib import Path

server_path, quest_path, out_path, runtime_head = map(Path, sys.argv[1:4]) + [sys.argv[4]] if False else (Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3]), sys.argv[4])
server = server_path.read_text(errors="replace")
quest = quest_path.read_text(errors="replace")
out = out_path

def count(text, pattern):
    return len(re.findall(pattern, text, re.M))

def kv(line):
    return {k: int(v) for k, v in re.findall(r'\b([A-Za-z_]+)=(\d+)\b', line)}

vals = {
    'replay_events': count(server, r'Helix time-diverse replay '),
    'gap_events': count(server, r'Helix gap timing event '),
    'idr_needed': count(server, r'IDR frame needed'),
    'idr_retargeted': count(server, r'IDR frame retargeted'),
    'inconsistent_idr': count(server, r'inconsistent IDR state'),
    'idr_timeouts': count(server, r'IDR frame timeout'),
    'encoder_timeouts': count(server, r'Timeout on stream'),
    'quest_incomplete_frames': count(quest, r'frame .* was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
}
summary = re.findall(r'^.*Helix time-diverse summary.*$', server, re.M)
summary_kv = [kv(line) for line in summary]
vals['td_summary_lines'] = len(summary_kv)
vals['td_fresh_bytes'] = sum(x.get('fresh_bytes', 0) for x in summary_kv)
vals['td_replay_bytes'] = sum(x.get('replay_bytes', 0) for x in summary_kv)
vals['td_replayed_frames'] = sum(x.get('replayed', 0) for x in summary_kv)
vals['td_send_errors'] = sum(x.get('send_errors', 0) for x in summary_kv)
vals['td_expired'] = sum(x.get('expired', 0) for x in summary_kv)
rtx_summary = re.findall(r'^.*Helix RTX.*summary.*$', quest, re.M | re.I)

summary_integrity = bool(summary_kv) and vals['td_replayed_frames'] == vals['replay_events']
budget_ok = bool(summary_kv) and vals['td_replay_bytes'] * 5 <= vals['td_fresh_bytes']
hard_failure = bool(vals['inconsistent_idr'] or vals['idr_timeouts'] or vals['encoder_timeouts'] or vals['td_send_errors'])
quest_has_helix = 'Helix ' in quest

if vals['replay_events'] == 0:
    verdict = 'NONDIAGNOSTIC: no time-diverse replay event occurred'
elif not summary_kv:
    verdict = 'NONDIAGNOSTIC: replay occurred but no time-diverse shutdown summary was captured'
elif not summary_integrity:
    verdict = 'NONDIAGNOSTIC: replay event count does not reconcile with shutdown summary'
elif not budget_ok:
    verdict = 'FAIL: measured replay payload exceeded the frozen 20% long-run byte budget'
elif hard_failure:
    verdict = 'FAIL: recovery path executed but a hard recovery/encoder/send failure signal occurred'
elif vals['gap_events'] == 0:
    verdict = 'PROVISIONAL_PASS_EXECUTION_ONLY: replay path executed within budget without hard failures, but no gap event was observed'
else:
    verdict = 'PROVISIONAL_PASS: replay path executed during a run with gap events, stayed within budget, and showed no hard failure signals; effectiveness still requires event-level/baseline comparison'

lines = [
    verdict,
    '',
    f'runtime_head={runtime_head}',
    'quest_provenance=self-contained-no',
    'quest_provenance_basis=pre-arm installed-APK readback plus exact-package automated launch; startup identity line absent from retained end-of-run log',
    f'quest_has_helix_telemetry={str(quest_has_helix).lower()}',
]
lines += [f'{k}={v}' for k, v in vals.items()]
lines += [f'td_summary_integrity={str(summary_integrity).lower()}', f'td_budget_ok={str(budget_ok).lower()}']
if vals['td_fresh_bytes']:
    lines += [f'td_replay_ratio={vals["td_replay_bytes"] / vals["td_fresh_bytes"]:.6f}']
if summary:
    lines += ['', 'server_time_diverse_summaries:', *summary]
if rtx_summary:
    lines += ['', 'quest_rtx_summary:', rtx_summary[-1]]
out.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

echo
echo "Salvaged artifacts: $OUT"
echo "Result: $RESULT"
