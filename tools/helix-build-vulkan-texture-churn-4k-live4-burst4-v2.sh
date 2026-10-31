#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="dbfea104b250d9271839d0912b6b4a50a6170dcd"
BASE_BLOB="fd75f3790b6eb0257dd43914fb093e347b660fbe"
BASE_PATH="tools/helix-build-vulkan-texture-churn-4k-live4-burst4-v1.sh"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

[[ "$(git rev-parse "$BASE_COMMIT:$BASE_PATH")" == "$BASE_BLOB" ]] || fail "base v1 builder blob mismatch"
git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"

python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
anchor="echo '[1/2] Compiling deterministic live4 burst4 4K Vulkan churn companion'"
if s.count(anchor) != 1:
    raise SystemExit(f'FAIL: compile anchor count={s.count(anchor)}')
fix=r'''python3 - "$SRC" <<'PYFIX'
from pathlib import Path
import re, sys
p=Path(sys.argv[1]); s=p.read_text()
pat=re.compile(r'auto next=start\+std::chrono::milliseconds\(uint64_t\(cycle\+1\)\*INTERVAL_MS\);')
ms=list(pat.finditer(s))
if len(ms) != 1:
    raise SystemExit(f'FAIL: stale next declaration count={len(ms)}')
s=pat.sub('', s, count=1)
if 'auto next=' in s:
    raise SystemExit('FAIL: stale next declaration remains')
p.write_text(s)
PYFIX

grep -Fq 'constexpr uint32_t BURST_SIZE=4;' "$SRC" || fail "burst size changed"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' "$SRC" || fail "burst dwell changed"
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$SRC" || fail "live slots changed"
grep -Fq 'if((cycles % BURST_SIZE)==0 && cycles<MAX_CYCLES && !g_stop) std::this_thread::sleep_for(std::chrono::milliseconds(BURST_DWELL_MS));' "$SRC" || fail "burst sleep transform changed"
! grep -Fq 'auto next=' "$SRC" || fail "dead next variable remains"
'''
s=s.replace(anchor, fix+'\n'+anchor, 1)
p.write_text(s)
PY

[[ "$(grep -c -- '-Wall -Wextra -Werror' "$TMP")" -eq 1 ]] || fail "strict Werror compile flags changed"
! grep -Fq -- '-Wno-unused' "$TMP" || fail "warning suppression forbidden"

echo "PASS: v2 burst4 builder correction audit; dead_next_removal=counted strict_werror=preserved base_blob=$BASE_BLOB"
bash "$TMP"
