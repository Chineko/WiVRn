#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/WiVRn"
BASE_COMMIT="eb34222557d372debe477ce59b00544ae096b960"
BASE_PATH="tools/helix-seal-vulkan-texture-churn-4k-live4-v1.sh"
BASE_BLOB="5a842b551d6fb4752735dce5c034da011d47549c"
NEW_BUILD_TOOLING="90842e13d58bcec6c788f4eb0bb345a632833ed1"
TMP="$(mktemp /tmp/helix-seal-vulkan-texture-churn-4k-live4-v2.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -d "$REPO/.git" ]] || fail "repo not found: $REPO"

git -C "$REPO" show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
[[ "$(git hash-object "$TMP")" == "$BASE_BLOB" ]] || fail "live4 v1 seal blob mismatch"

python3 - "$TMP" "$NEW_BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); new=sys.argv[2]; s=p.read_text()
old='BUILD_TOOLING="b5db206941900271be24ffdbefa4dc21b31edb76"'
repl=f'BUILD_TOOLING="{new}"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: seal tooling anchor count={s.count(old)}')
s=s.replace(old,repl,1)
if 'b5db206941900271be24ffdbefa4dc21b31edb76' in s:
    raise SystemExit('FAIL: stale v1 build tooling remains in seal')
if new not in s:
    raise SystemExit('FAIL: corrected build tooling missing from seal')
p.write_text(s)
PY

bash -n "$TMP" || fail "corrected live4 seal syntax invalid"
echo "PASS: live4 v2 seal correction audit; base_blob=$BASE_BLOB build_tooling=$NEW_BUILD_TOOLING"
bash "$TMP"
