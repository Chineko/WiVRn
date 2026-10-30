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
repls={
'vk_ok(vkMapMemory(device, staging_memory, 0, upload_bytes, 0, &mapped), "vkMapMemory_staging");':'vk_ok(vkMapMemory(device, staging_memory, 0, VK_WHOLE_SIZE, 0, &mapped), "vkMapMemory_staging");',
'const VkDeviceSize upload_bytes = pattern_bytes * 2;':'const VkDeviceSize upload_bytes = pattern_bytes * 8;',
'HELIX_VULKAN_ENTROPY patterns=2 upload_bytes=%llu':'HELIX_VULKAN_ENTROPY patterns=8 upload_bytes=%llu',
'const VkDeviceSize pattern_offset = (produced & 1u) ? pattern_bytes : 0;':'const VkDeviceSize pattern_offset = VkDeviceSize(produced % 8u) * pattern_bytes;',
}
for old,new in repls.items():
    if s.count(old) != 1:
        raise SystemExit(f'error: strict-v3 anchor not unique: {old}')
    s=s.replace(old,new,1)
for forbidden in [
    'vkMapMemory(device, staging_memory, 0, upload_bytes',
    'upload_bytes = pattern_bytes * 2',
    'patterns=2 upload_bytes',
    '(produced & 1u) ? pattern_bytes : 0',
]:
    if forbidden in s:
        raise SystemExit(f'error: stale strict-v3 pattern remains: {forbidden}')
for required in [
    'VK_WHOLE_SIZE, 0, &mapped',
    'upload_bytes = pattern_bytes * 8',
    'HELIX_VULKAN_ENTROPY patterns=8',
    'produced % 8u',
]:
    if required not in s:
        raise SystemExit(f'error: strict-v3 requirement missing: {required}')
p.write_text(s)
PY
grep -Fq 'VK_WHOLE_SIZE, 0, &mapped' "$tmp"
grep -Fq 'upload_bytes = pattern_bytes * 8' "$tmp"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$tmp"
grep -Fq 'produced % 8u' "$tmp"
grep -Fq 'vkCmdCopyBufferToImage' "$tmp"
! grep -Fq 'vkCmdClearColorImage' "$tmp"
exec bash "$tmp"
