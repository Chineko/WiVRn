#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
SOURCE_BASE="fa68cb3af0e0dfcb5e683abd951dfe0d2a126336"
SELF_PATH="tools/helix-recover-bounded-runtime.sh"

fail() { echo "Helix salvage gate: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in awk cp cut date find git grep head python3 sort; do need "$cmd"; done

[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH"
git cat-file -e "$SOURCE_BASE^{commit}" 2>/dev/null || fail "frozen source base $SOURCE_BASE is not available locally"

# Exact artifact gate: the helper on disk must be byte-identical to the helper
# committed at the checked-out HEAD. This detects stale/locally edited tooling.
HEAD_SELF_BLOB=$(git rev-parse "HEAD:$SELF_PATH" 2>/dev/null || true)
[[ "$HEAD_SELF_BLOB" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve $SELF_PATH at HEAD"
SELF_BLOB=$(git hash-object "$SELF_PATH")
[[ "$SELF_BLOB" == "$HEAD_SELF_BLOB" ]] || fail "local salvage helper differs from HEAD artifact"

OUT=${1:-}
if [[ -z "$OUT" ]]; then
    OUT=$(find "$HOME" -maxdepth 1 -type d -name 'helix-bounded-recovery-*' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)
fi
[[ -n "$OUT" && -d "$OUT" ]] || fail "bounded-recovery output directory not found"

DASH_OUT="$OUT/dashboard-stdout.txt"
QUEST_LOG="$OUT/quest-logcat.txt"
METADATA="$OUT/metadata.txt"
RESULT="$OUT/result.txt"
[[ -s "$DASH_OUT" ]] || fail "missing $DASH_OUT"
[[ -s "$QUEST_LOG" ]] || fail "missing $QUEST_LOG; completed run cannot be salvaged without Quest logcat"
[[ -s "$METADATA" ]] || fail "missing $METADATA"

RECORDED_SOURCE_BASE=$(awk -F= '$1=="source_base"{print $2; exit}' "$METADATA")
RUNTIME_HEAD=$(awk -F= '$1=="runtime_head"{print $2; exit}' "$METADATA")
CAPTURE_START=$(awk -F= '$1=="capture_start_epoch"{print $2; exit}' "$METADATA")
[[ "$RECORDED_SOURCE_BASE" == "$SOURCE_BASE" ]] || fail "run source_base is $RECORDED_SOURCE_BASE, expected $SOURCE_BASE"
[[ "$RUNTIME_HEAD" =~ ^[0-9a-f]{40}$ ]] || fail "runtime_head missing or invalid in metadata"
[[ "$CAPTURE_START" =~ ^[0-9]+$ ]] || fail "capture_start_epoch missing or invalid in metadata"
git cat-file -e "$RUNTIME_HEAD^{commit}" 2>/dev/null || fail "recorded runtime commit $RUNTIME_HEAD is not available locally"

# The tested runtime may contain later docs/tools commits, but executable source must
# remain byte-equivalent to the frozen prototype. Check the complete repository diff
# excluding only the two explicitly non-runtime trees.
if ! git diff --quiet "$SOURCE_BASE" "$RUNTIME_HEAD" -- . ':(exclude)docs/**' ':(exclude)tools/**'; then
    fail "tested runtime $RUNTIME_HEAD changes executable source relative to frozen prototype $SOURCE_BASE"
fi

SERVER_LOG=$(python3 - "$DASH_OUT" <<'PY'
import re, sys
from pathlib import Path
text = Path(sys.argv[1]).read_text(errors='replace')
matches = re.findall(r'Saving logs in\s+"([^"]*server_logs_[^"]+\.txt)"', text)
if not matches:
    raise SystemExit(2)
print(matches[-1])
PY
) || fail "dashboard output did not contain authoritative 'Saving logs in ...' path"
[[ "$SERVER_LOG" == /* ]] || fail "dashboard-reported server log path is not absolute: $SERVER_LOG"
[[ -s "$SERVER_LOG" ]] || fail "dashboard-reported server log is missing/empty: $SERVER_LOG"

RUNTIME_SHORT=${RUNTIME_HEAD:0:8}
grep -F "$RUNTIME_SHORT" "$SERVER_LOG" >/dev/null || fail "server log does not contain tested runtime id $RUNTIME_SHORT"
grep -F "$RUNTIME_SHORT" "$QUEST_LOG" >/dev/null || fail "Quest log does not contain tested runtime id $RUNTIME_SHORT"

# Only after all provenance gates pass do we copy/write into the evidence directory.
cp "$SERVER_LOG" "$OUT/server-log.txt"
printf 'server_log_source=%s\nrecovered_utc=%s\n' "$SERVER_LOG" "$(date -u +%FT%TZ)" >>"$METADATA"

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
    'quest_incomplete_frames': count(quest, r'frame .* was not sent (?:because|with)'),
    'quest_old_shards': count(quest, r'Drop shard for old frame'),
}
summary = re.findall(r'^.*Helix time-diverse summary.*$', server, re.M)
rtx_summary = re.findall(r'^.*Helix RTX.*summary.*$', quest, re.M | re.I)

# The first runtime decision is deliberately narrow: did the mechanism actually
# execute without a hard recovery-state failure? Improvement is not claimed here.
if vals['replay_events'] == 0:
    verdict = 'NONDIAGNOSTIC: no time-diverse replay event occurred'
elif vals['inconsistent_idr'] or vals['idr_timeouts'] or vals['encoder_timeouts']:
    verdict = 'FAIL: recovery path executed but a hard recovery/encoder failure signal occurred'
else:
    verdict = 'PROVISIONAL_PASS: time-diverse path executed without hard failure signals; effectiveness still requires baseline comparison'

lines = [verdict, '']
lines += [f'{k}={v}' for k, v in vals.items()]
if summary:
    lines += ['', 'server_time_diverse_summary:', summary[-1]]
else:
    lines += ['', 'warning=no Helix time-diverse summary found; shutdown summary evidence is unavailable']
if rtx_summary:
    lines += ['', 'quest_rtx_summary:', rtx_summary[-1]]
out.write_text('\n'.join(lines) + '\n')
print('\n'.join(lines))
PY

echo
echo "Recovered existing runtime evidence: $OUT"
echo "Result: $RESULT"
