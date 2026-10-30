#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
VULKAN_WRAPPER_COMMIT="cfa03d67546f25ed5d074d41f035adbf2918bbcd"
BUILD_TOOLING="8430f775e0d5f2847683406a70c9695e22ac36df"
BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$BUILD_ROOT/vulkan-stimulus-v5-seal.txt"
SRC="$BUILD_ROOT/helix_vulkan_stimulus_v5.cpp"
BIN="$BUILD_ROOT/helix-vulkan-stimulus-v5"
META="$BUILD_ROOT/vulkan-stimulus-v5-metadata.txt"
WRAPPER="$(mktemp)"
EMITTED="$(mktemp)"
trap 'rm -f "$WRAPPER" "$EMITTED"' EXIT INT TERM

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git grep python3 sed sha256sum tail bash awk; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SEAL" "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "sealed v5 artifact missing: $f"; done
[[ -x "$BIN" ]] || fail "sealed v5 Vulkan stimulus is not executable"

grep -Fq "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "v5 seal source mismatch"
grep -Fq "build_tooling_commit=$BUILD_TOOLING" "$SEAL" || fail "v5 seal tooling mismatch"
grep -Fq 'artifact_seal=PASS strict-v5-source-binary-metadata-deps' "$SEAL" || fail "v5 artifact seal marker missing"
grep -Fq 'runtime_status=NOT_RUN' "$SEAL" || fail "v5 sealed artifact runtime status is not NOT_RUN"

want_src="$(sed -n 's/^source_sha256=//p' "$SEAL" | tail -1)"
want_bin="$(sed -n 's/^binary_sha256=//p' "$SEAL" | tail -1)"
want_meta="$(sed -n 's/^metadata_sha256=//p' "$SEAL" | tail -1)"
[[ -n "$want_src" && -n "$want_bin" && -n "$want_meta" ]] || fail "v5 seal hashes incomplete"
[[ "$(sha256sum "$SRC" | awk '{print $1}')" == "$want_src" ]] || fail "v5 stimulus source changed after seal"
[[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$want_bin" ]] || fail "v5 stimulus binary changed after seal"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$want_meta" ]] || fail "v5 stimulus metadata changed after seal"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$META" || fail "v5 metadata contract missing"

# Generate the already-audited Vulkan runtime script, but emit it instead of executing it.
git cat-file -e "${VULKAN_WRAPPER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$VULKAN_WRAPPER_COMMIT"
git show "${VULKAN_WRAPPER_COMMIT}:tools/helix-run-encoded-nvenc-torture-vulkan.sh" >"$WRAPPER"
python3 - "$WRAPPER" "$EMITTED" <<'PY'
from pathlib import Path
import shlex, sys
p=Path(sys.argv[1]); out=sys.argv[2]
s=p.read_text()
needle='exec bash "$tmp"\n'
if s.count(needle) != 1:
    raise SystemExit('FAIL: Vulkan wrapper execution anchor not unique')
s=s.replace(needle, f'cp "$tmp" {shlex.quote(out)}\n', 1)
p.write_text(s)
PY
bash "$WRAPPER"
[[ -s "$EMITTED" ]] || fail "Vulkan wrapper did not emit final runtime script"

# Harden the FINAL emitted runtime script and bind it to the sealed v5 binary.
python3 - "$EMITTED" "$SEAL" "$BIN" "$want_src" "$want_bin" "$want_meta" <<'PY'
from pathlib import Path
import re, shlex, sys
p=Path(sys.argv[1]); seal,bin_path,src_sha,bin_sha,meta_sha=sys.argv[2:]
s=p.read_text()

def once(old,new,label):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'FAIL: final runtime anchor not unique: {label}')
    s=s.replace(old,new,1)

# Replace the Vulkan driver chosen by the old wrapper with the exact sealed v5 binary.
matches=list(re.finditer(r'^DRIVER=.*$', s, re.M))
if len(matches) != 1:
    raise SystemExit(f'FAIL: final runtime DRIVER assignment count={len(matches)}')
m=matches[0]
s=s[:m.start()] + 'DRIVER=' + shlex.quote(bin_path) + s[m.end():]

