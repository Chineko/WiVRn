#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
VULKAN_WRAPPER_COMMIT="cfa03d67546f25ed5d074d41f035adbf2918bbcd"
GENERATOR_TOOLING="1346a215fad30861651bfd054c8e5cd162bca06f"
BUILD_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$BUILD_ROOT/vulkan-stimulus-seal.txt"
SRC="$BUILD_ROOT/helix_vulkan_stimulus.cpp"
BIN="$BUILD_ROOT/helix-vulkan-stimulus"
META="$BUILD_ROOT/vulkan-stimulus-metadata.txt"
WRAPPER="$(mktemp)"
EMITTED="$(mktemp)"
trap 'rm -f "$WRAPPER" "$EMITTED"' EXIT INT TERM

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git grep python3 sed sha256sum tail bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$SEAL" "$SRC" "$BIN" "$META"; do [[ -s "$f" ]] || fail "sealed artifact missing: $f"; done
[[ -x "$BIN" ]] || fail "sealed Vulkan stimulus is not executable"

grep -Fq "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "seal source mismatch"
grep -Fq "tooling_commit=$GENERATOR_TOOLING" "$SEAL" || fail "seal tooling mismatch"
grep -Fq 'artifact_seal=PASS exact-generated-source-binary-metadata' "$SEAL" || fail "artifact seal marker missing"
grep -Fq 'runtime_status=NOT_RUN' "$SEAL" || fail "sealed artifact was already marked as runtime-used"

want_src="$(sed -n 's/^source_sha256=//p' "$SEAL" | tail -1)"
want_bin="$(sed -n 's/^binary_sha256=//p' "$SEAL" | tail -1)"
want_meta="$(sed -n 's/^metadata_sha256=//p' "$SEAL" | tail -1)"
[[ -n "$want_src" && -n "$want_bin" && -n "$want_meta" ]] || fail "seal hashes incomplete"
[[ "$(sha256sum "$SRC" | awk '{print $1}')" == "$want_src" ]] || fail "stimulus source changed after seal"
[[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$want_bin" ]] || fail "stimulus binary changed after seal"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$want_meta" ]] || fail "stimulus metadata changed after seal"

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

# Harden the FINAL emitted runtime script, not its generator.
python3 - "$EMITTED" "$SEAL" "$want_src" "$want_bin" "$want_meta" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); seal,src_sha,bin_sha,meta_sha=sys.argv[2:]
s=p.read_text()

def once(old,new,label):
    global s
    if s.count(old) != 1:
        raise SystemExit(f'FAIL: final runtime anchor not unique: {label}')
    s=s.replace(old,new,1)

completion='''grep -Fq 'HELIX_VULKAN_DONE frames=220' "$OUT/vulkan.txt" || fail "Vulkan stimulus did not complete 220 frames"\n'''
completion_new=completion+'''grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$OUT/vulkan.txt" || fail "Vulkan entropy stimulus contract did not execute"\nprintf 'stimulus_seal=%s\\nstimulus_source_sha256=%s\\nstimulus_binary_sha256=%s\\nstimulus_metadata_sha256=%s\\n' '''+repr(seal)+''' '''+repr(src_sha)+''' '''+repr(bin_sha)+''' '''+repr(meta_sha)+''' >>"$OUT/metadata.txt"\n'''
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
 'HELIX_VULKAN_ENTROPY patterns=8',
 'HELIX_VULKAN_DONE frames=220',
 'running server identity mismatch',
 'HELIX_ENCODED_NVENC_CAP stream=0 supported=1',
 'HELIX_ENCODED_TORTURE_SUMMARY',
 "for c in ('rtx8','gap9','full_reference')",
 "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'",
]
for x in required:
    if x not in s: raise SystemExit('FAIL: final runtime requirement missing: '+x)
for x in ['XR_MND_headless','HELIX_HEADLESS_DONE','$OUT/headless.txt','print $(i+1); exit']:
    if x in s: raise SystemExit('FAIL: stale final runtime pattern remains: '+x)
p.write_text(s)
PY

bash -n "$EMITTED"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$EMITTED"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$EMITTED"
grep -Fq "x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'" "$EMITTED"
! grep -Fq 'XR_MND_headless' "$EMITTED"
! grep -Fq 'HELIX_HEADLESS_DONE' "$EMITTED"

echo 'STRICT_RUNTIME_PREFLIGHT=PASS final-emitted-runtime-audited'
exec bash "$EMITTED"
