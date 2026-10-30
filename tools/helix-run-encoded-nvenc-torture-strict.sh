#!/usr/bin/env bash
set -euo pipefail

RUNTIME_TOOLING="cfa03d67546f25ed5d074d41f035adbf2918bbcd"
SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
GENERATOR_TOOLING="1346a215fad30861651bfd054c8e5cd162bca06f"
BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$BUILD_ROOT/vulkan-stimulus-seal.txt"
SRC="$BUILD_ROOT/helix_vulkan_stimulus.cpp"
BIN="$BUILD_ROOT/helix-vulkan-stimulus"
META="$BUILD_ROOT/vulkan-stimulus-metadata.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git grep python3 sed sha256sum tail; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ -s "$SEAL" && -s "$SRC" && -x "$BIN" && -s "$META" ]] || fail "sealed Vulkan stimulus artifact set incomplete"
grep -Fq "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "seal source commit mismatch"
grep -Fq "tooling_commit=$GENERATOR_TOOLING" "$SEAL" || fail "seal generator tooling mismatch"
grep -Fq 'artifact_seal=PASS exact-generated-source-binary-metadata' "$SEAL" || fail "artifact seal marker missing"
grep -Fq 'runtime_status=NOT_RUN' "$SEAL" || fail "seal runtime status is not NOT_RUN"

want_src="$(sed -n 's/^source_sha256=//p' "$SEAL" | tail -1)"
want_bin="$(sed -n 's/^binary_sha256=//p' "$SEAL" | tail -1)"
want_meta="$(sed -n 's/^metadata_sha256=//p' "$SEAL" | tail -1)"
[[ -n "$want_src" && -n "$want_bin" && -n "$want_meta" ]] || fail "seal hashes incomplete"
[[ "$(sha256sum "$SRC" | awk '{print $1}')" == "$want_src" ]] || fail "stimulus source changed after seal"
[[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$want_bin" ]] || fail "stimulus binary changed after seal"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$want_meta" ]] || fail "stimulus metadata changed after seal"

grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "sealed source entropy contract missing"
grep -Fq 'vkCmdCopyBufferToImage' "$SRC" || fail "sealed source transfer contract missing"
! grep -Fq 'XR_MND_headless' "$SRC" || fail "sealed source contains headless extension"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git cat-file -e "${RUNTIME_TOOLING}^{commit}" 2>/dev/null || git fetch origin "$RUNTIME_TOOLING"
git show "${RUNTIME_TOOLING}:tools/helix-run-encoded-nvenc-torture-vulkan.sh" >"$tmp"

python3 - "$tmp" "$SEAL" "$want_src" "$want_bin" "$want_meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); seal,src_sha,bin_sha,meta_sha=sys.argv[2:]
s=p.read_text()

# Require the actual 8-pattern entropy stimulus to execute and bind its seal into evidence.
needle='''grep -Fq 'HELIX_VULKAN_DONE frames=220' "$OUT/vulkan.txt" || fail "Vulkan stimulus did not complete 220 frames"\n'''
replacement=needle + '''grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$OUT/vulkan.txt" || fail "Vulkan entropy stimulus contract did not execute"\nprintf 'stimulus_seal=%s\\nstimulus_source_sha256=%s\\nstimulus_binary_sha256=%s\\nstimulus_metadata_sha256=%s\\n' ''' + repr(seal) + ''' ''' + repr(src_sha) + ''' ''' + repr(bin_sha) + ''' ''' + repr(meta_sha) + ''' >>"$OUT/metadata.txt"\n'''
if needle not in s:
    raise SystemExit('error: Vulkan completion anchor not found')
s=s.replace(needle,replacement,1)

# Close remaining set -o pipefail + early-exit awk paths in network address discovery.
old_q='''QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\\r' | awk '/inet /{sub(/\\/.*/,"",$2); print $2; exit}')"\n'''
new_q='''QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\\r' | awk '/inet / && !found {sub(/\\/.*/,"",$2); value=$2; found=1} END {if(found) print value}')"\n'''
old_h='''HOST_IP="$(ip -4 route get "$QUEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"\n'''
new_h='''HOST_IP="$(ip -4 route get "$QUEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"\n'''
if old_q not in s or old_h not in s:
    raise SystemExit('error: address-discovery anchors not found')
s=s.replace(old_q,new_q,1).replace(old_h,new_h,1)

# Reducer invalidation evidence must match both stream 0 and the exact failed frame.
old_apply="if not any(x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')"
new_apply="if not any(x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')"
old_unexpected="if any(x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')"
new_unexpected="if any(x.get('stream')=='0' and x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')"
if old_apply not in s or old_unexpected not in s:
    raise SystemExit('error: reducer invalidation anchors not found')
s=s.replace(old_apply,new_apply,1).replace(old_unexpected,new_unexpected,1)

for required in [
    'HELIX_VULKAN_ENTROPY patterns=8',
    'HELIX_VULKAN_DONE frames=220',
    'running server identity mismatch',
    'HELIX_ENCODED_NVENC_CAP stream=0 supported=1',
    'HELIX_ENCODED_TORTURE_SUMMARY',
    "for c in ('rtx8','gap9','full_reference')",
    "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'",
    "awk '/inet / && !found",
]:
    if required not in s:
        raise SystemExit(f'error: strict runtime contract missing: {required}')
for forbidden in [
    'XR_MND_headless','HELIX_HEADLESS_DONE','$OUT/headless.txt',
    "awk '/inet /{sub(/\\/.*/,\"\",$2); print $2; exit}'",
    'print $(i+1); exit',
    "any(x.get('frame')==frame and x.get('action')=='applied' for x in inv)",
]:
    if forbidden in s:
        raise SystemExit(f'error: stale runtime contract remains: {forbidden}')
p.write_text(s)
PY

# Final generated runtime script audit before any ADB/device action.
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$tmp"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$tmp"
grep -Fq 'running server identity mismatch' "$tmp"
grep -Fq 'HELIX_ENCODED_NVENC_CAP stream=0 supported=1' "$tmp"
grep -Fq 'HELIX_ENCODED_TORTURE_SUMMARY' "$tmp"
grep -Fq "for c in ('rtx8','gap9','full_reference')" "$tmp"
grep -Fq "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'" "$tmp"
! grep -Fq 'XR_MND_headless' "$tmp"
! grep -Fq 'HELIX_HEADLESS_DONE' "$tmp"
! grep -Fq 'print $(i+1); exit' "$tmp"

echo 'STRICT_RUNTIME_PREFLIGHT=PASS sealed-artifact-and-generated-runner-audited'
exec bash "$tmp"
