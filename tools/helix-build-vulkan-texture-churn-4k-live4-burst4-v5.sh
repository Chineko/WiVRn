#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="a9053b0d67ff2e7e4fe03a4088580ff360469636"
BASE_BLOB="e248ed81bfd06f20781e1f7e3925842fe2e8a538"
BASE_PATH="tools/helix-build-vulkan-texture-churn-4k-live4-burst4-v4.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

[[ "$(git rev-parse "$BASE_COMMIT:$BASE_PATH")" == "$BASE_BLOB" ]] || fail "base v4 builder blob mismatch"
git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old="! grep -Fq -- '-Wno-unused' \"$TMP\" || fail \"warning suppression forbidden\""
if s.count(old) != 1:
    raise SystemExit(f'FAIL: v4 warning guard anchor count={s.count(old)}')
new='''COMPILE_LINE="$(grep -F 'timeout --signal=TERM --kill-after=5s 45s c++ ' "$TMP")"
[[ -n "$COMPILE_LINE" ]] || fail "compile command missing"
[[ "$(printf '%s\\n' "$COMPILE_LINE" | grep -c -- '-Wall -Wextra -Werror')" -eq 1 ]] || fail "strict Werror compile flags changed"
! printf '%s\\n' "$COMPILE_LINE" | grep -Fq -- '-Wno-' || fail "warning suppression present in compile command"'''
s=s.replace(old,new,1)
p.write_text(s)
PY

# This outer wrapper must not reintroduce the same false-positive self-scan.
[[ "$(grep -c 'warning suppression present in compile command' "$TMP")" -eq 1 ]] || fail "compile-line warning guard missing"

echo "PASS: v5 burst4 builder correction audit; warning_guard_scope=compile-command-only base_blob=$BASE_BLOB"
bash "$TMP"