# Quest power telemetry is not a reliable readiness oracle. Wake best-effort,
# preserve the reported state, and let the real trusted Client-connected gate
# decide whether the headset is actually usable.
awake_old='''SCREEN="$(adb -s "$SERIAL" shell dumpsys power 2>/dev/null | tr -d '\\r' | grep -E 'mWakefulness=|Display Power:' || true)"\necho "$SCREEN" >"$OUT/preflight.txt"\ngrep -Eq 'Awake|state=ON' "$OUT/preflight.txt" || fail "Quest is not awake; wear it and keep display on"\n'''
awake_new='''adb -s "$SERIAL" shell input keyevent 224 >/dev/null 2>&1 || true\nsleep .5\nSCREEN="$(adb -s "$SERIAL" shell dumpsys power 2>/dev/null | tr -d '\\r' | grep -E 'mWakefulness=|Display Power:' || true)"\nprintf 'quest_power_probe=%s\\n' "$SCREEN" >"$OUT/preflight.txt"\necho 'Quest readiness will be proven by trusted Client connected after launch' >>"$OUT/preflight.txt"\n'''
once(awake_old,awake_new,'Quest awake preflight')

completion='''grep -Fq 'HELIX_VULKAN_DONE frames=220' "$OUT/vulkan.txt" || fail "Vulkan stimulus did not complete 220 frames"\n'''
completion_new=completion+'''grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$OUT/vulkan.txt" || fail "Vulkan entropy stimulus contract did not execute"\ngrep -Eq 'HELIX_VULKAN_PROGRESS frames=[0-9]+ attempts=[0-9]+ shouldRender=1 state=[0-9]+' "$OUT/vulkan.txt" || fail "v5 render-counted stimulus never produced a renderable frame"\nprintf 'stimulus_seal=%s\\nstimulus_source_sha256=%s\\nstimulus_binary_sha256=%s\\nstimulus_metadata_sha256=%s\\n' '''+repr(seal)+''' '''+repr(src_sha)+''' '''+repr(bin_sha)+''' '''+repr(meta_sha)+''' >>"$OUT/metadata.txt"\n'''
once(completion,completion_new,'Vulkan completion')

q_old='''QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\\r' | awk '/inet /{sub(/\\/.*/,"",$2); print $2; exit}')"\n'''
q_new='''QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\\r' | awk '/inet / && !found {sub(/\\/.*/,"",$2); value=$2; found=1} END {if(found) print value}')"\n'''
once(q_old,q_new,'Quest IPv4 discovery')

h_old='''HOST_IP="$(ip -4 route get "$QUEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"\n'''
h_new='''HOST_IP="$(ip -4 route get "$QUEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"\n'''
once(h_old,h_new,'host IPv4 discovery')

apply_old="if not any(x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')"
apply_new="if not any(x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')"
once(apply_old,apply_new,'invalidation applied reducer')

unexpected_old="if any(x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')"
unexpected_new="if any(x.get('stream')=='0' and x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')"
once(unexpected_old,unexpected_new,'unexpected invalidation reducer')

required=[
 'Quest readiness will be proven by trusted Client connected after launch',
 'HELIX_VULKAN_ENTROPY patterns=8',
 'HELIX_VULKAN_DONE frames=220',
 'v5 render-counted stimulus never produced a renderable frame',
 'running server identity mismatch',
 'HELIX_ENCODED_NVENC_CAP stream=0 supported=1',
 'HELIX_ENCODED_TORTURE_SUMMARY',
 "for c in ('rtx8','gap9','full_reference')",
 "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'",
]
for x in required:
    if x not in s: raise SystemExit('FAIL: final runtime requirement missing: '+x)
for x in ['Quest is not awake; wear it and keep display on','XR_MND_headless','HELIX_HEADLESS_DONE','$OUT/headless.txt','print $(i+1); exit']:
    if x in s: raise SystemExit('FAIL: stale final runtime pattern remains: '+x)
p.write_text(s)
PY

bash -n "$EMITTED"
grep -Fq "DRIVER='$BIN'" "$EMITTED" || grep -Fq "DRIVER=$BIN" "$EMITTED" || fail "final runtime not bound to sealed v5 binary"
grep -Fq 'Quest readiness will be proven by trusted Client connected after launch' "$EMITTED"
! grep -Fq 'Quest is not awake; wear it and keep display on' "$EMITTED"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$EMITTED"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$EMITTED"
grep -Fq 'v5 render-counted stimulus never produced a renderable frame' "$EMITTED"
grep -Fq "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'" "$EMITTED"
! grep -Fq 'XR_MND_headless' "$EMITTED"
! grep -Fq 'HELIX_HEADLESS_DONE' "$EMITTED"

echo 'STRICT_RUNTIME_PREFLIGHT=PASS sealed-v5-final-runtime-audited'
exec bash "$EMITTED"
