#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="c3ed8c824a98b4cada80d635787c6af788084583"
BASE_BLOB="939f02b6646b26fc1e88a2fc768a8c691f6c8675"
BASE_PATH="tools/helix-build-vulkan-texture-churn-4k-live4-burst4-v2.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

[[ "$(git rev-parse "$BASE_COMMIT:$BASE_PATH")" == "$BASE_BLOB" ]] || fail "base v2 builder blob mismatch"
git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

old="p.write_text(s)\nPYFIX"
if s.count(old) != 1:
    raise SystemExit(f'FAIL: PYFIX write anchor count={s.count(old)}')
insert=(
    "start='const auto start=std::chrono::steady_clock::now();'\n"
    "if s.count(start) != 1:\n"
    "    raise SystemExit(f'FAIL: stale start declaration count={s.count(start)}')\n"
    "s=s.replace(start, '', 1)\n"
    "if 'auto next=' in s:\n"
    "    raise SystemExit('FAIL: stale next declaration remains')\n"
    "if 'const auto start=' in s:\n"
    "    raise SystemExit('FAIL: stale start declaration remains')\n"
    "p.write_text(s)\nPYFIX"
)
s=s.replace(old, insert, 1)

old_guard="! grep -Fq 'auto next=' \"$SRC\" || fail \"dead next variable remains\""
if s.count(old_guard) != 1:
    raise SystemExit(f'FAIL: dead-next guard anchor count={s.count(old_guard)}')
new_guard=old_guard + "\n! grep -Fq 'const auto start=' \"$SRC\" || fail \"dead start variable remains\""
s=s.replace(old_guard,new_guard,1)
p.write_text(s)
PY

[[ "$(grep -c -- '-Wall -Wextra -Werror' "$TMP")" -eq 1 ]] || fail "strict Werror compile flags changed"
! grep -Fq -- '-Wno-unused' "$TMP" || fail "warning suppression forbidden"

echo "PASS: v4 burst4 builder correction audit; dead_timing_pair_removal=counted quoting_safe=yes strict_werror=preserved base_blob=$BASE_BLOB"
bash "$TMP"
