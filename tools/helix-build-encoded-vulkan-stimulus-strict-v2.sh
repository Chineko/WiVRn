#!/usr/bin/env bash
set -euo pipefail
BASE="dc5c2ca5bf3ae193ba58bb515ea39579a2080d56"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo 'error: run from inside WiVRn checkout' >&2; exit 2; }
cd "$repo_root"
for c in git python3 grep; do command -v "$c" >/dev/null 2>&1 || { echo "error: missing command $c" >&2; exit 2; }; done
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git cat-file -e "${BASE}^{commit}" 2>/dev/null || git fetch origin "$BASE"
git show "${BASE}:tools/helix-build-encoded-vulkan-stimulus-strict.sh" >"$tmp"
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='vk_ok(vkMapMemory(device, staging_memory, 0, upload_bytes, 0, &mapped), "vkMapMemory_staging");'
new='vk_ok(vkMapMemory(device, staging_memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory_staging");'
if s.count(old) != 1:
    raise SystemExit('error: staging-map audit anchor not unique')
s=s.replace(old,new,1)
if old in s or new not in s:
    raise SystemExit('error: staging-map audit patch incomplete')
p.write_text(s)
PY
grep -Fq 'VK_WHOLE_SIZE, 0, &mapped' "$tmp"
grep -Fq 'HELIX_VULKAN_ENTROPY' "$tmp"
grep -Fq 'vkCmdCopyBufferToImage' "$tmp"
! grep -Fq 'vkCmdClearColorImage' "$tmp"
exec bash "$tmp"
