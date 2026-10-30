#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
PACKAGE="org.meumeu.wivrn.local"
ACTIVITY="org.meumeu.wivrn.MainActivity"
STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/helix-encoded-nvenc-runtime-$STAMP"
mkdir -p "$OUT"

fail(){ echo "FAIL: $*" >&2; echo "evidence=$OUT" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "missing command $1"; }
for c in adb awk grep sed sort tail head sha256sum timeout pgrep pkill readlink realpath systemctl python3; do need "$c"; done

mapfile -t metas < <(grep -l "^source_commit=${SOURCE_COMMIT}$" "$HOME"/helix-encoded-nvenc-build-*/resume-metadata.txt 2>/dev/null | sort)
[[ ${#metas[@]} -gt 0 ]] || fail "no salvaged encoded artifact set for $SOURCE_COMMIT"
META="${metas[-1]}"
SERVER="$(sed -n 's/^server=//p' "$META" | tail -1)"
DASHBOARD="$(sed -n 's/^dashboard=//p' "$META" | tail -1)"
MANIFEST="$(sed -n 's/^openxr_manifest=//p' "$META" | tail -1)"
APK="$(sed -n 's/^apk=//p' "$META" | tail -1)"
DRIVER="$(sed -n 's/^headless_driver=//p' "$META" | tail -1)"
for f in "$SERVER" "$DASHBOARD" "$MANIFEST" "$APK" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DASHBOARD" && -x "$DRIVER" ]] || fail "runtime executable missing"
grep -Fq 'provenance=PASS direct-executable-build-graph' "$META" || fail "desktop provenance marker missing"
grep -Fq 'artifact_gate=PASS salvaged-existing-desktop-plus-apk-headless' "$META" || fail "artifact gate marker missing"

# Prefer exactly one USB ADB device; reject ambiguity.
mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t usb < <(printf '%s\n' "${devs[@]}" | grep -v ':' || true)
if [[ ${#usb[@]} -eq 1 ]]; then SERIAL="${usb[0]}"; elif [[ ${#devs[@]} -eq 1 ]]; then SERIAL="${devs[0]}"; else fail "expected one usable ADB device"; fi

SCREEN="$(adb -s "$SERIAL" shell dumpsys power 2>/dev/null | tr -d '\r' | grep -E 'mWakefulness=|Display Power:' || true)"
echo "$SCREEN" >"$OUT/preflight.txt"
grep -Eq 'Awake|state=ON' "$OUT/preflight.txt" || fail "Quest is not awake; wear it and keep display on"

APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
cat >"$OUT/metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
artifact_metadata=$META
server=$SERVER
dashboard=$DASHBOARD
openxr_manifest=$MANIFEST
apk=$APK
apk_sha256=$APK_SHA
headless_driver=$DRIVER
adb_serial=$SERIAL
EOF

active_units=()
DASH_PID=""; LOGCAT_PID=""
cleanup(){
  set +e
  [[ -n "$LOGCAT_PID" ]] && kill "$LOGCAT_PID" >/dev/null 2>&1
  [[ -n "$DASH_PID" ]] && kill "$DASH_PID" >/dev/null 2>&1
  adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1
  for u in "${active_units[@]}"; do systemctl --user start "$u" >/dev/null 2>&1; done
}
trap cleanup EXIT INT TERM

echo '[1/8] Installing exact matching Quest APK'
adb -s "$SERIAL" install -r -d "$APK" >"$OUT/adb-install.txt" 2>&1 || fail "APK install failed"
adb -s "$SERIAL" shell dumpsys package "$PACKAGE" >"$OUT/package.txt"
grep -Fq "versionName=helix-encoded-${SOURCE_COMMIT}" "$OUT/package.txt" || fail "installed versionName mismatch"

echo '[2/8] Establishing clean runtime ownership and NVENC-only config'
mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
for u in "${active_units[@]}"; do systemctl --user stop "$u" || true; done
pkill -x wivrn-dashboard >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
sleep 1
pgrep -x wivrn-server >/dev/null && fail "old wivrn-server survived cleanup"
pgrep -x wivrn-dashboard >/dev/null && fail "old wivrn-dashboard survived cleanup"

XDG="$OUT/xdg-config"; mkdir -p "$XDG/wivrn"
cat >"$XDG/wivrn/config.json" <<'EOF'
{
  "encoder": {"encoder": "nvenc", "codec": "h264"},
  "publish-service": "avahi"
}
EOF

adb -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
adb -s "$SERIAL" logcat -v threadtime >"$OUT/quest-logcat.txt" 2>&1 & LOGCAT_PID=$!

BUILD_ROOT="$(dirname "$(dirname "$SERVER")")"
PREFIX="$(find "$BUILD_ROOT" -type f -path '*/dashboard/prefix.sh' | head -1 || true)"
[[ -n "$PREFIX" && -f "$PREFIX" ]] || fail "dashboard prefix.sh missing"
(
  set +u
  source "$PREFIX"
  set -u
  export XDG_CONFIG_HOME="$XDG"
  export HELIX_ENCODED_TORTURE=1
  exec "$DASHBOARD"
) >"$OUT/dashboard.txt" 2>&1 & DASH_PID=$!

SERVER_LOG=""
for _ in $(seq 1 150); do
  kill -0 "$DASH_PID" 2>/dev/null || fail "dashboard exited during startup"
  SERVER_LOG="$(python3 - "$OUT/dashboard.txt" <<'PY'
import re,sys,pathlib
p=pathlib.Path(sys.argv[1]); t=p.read_text(errors='replace') if p.exists() else ''
m=re.findall(r'Saving logs in\s+"([^"]*server_logs_[^"]+\.txt)"',t)
print(m[-1] if m else '')
PY
)"
  [[ -n "$SERVER_LOG" && -s "$SERVER_LOG" ]] && break
  sleep .1
done
[[ -n "$SERVER_LOG" && -s "$SERVER_LOG" ]] || fail "authoritative server log not found"
printf 'server_log=%s\n' "$SERVER_LOG" >>"$OUT/metadata.txt"

echo '[3/8] Launching Quest directly at the exact server'
QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\r' | awk '/inet /{sub(/\/.*/,"",$2); print $2; exit}')"
[[ -n "$QUEST_IP" ]] || fail "Quest wlan0 IPv4 missing"
HOST_IP="$(ip -4 route get "$QUEST_IP" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
[[ -n "$HOST_IP" ]] || fail "host route source missing"
printf 'quest_ip=%s\nhost_ip=%s\n' "$QUEST_IP" "$HOST_IP" >>"$OUT/metadata.txt"
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb -s "$SERIAL" shell am start -W -a android.intent.action.VIEW -d "wivrn+tcp://${HOST_IP}" -n "$PACKAGE/$ACTIVITY" >"$OUT/launch.txt" 2>&1 || fail "Quest launch failed"
sleep 3

echo '[4/8] Driving 220 real OpenXR frames through NVENC'
set +e
XR_RUNTIME_JSON="$MANIFEST" timeout --signal=TERM --kill-after=5s 90s "$DRIVER" 220 >"$OUT/headless.txt" 2>&1
DRIVER_STATUS=$?
set -e
echo "driver_status=$DRIVER_STATUS" >>"$OUT/metadata.txt"
[[ "$DRIVER_STATUS" -eq 0 ]] || fail "headless OpenXR driver failed"
grep -Fq 'HELIX_HEADLESS_DONE frames=220' "$OUT/headless.txt" || fail "headless driver did not complete 220 frames"

# Let final feedback and encoder summaries drain.
sleep 3
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep 1
kill "$DASH_PID" >/dev/null 2>&1 || true; wait "$DASH_PID" >/dev/null 2>&1 || true; DASH_PID=""
kill "$LOGCAT_PID" >/dev/null 2>&1 || true; wait "$LOGCAT_PID" >/dev/null 2>&1 || true; LOGCAT_PID=""
cp "$SERVER_LOG" "$OUT/server-log.txt"

echo '[5/8] Verifying exact runtime identity and NVENC capability'
grep -Fq "$SOURCE_COMMIT" "$OUT/server-log.txt" || fail "server log missing exact commit"
grep -Fq 'HELIX_ENCODED_NVENC_CAP stream=0 supported=1' "$OUT/server-log.txt" || fail "NVENC reference invalidation capability was not active"
grep -Fq 'HELIX_ENCODED_NVENC_CAP stream=1 supported=1' "$OUT/server-log.txt" || fail "control stream NVENC capability was not active"

echo '[6/8] Reducing encoded recovery semantics'
python3 - "$OUT/server-log.txt" "$OUT/quest-logcat.txt" "$OUT/result.txt" <<'PY'
import re,sys
from pathlib import Path
s=Path(sys.argv[1]).read_text(errors='replace')
q=Path(sys.argv[2]).read_text(errors='replace')
out=Path(sys.argv[3])

def lines(tag): return [x for x in s.splitlines() if tag in x]

def parse_kv(line):
    return {k:v for k,v in re.findall(r'([A-Za-z_]+)=([^\s]+)',line)}
inj={parse_kv(x).get('scenario'):parse_kv(x) for x in lines('HELIX_ENCODED_INJECT scenario=')}
done={parse_kv(x).get('scenario'):parse_kv(x) for x in lines('HELIX_ENCODED_INJECT_DONE')}
fb={parse_kv(x).get('scenario'):parse_kv(x) for x in lines('HELIX_ENCODED_FEEDBACK')}
rec={parse_kv(x).get('scenario'):parse_kv(x) for x in lines('HELIX_ENCODED_RECOVERY')}
inv=[parse_kv(x) for x in lines('HELIX_ENCODED_INVALIDATION')]
summ=[parse_kv(x) for x in lines('HELIX_ENCODED_TORTURE_SUMMARY')]
errors=[]
for c in ('rtx8','gap9','full_reference'):
    if c not in inj: errors.append(f'{c}:missing_inject')
    if c not in done: errors.append(f'{c}:missing_done')
    if c not in fb: errors.append(f'{c}:missing_feedback')
    if c not in rec: errors.append(f'{c}:missing_recovery')
if 'rtx8' in done and int(done['rtx8'].get('dropped','-1')) != 8: errors.append('rtx8:drop_count')
if 'gap9' in done and int(done['gap9'].get('dropped','-1')) != 9: errors.append('gap9:drop_count')
if 'full_reference' in done:
    d=int(done['full_reference'].get('dropped','-1')); t=int(done['full_reference'].get('total_shards','-2'))
    if d <= 0 or d != t: errors.append('full_reference:not_full_erasure')
if 'rtx8' in fb and fb['rtx8'].get('sent_to_decoder') != '1': errors.append('rtx8:not_same_frame_decoded')
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
        if not any(x.get('frame')==frame and x.get('action')=='applied' for x in inv): errors.append(f'{c}:invalidation_not_applied')
if 'rtx8' in inj:
    frame=inj['rtx8'].get('frame')
    if any(x.get('frame')==frame for x in inv): errors.append('rtx8:unexpected_invalidation')
if not summ: errors.append('missing_summary')
else:
    z=summ[-1]
    if z.get('injected')!='3' or z.get('feedback')!='3' or z.get('recovered')!='3' or z.get('dirty')!='0' or z.get('next_case')!='3': errors.append('summary_not_clean')
crash=bool(re.search(r'Fatal signal|SIGABRT|Assertion.*failed|FATAL EXCEPTION|ANR in org\.meumeu\.wivrn',q,re.I))
if crash: errors.append('quest_crash_marker')
verdict='PASS' if not errors else 'FAIL'
text='\n'.join([
 f'verdict={verdict}',
 f'injections={len(inj)} feedback={len(fb)} recoveries={len(rec)} invalidations={len(inv)}',
 'errors=' + (','.join(errors) if errors else 'none'),
])+'\n'
out.write_text(text); print(text,end='')
raise SystemExit(0 if verdict=='PASS' else 1)
PY
REDUCE_STATUS=$?

echo '[7/8] Final encoded NVENC verdict'
cat "$OUT/result.txt"
if [[ "$REDUCE_STATUS" -ne 0 ]]; then echo "evidence=$OUT"; exit 1; fi

echo '[8/8] PASS'
echo 'verdict=ENCODED_NVENC_TORTURE_PASS'
echo "evidence=$OUT"
