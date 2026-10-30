#!/usr/bin/env bash
set -euo pipefail

# Provisional runtime wrapper for the graphics-bound Vulkan stimulus.
# It reuses the audited direct-server runner, applies the live-executable
# provenance fix, and replaces only the invalid XR_MND_headless stimulus.
base_tooling="8c656f35e62fa4738230a8f99e942740b645122b"
source_commit="5568963b538eaae708b9f957a9a3c162ddaf5de4"
build_root="$HOME/helix-encoded-nvenc-build-20261030-160211"
vulkan_meta="$build_root/vulkan-stimulus-metadata.txt"
[[ -s "$vulkan_meta" ]] || { echo "FAIL: Vulkan stimulus metadata missing; build stimulus first" >&2; exit 2; }
grep -Fq "source_commit=$source_commit" "$vulkan_meta" || { echo "FAIL: Vulkan stimulus source identity mismatch" >&2; exit 2; }
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-projection-layer' "$vulkan_meta" || { echo "FAIL: Vulkan stimulus contract marker missing" >&2; exit 2; }
grep -Fq 'runtime_status=NOT_RUN' "$vulkan_meta" || { echo "FAIL: Vulkan stimulus metadata has unexpected runtime state" >&2; exit 2; }
VULKAN_STIMULUS="$(sed -n 's/^vulkan_stimulus=//p' "$vulkan_meta" | tail -1)"
[[ -x "$VULKAN_STIMULUS" ]] || { echo "FAIL: Vulkan stimulus executable missing" >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
git show "${base_tooling}:tools/helix-run-encoded-nvenc-torture.sh" >"$tmp"
python3 - "$tmp" "$VULKAN_STIMULUS" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); driver=sys.argv[2]
s=p.read_text()

# Strong runtime identity: exact live executable path plus frozen build metadata.
old='''for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" && break
  sleep .1
done
grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" || fail "server startup log missing exact commit"
'''
new='''for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" && break
  sleep .1
done
grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing"
SERVER_EXE="$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)"
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server identity mismatch: $SERVER_EXE != $SERVER"
printf 'server_exe=%s\\n' "$SERVER_EXE" >>"$OUT/metadata.txt"
'''
if old not in s: raise SystemExit('error: startup provenance anchor not found')
s=s.replace(old,new,1)
old2='''grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" || fail "server log missing exact commit"
'''
new2='''grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing from preserved log"
grep -Fq "source_commit=$SOURCE_COMMIT" "$META" || fail "artifact metadata lost exact source identity"
'''
if old2 not in s: raise SystemExit('error: final provenance anchor not found')
s=s.replace(old2,new2,1)

# Replace only the stimulus executable and its completion contract.
old3='''DRIVER="$(sed -n 's/^headless_driver=//p' "$META" | tail -1)"
for f in "$SERVER" "$MANIFEST" "$APK" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"
'''
new3=f'''DRIVER={driver!r}
for f in "$SERVER" "$MANIFEST" "$APK" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"
'''
if old3 not in s: raise SystemExit('error: driver-selection anchor not found')
s=s.replace(old3,new3,1)
s=s.replace('headless_driver=$DRIVER', 'vulkan_stimulus=$DRIVER')
s=s.replace("echo '[4/8] Driving 220 real OpenXR frames through NVENC'", "echo '[4/8] Driving 220 graphics-bound Vulkan/OpenXR frames through NVENC'")
s=s.replace('>"$OUT/headless.txt" 2>&1', '>"$OUT/vulkan.txt" 2>&1')
s=s.replace('fail "headless OpenXR driver failed"', 'fail "graphics-bound Vulkan/OpenXR stimulus failed"')
s=s.replace("grep -Fq 'HELIX_HEADLESS_DONE frames=220' \"$OUT/headless.txt\" || fail \"headless driver did not complete 220 frames\"", "grep -Fq 'HELIX_VULKAN_DONE frames=220' \"$OUT/vulkan.txt\" || fail \"Vulkan stimulus did not complete 220 frames\"")
if 'XR_MND_headless' in s or 'HELIX_HEADLESS_DONE' in s or '$OUT/headless.txt' in s:
    raise SystemExit('error: stale headless runtime contract remains')
p.write_text(s)
PY

# Static whole-wrapper guards before any headset action.
! grep -Fq 'server startup log missing exact commit' "$tmp"
grep -Fq 'running server identity mismatch' "$tmp"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$tmp"
grep -Fq 'graphics-bound Vulkan/OpenXR stimulus failed' "$tmp"
! grep -Fq 'XR_MND_headless' "$tmp"
! grep -Fq 'HELIX_HEADLESS_DONE' "$tmp"

exec bash "$tmp"
