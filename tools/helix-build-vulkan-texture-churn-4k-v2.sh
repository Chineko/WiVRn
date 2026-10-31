#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/WiVRn"
BASE_COMMIT="8ad7de213960a4fcbe1d43522e938cb1aee16dfb"
BASE_PATH="tools/helix-build-vulkan-texture-churn-4k-v1.sh"
BASE_BLOB="56cf9317c3f4c3d47e2534a71b2e70f0d6c41e0b"
TMP="$(mktemp /tmp/helix-build-vulkan-texture-churn-4k-v2.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -d "$REPO/.git" ]] || fail "repo not found: $REPO"

git -C "$REPO" show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
[[ "$(git hash-object "$TMP")" == "$BASE_BLOB" ]] || fail "v1 builder blob mismatch"

python3 - "$TMP" <<'PY'
from pathlib import Path
import re, sys
p=Path(sys.argv[1])
s=p.read_text()
pattern=re.compile(r'(?P<type>Vk[A-Za-z0-9_]+) (?P<var>[A-Za-z0-9_]+)\{(?P<stype>VK_STRUCTURE_TYPE_[A-Z0-9_]+)\};')

def repl(m):
    return f"{m.group('type')} {m.group('var')}{{}};{m.group('var')}.sType={m.group('stype')};"

s2,n=pattern.subn(repl,s)
if n != 17:
    raise SystemExit(f"FAIL: expected 17 Vulkan sType initializer rewrites, got {n}")
if '{VK_STRUCTURE_TYPE_' in s2:
    raise SystemExit('FAIL: stale partial Vulkan structure initializer remains')
# Preserve strict warnings; this is a source correction, not warning suppression.
if '-Wall -Wextra -Werror' not in s2:
    raise SystemExit('FAIL: strict compiler warning policy missing')
if '-Wno-missing-field-initializers' in s2:
    raise SystemExit('FAIL: warning suppression unexpectedly present')
p.write_text(s2)
PY

bash -n "$TMP" || fail "corrected builder syntax invalid"
echo "PASS: v2 builder correction audit; rewrites=17 strict_werror=preserved base_blob=$BASE_BLOB"
bash "$TMP"
