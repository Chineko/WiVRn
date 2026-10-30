#!/usr/bin/env bash
set -euo pipefail

BASE_AUDITED_COMMIT="c849e4a583a28c630a3b18b6f78c0356c1166a7f"
BASE_AUDITED_PATH="tools/helix-run-encoded-nvenc-torture-fix-v2-strict-audited.sh"

git cat-file -e "${BASE_AUDITED_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_AUDITED_COMMIT"
git cat-file -e "${BASE_AUDITED_COMMIT}^{commit}" 2>/dev/null || { echo "FAIL: pinned audited v2 launcher unavailable" >&2; exit 2; }

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "${BASE_AUDITED_COMMIT}:${BASE_AUDITED_PATH}" >"$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f"FAIL: {label} anchor count={n}")
    s=s.replace(old,new,1)

# Rebind the v2 audited binding script to the exact v3 build.
once('SOURCE_COMMIT="22fb078d1e294a04c20fe9ba512b63d39d4e9f45"',
     'SOURCE_COMMIT="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"',
     'source commit')
once('BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v2-build-20261030-183258"',
     'BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v3-build-20261030-185452"',
     'build root')
once('APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v2-22fb078d1e29.apk"',
     'APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v3-951ce95cd2ea.apk"',
     'APK path')
once('SERVER_SHA256="b1ce56a31b0532db866443345a305ceb0e0efad626af03b111bad4392f35a1b7"',
     'SERVER_SHA256="1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af"',
     'server hash')
once('APK_SHA256="12ecc954722fcdd1faeaf7321a4497746c43e7daa0aaffc622ba5a8a57f95376"',
     'APK_SHA256="1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c"',
     'APK hash')
once('VERSION_NAME="helix-encoded-fix-v2-22fb078d1e294a04c20fe9ba512b63d39d4e9f45"',
     'VERSION_NAME="helix-encoded-fix-v3-951ce95cd2ea14bf34e099d2b7e56f272d05cdac"',
     'version name')

# Update metadata/provenance labels from v2 to v3.
s=s.replace('fix-v2', 'fix-v3')
once("artifact_gate=PASS encoded-nvenc-fix-v2-server-apk-exact-source",
     "artifact_gate=PASS encoded-nvenc-fix-v3-server-apk-exact-source",
     'artifact gate')

# Extend the nested emitted-runtime transformer with the evidence-backed rtx8 contract.
anchor="required=[\n"
if s.count(anchor) != 1:
    raise SystemExit(f"FAIL: nested required-list anchor count={s.count(anchor)}")

old_reducer = """if 'rtx8' in fb and fb['rtx8'].get('sent_to_decoder') != '1': errors.append('rtx8:not_same_frame_decoded')
if 'rtx8' in rec and not (rec['rtx8'].get('mode')=='same_frame' and rec['rtx8'].get('delta')=='0'): errors.append('rtx8:bad_recovery')
for c in ('gap9','full_reference'):
    if c in fb and fb[c].get('sent_to_decoder') != '0': errors.append(f'{c}:expected_incomplete')
    if c in rec:
        if rec[c].get('mode') != 'fresh_frame': errors.append(f'{c}:not_fresh_recovery')
        try: delta=int(rec[c].get('delta','999'))
        except: delta=999
        if delta < 1 or delta > 3: errors.append(f'{c}:recovery_delta={delta}')
    if c in inj:
        frame=inj[c].get('frame')
        if not any(x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')
if 'rtx8' in inj:
    frame=inj['rtx8'].get('frame')
    if any(x.get('stream')=='0' and x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')
"""
new_reducer = """for c in ('rtx8','gap9','full_reference'):
    if c in fb and fb[c].get('sent_to_decoder') != '0': errors.append(f'{c}:expected_incomplete')
    if c in rec:
        if rec[c].get('mode') != 'fresh_frame': errors.append(f'{c}:not_fresh_recovery')
        try: delta=int(rec[c].get('delta','999'))
        except: delta=999
        if delta < 1 or delta > 3: errors.append(f'{c}:recovery_delta={delta}')
    if c in inj:
        frame=inj[c].get('frame')
        if not any(x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')
"""

inject = (
    "old_reducer=" + repr(old_reducer) + "\n"
    "new_reducer=" + repr(new_reducer) + "\n"
    "if s.count(old_reducer) != 1:\n"
    "    raise SystemExit('FAIL: emitted v2 reducer anchor count='+str(s.count(old_reducer)))\n"
    "s=s.replace(old_reducer,new_reducer,1)\n\n"
)
s=s.replace(anchor, inject+anchor, 1)

# Make the nested self-audit require the new v3 reducer contract.
marker="    'HELIX_VULKAN_DONE frames=220',\n"
replacement=(
    "    \"for c in ('rtx8','gap9','full_reference'):\",\n"
    "    \"fb[c].get('sent_to_decoder') != '0'\",\n"
    "    \"rec[c].get('mode') != 'fresh_frame'\",\n"
    "    \"x.get('stream')=='0' and x.get('frame')==frame and x.get('action')=='applied'\",\n"
    + marker
)
once(marker,replacement,'nested v3 reducer requirements')

# Rename the runtime binding success gate.
once('FIX_V2_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-unchanged',
     'FIX_V3_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-v3-audited',
     'binding success gate')

p.write_text(s)
PY

bash -n "$tmp"
grep -Fq '951ce95cd2ea14bf34e099d2b7e56f272d05cdac' "$tmp" || { echo "FAIL: v3 source binding missing" >&2; exit 2; }
grep -Fq '1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af' "$tmp" || { echo "FAIL: v3 server hash binding missing" >&2; exit 2; }
grep -Fq '1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c' "$tmp" || { echo "FAIL: v3 APK hash binding missing" >&2; exit 2; }
grep -Fq "for c in ('rtx8','gap9','full_reference')" "$tmp" || { echo "FAIL: v3 unified reducer transformer missing" >&2; exit 2; }
grep -Fq 'FIX_V3_RUNTIME_BINDING=PASS exact-source-server-apk-hashes reducer-v3-audited' "$tmp" || { echo "FAIL: v3 binding gate missing" >&2; exit 2; }

exec bash "$tmp"
