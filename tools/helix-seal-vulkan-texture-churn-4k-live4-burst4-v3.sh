#!/usr/bin/env bash
set -euo pipefail

BASE_COMMIT="d8c27ac686fa61dfef539a7b9607fef4afb88e3a"
BASE_PATH="tools/helix-seal-vulkan-texture-churn-4k-live4-burst4-v2.sh"
BUILD_TOOLING="1ebad9eae68d1b9da50a57744047f99fa245e038"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
python3 - "$TMP" "$BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); tooling=sys.argv[2]; s=p.read_text()
old='BUILD_TOOLING="c3ed8c824a98b4cada80d635787c6af788084583"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: tooling anchor count={s.count(old)}')
s=s.replace(old, f'BUILD_TOOLING="{tooling}"', 1)
anchor='! grep -Fq \'auto next=\' "$SRC" || fail "dead next variable remains"'
extra=anchor+'\n! grep -Fq \'const auto start=\' "$SRC" || fail "dead start variable remains"'
if s.count(anchor) != 1:
    raise SystemExit(f'FAIL: source guard anchor count={s.count(anchor)}')
s=s.replace(anchor, extra, 1)
p.write_text(s)
PY
bash "$TMP"
