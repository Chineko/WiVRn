#!/usr/bin/env bash
set -euo pipefail

REPO="$HOME/WiVRn"
BASE_COMMIT="b5db206941900271be24ffdbefa4dc21b31edb76"
BASE_PATH="tools/helix-build-vulkan-texture-churn-4k-live4-v1.sh"
BASE_BLOB="6ab0811a9f4fd0eff7ee0884e84296833b8c8c68"
BANK_META_SHA="c8de14bec0d1e46fc1dd059ff6b80f033e8f69dae9db880d58cbe69e87286ccf"
TMP="$(mktemp /tmp/helix-build-vulkan-texture-churn-4k-live4-v2.XXXXXX.sh)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -d "$REPO/.git" ]] || fail "repo not found: $REPO"

git -C "$REPO" show "$BASE_COMMIT:$BASE_PATH" > "$TMP"
[[ "$(git hash-object "$TMP")" == "$BASE_BLOB" ]] || fail "live4 v1 builder blob mismatch"

python3 - "$TMP" "$BANK_META_SHA" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); bank_sha=sys.argv[2]; s=p.read_text()
old='''VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing"
'''
new=f'''BANK_META="$ROOT/vulkan-stimulus-sustained-5min-texture-bank32-v1-metadata.txt"
BANK_META_SHA="{bank_sha}"
[[ -s "$BANK_META" ]] || fail "sealed bank32 metadata missing"
[[ "$(sha256sum "$BANK_META" | awk '{{print $1}}')" == "$BANK_META_SHA" ]] || fail "bank32 metadata hash mismatch for Vulkan loader provenance"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {{print substr($0,index($0,"=")+1)}}' "$BANK_META" | tail -1)"
[[ -f "$VULKAN_LIB" ]] || fail "Vulkan loader missing from sealed bank32 metadata"
'''
if s.count(old) != 1:
    raise SystemExit(f'FAIL: loader provenance anchor count={s.count(old)}')
s=s.replace(old,new,1)
if '"$BASE_META" | tail -1)' in s and 'vulkan_loader' in s:
    raise SystemExit('FAIL: stale base metadata Vulkan loader lookup remains')
if bank_sha not in s:
    raise SystemExit('FAIL: bank32 metadata hash binding missing')
p.write_text(s)
PY

bash -n "$TMP" || fail "corrected live4 builder syntax invalid"
echo "PASS: live4 v2 loader-provenance correction audit; base_blob=$BASE_BLOB bank32_metadata_sha256=$BANK_META_SHA"
bash "$TMP"
