#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="f61d7423d9ac926e1a98d1040a000d37be4bf621"
BASE_PATH="tools/helix-audit-encoded-network-sustained-5min-texture-bank32-20f-churn4k-live4-burst4-v4.sh"
EXPECTED_BUILD_TOOLING="8369e81e51ab2e7b99319d1cfb8eda55f99f0208"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
python3 - "$TMP" "$EXPECTED_BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); tooling=sys.argv[2]; s=p.read_text()
old='EXPECTED_BUILD_TOOLING="a9053b0d67ff2e7e4fe03a4088580ff360469636"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: tooling anchor count={s.count(old)}')
s=s.replace(old, f'EXPECTED_BUILD_TOOLING="{tooling}"', 1)
p.write_text(s)
PY
bash "$TMP"
