#!/usr/bin/env bash
set -euo pipefail

BASE_STRICT_COMMIT="3f0be1819a53d2011fc645b0c4d105f21683877e"
BASE_STRICT_PATH="tools/helix-run-encoded-nvenc-torture-strict.sh"
SOURCE_COMMIT="22fb078d1e294a04c20fe9ba512b63d39d4e9f45"
BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v2-build-20261030-183258"
META="$BUILD_ROOT/metadata.txt"
SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"
MANIFEST="$BUILD_ROOT/worktree/build-everything/openxr_wivrn-dev.json"
APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v2-22fb078d1e29.apk"
SERVER_SHA256="b1ce56a31b0532db866443345a305ceb0e0efad626af03b111bad4392f35a1b7"
APK_SHA256="12ecc954722fcdd1faeaf7321a4497746c43e7daa0aaffc622ba5a8a57f95376"
VERSION_NAME="helix-encoded-fix-v2-22fb078d1e294a04c20fe9ba512b63d39d4e9f45"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 sha256sum awk grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$META" "$SERVER" "$MANIFEST" "$APK"; do [[ -s "$f" ]] || fail "fix-v2 artifact missing: $f"; done
[[ -x "$SERVER" ]] || fail "fix-v2 server is not executable"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "fix-v2 server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "fix-v2 APK hash mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "fix-v2 metadata source mismatch"
grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "fix-v2 metadata remote head mismatch"
grep -Fqx "version_name=$VERSION_NAME" "$META" || fail "fix-v2 metadata version mismatch"
grep -Fqx "server=$SERVER" "$META" || fail "fix-v2 metadata server path mismatch"
grep -Fqx "openxr_manifest=$MANIFEST" "$META" || fail "fix-v2 metadata manifest path mismatch"
grep -Fqx "apk=$APK" "$META" || fail "fix-v2 metadata APK path mismatch"
grep -Fqx 'server_provenance=PASS exact-patched-commit-direct-link' "$META" || fail "fix-v2 server provenance marker missing"
grep -Fqx 'artifact_gate=PASS encoded-nvenc-fix-v2-server-apk-exact-source' "$META" || fail "fix-v2 artifact gate marker missing"

git cat-file -e "${BASE_STRICT_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_STRICT_COMMIT"
base="$(mktemp)"
patched="$(mktemp)"
trap 'rm -f "$base" "$patched"' EXIT INT TERM
git show "${BASE_STRICT_COMMIT}:${BASE_STRICT_PATH}" >"$base"

python3 - "$base" "$patched" "$SOURCE_COMMIT" "$META" "$SERVER" "$MANIFEST" "$APK" "$SERVER_SHA256" "$APK_SHA256" "$VERSION_NAME" <<'PY'
from pathlib import Path
import shlex, sys
src, dst, source_commit, meta, server, manifest, apk, server_sha, apk_sha, version_name = sys.argv[1:]
s = Path(src).read_text()
needle = "echo 'STRICT_RUNTIME_PREFLIGHT=PASS sealed-v5-final-runtime-audited'\nexec bash \"$EMITTED\"\n"
if s.count(needle) != 1:
    raise SystemExit('FAIL: base strict final execution anchor not unique')
