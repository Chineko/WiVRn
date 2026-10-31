#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/WiVRn"
BASE_COMMIT="77b9224a35a9a897322293ba885fb1977a0078ec"
BASE_PATH="tools/helix-seal-vulkan-texture-churn-4k-v1.sh"
BASE_BLOB="b7f8742746e015c4f24eb5c43dc8915a9646bfa4"
CORRECTED_BUILD_TOOLING="397dcd68306978e39bd8960977633ef9776f873a"
TMP="$(mktemp /tmp/helix-seal-vulkan-texture-churn-4k-v2.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -d "$REPO/.git" ]] || fail "repo not found: $REPO"

git -C "$REPO" show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
[[ "$(git hash-object "$TMP")" == "$BASE_BLOB" ]] || fail "v1 seal blob mismatch"

python3 - "$TMP" "$CORRECTED_BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); corrected=sys.argv[2]; s=p.read_text()
old='BUILD_TOOLING="8ad7de213960a4fcbe1d43522e938cb1aee16dfb"'
new=f'BUILD_TOOLING="{corrected}"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: old build tooling anchor count={s.count(old)}')
s=s.replace(old,new,1)
if old in s:
    raise SystemExit('FAIL: stale v1 build tooling remains')
p.write_text(s)
PY

bash -n "$TMP" || fail "corrected seal syntax invalid"
echo "PASS: v2 seal correction audit; build_tooling=$CORRECTED_BUILD_TOOLING base_blob=$BASE_BLOB"
bash "$TMP"
