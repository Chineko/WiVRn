#!/usr/bin/env bash
set -euo pipefail

BASE_AUDIT_COMMIT="74625827a2eddb484944f2e847359313d6f02c8f"
BASE_AUDIT_BLOB="10389d463b973daee0cdc5de9d0ea958f836897a"
BASE_PATH="tools/helix-audit-encoded-network-sustained-5min-texture-bank32-20f-churn4k-live4-burst4-v1.sh"
EXPECTED_BUILD_TOOLING="c3ed8c824a98b4cada80d635787c6af788084583"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse "$BASE_AUDIT_COMMIT:$BASE_PATH")" == "$BASE_AUDIT_BLOB" ]] || fail "base v1 audit blob mismatch"
git show "$BASE_AUDIT_COMMIT:$BASE_PATH" > "$TMP"

python3 - "$TMP" "$EXPECTED_BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); new=sys.argv[2]; s=p.read_text()
old='EXPECTED_BUILD_TOOLING="dbfea104b250d9271839d0912b6b4a50a6170dcd"'
repl=f'EXPECTED_BUILD_TOOLING="{new}"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: tooling binding count={s.count(old)}')
s=s.replace(old,repl,1)
anchor="grep -Fqx 'source_delta=PASS frozen-live4-only-temporal-upload-shape-smooth2s-to-burst4-dwell8s' \"$CHURN_META\" || fail \"source delta mismatch\""
if s.count(anchor) != 1:
    raise SystemExit(f'FAIL: audit anchor count={s.count(anchor)}')
s=s.replace(anchor, anchor+'\n! grep -Fq \'auto next=\' "$CHURN_SRC" || fail "stale dead next variable present"',1)
p.write_text(s)
PY

grep -Fqx "EXPECTED_BUILD_TOOLING=\"$EXPECTED_BUILD_TOOLING\"" "$TMP" || fail "corrected tooling binding missing"
grep -Fq 'stale dead next variable present' "$TMP" || fail "dead-next runtime audit missing"
echo "PASS: v2 burst4 runtime-audit correction; tooling=$EXPECTED_BUILD_TOOLING dead_next_guard=present base_blob=$BASE_AUDIT_BLOB"
bash "$TMP"
