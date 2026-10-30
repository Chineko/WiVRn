#!/usr/bin/env bash
set -euo pipefail

BASE_BINDING_COMMIT="ee49a058d55311c5d4a57c55896ad2e5a6a0df03"
BASE_BINDING_PATH="tools/helix-run-encoded-nvenc-torture-fix-v2-strict.sh"

git cat-file -e "${BASE_BINDING_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_BINDING_COMMIT"
git cat-file -e "${BASE_BINDING_COMMIT}^{commit}" 2>/dev/null || { echo "FAIL: pinned fix-v2 runtime binding commit unavailable" >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "${BASE_BINDING_COMMIT}:${BASE_BINDING_PATH}" >"$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''from pathlib import Path\nimport re\np=Path("$EMITTED")\n'''
new='''from pathlib import Path\nimport re, sys\np=Path(sys.argv[1])\n'''
if s.count(old) != 1:
    raise SystemExit(f"FAIL: emitted-path correction anchor count={s.count(old)}")
s=s.replace(old,new,1)
p.write_text(s)
PY

bash -n "$tmp"
grep -Fq 'p=Path(sys.argv[1])' "$tmp" || { echo "FAIL: corrected emitted path binding missing" >&2; exit 2; }
! grep -Fq 'p=Path("$EMITTED")' "$tmp" || { echo "FAIL: stale literal emitted path remains" >&2; exit 2; }
grep -Fq 'FIX_V2_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-unchanged' "$tmp" || { echo "FAIL: fix-v2 binding gate missing" >&2; exit 2; }

exec bash "$tmp"