insert = r'''echo 'STRICT_RUNTIME_PREFLIGHT=PASS sealed-v5-final-runtime-audited'

# Rebind only the runtime server/APK identity to the audited fix-v2 artifact.
python3 - "$EMITTED" <<'PY2'
from pathlib import Path
import re
p=Path("$EMITTED")
s=p.read_text()
source_commit=__SOURCE_COMMIT__
meta=__META__
server=__SERVER__
manifest=__MANIFEST__
apk=__APK__
server_sha=__SERVER_SHA__
apk_sha=__APK_SHA__
version_name=__VERSION_NAME__

old='SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"'
new='SOURCE_COMMIT="'+source_commit+'"'
if s.count(old) != 1:
    raise SystemExit('FAIL: emitted SOURCE_COMMIT anchor count='+str(s.count(old)))
s=s.replace(old,new,1)

pattern=re.compile(r'''mapfile -t metas < <\(grep -l "\^source_commit=\$\{SOURCE_COMMIT\}\$" "\$HOME"/helix-encoded-nvenc-build-\*/resume-metadata\.txt 2>/dev/null \| sort\)\n\[\[ \$\{#metas\[@\]\} -gt 0 \]\] \|\| fail "no salvaged encoded artifact set for \$SOURCE_COMMIT"\nMETA="\$\{metas\[-1\]\}"\nSERVER="\$\(sed -n 's/\^server=//p' "\$META" \| tail -1\)"\nMANIFEST="\$\(sed -n 's/\^openxr_manifest=//p' "\$META" \| tail -1\)"\nAPK="\$\(sed -n 's/\^apk=//p' "\$META" \| tail -1\)"\nDRIVER=.*?\nfor f in "\$SERVER" "\$MANIFEST" "\$APK" "\$DRIVER"; do \[\[ -s "\$f" \]\] \|\| fail "artifact missing: \$f"; done\n\[\[ -x "\$SERVER" && -x "\$DRIVER" \]\] \|\| fail "runtime executable missing"\ngrep -Fq 'provenance=PASS direct-executable-build-graph' "\$META" \|\| fail "desktop provenance marker missing"\ngrep -Fq 'artifact_gate=PASS salvaged-existing-desktop-plus-apk-headless' "\$META" \|\| fail "artifact gate marker missing"\n''', re.S)
m=pattern.search(s)
if not m:
    raise SystemExit('FAIL: emitted artifact discovery block not found')
driver_line=re.search(r'^DRIVER=.*$', m.group(0), re.M)
if not driver_line:
    raise SystemExit('FAIL: sealed Vulkan DRIVER line missing during rebind')
driver=driver_line.group(0)
replacement=(
    'META='+repr(meta)+'\n'
    'SERVER='+repr(server)+'\n'
    'MANIFEST='+repr(manifest)+'\n'
    'APK='+repr(apk)+'\n'
    +driver+'\n'
    'for f in "$SERVER" "$MANIFEST" "$APK" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done\n'
    '[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"\n'
    '[[ "$(sha256sum "$SERVER" | awk \'{print $1}\')" == '+repr(server_sha)+' ]] || fail "runtime server hash mismatch"\n'
    '[[ "$(sha256sum "$APK" | awk \'{print $1}\')" == '+repr(apk_sha)+' ]] || fail "runtime APK hash mismatch"\n'
    'grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "artifact metadata source mismatch"\n'
    'grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "artifact metadata remote mismatch"\n'
    'grep -Fqx '+repr('version_name='+version_name)+' "$META" || fail "artifact version mismatch"\n'
    "grep -Fqx 'server_provenance=PASS exact-patched-commit-direct-link' \"$META\" || fail \"desktop provenance marker missing\"\n"
    "grep -Fqx 'artifact_gate=PASS encoded-nvenc-fix-v2-server-apk-exact-source' \"$META\" || fail \"artifact gate marker missing\"\n"
)
s=s[:m.start()]+replacement+s[m.end():]

old_version='grep -Fq "versionName=helix-encoded-${SOURCE_COMMIT}" "$OUT/package.txt" || fail "installed versionName mismatch"'
new_version='grep -Fq '+repr('versionName='+version_name)+' "$OUT/package.txt" || fail "installed versionName mismatch"'
if s.count(old_version) != 1:
    raise SystemExit('FAIL: installed version anchor count='+str(s.count(old_version)))
s=s.replace(old_version,new_version,1)

required=[
    source_commit, server, apk, server_sha, apk_sha,
    'for c in (\'rtx8\',\'gap9\',\'full_reference\')',
    "int(done['rtx8'].get('dropped','-1')) != 8",
    "int(done['gap9'].get('dropped','-1')) != 9",
    "z.get('feedback')!='3'",
    "z.get('recovered')!='3'",
    "z.get('dirty')!='0'",
    'HELIX_VULKAN_DONE frames=220',
]
for x in required:
    if x not in s:
        raise SystemExit('FAIL: rebound runtime requirement missing: '+x)
p.write_text(s)
PY2

bash -n "$EMITTED"
echo 'FIX_V2_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-unchanged'
exec bash "$EMITTED"
'''
repls={
    '__SOURCE_COMMIT__':repr(source_commit),
    '__META__':repr(meta),
    '__SERVER__':repr(server),
    '__MANIFEST__':repr(manifest),
    '__APK__':repr(apk),
    '__SERVER_SHA__':repr(server_sha),
    '__APK_SHA__':repr(apk_sha),
    '__VERSION_NAME__':repr(version_name),
}
for k,v in repls.items(): insert=insert.replace(k,v)
s=s.replace(needle,insert,1)
Path(dst).write_text(s)
PY

bash -n "$patched"
grep -Fq "$SOURCE_COMMIT" "$patched" || fail "fix-v2 source binding missing"
grep -Fq "$SERVER_SHA256" "$patched" || fail "fix-v2 server hash binding missing"
grep -Fq "$APK_SHA256" "$patched" || fail "fix-v2 APK hash binding missing"
grep -Fq 'FIX_V2_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-unchanged' "$patched" || fail "fix-v2 binding gate missing"

exec bash "$patched"
