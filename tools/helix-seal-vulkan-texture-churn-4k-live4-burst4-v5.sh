#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="9485af7bededaf22f6cade18eff534aafda772d2"
BASE_PATH="tools/helix-seal-vulkan-texture-churn-4k-live4-burst4-v4.sh"
BUILD_TOOLING="8369e81e51ab2e7b99319d1cfb8eda55f99f0208"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
python3 - "$TMP" "$BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); tooling=sys.argv[2]; s=p.read_text()
old='BUILD_TOOLING="a9053b0d67ff2e7e4fe03a4088580ff360469636"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: tooling anchor count={s.count(old)}')
s=s.replace(old, f'BUILD_TOOLING="{tooling}"', 1)
p.write_text(s)
PY
bash "$TMP"
