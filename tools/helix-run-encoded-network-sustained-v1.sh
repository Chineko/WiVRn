#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="716e5280c327c43fc95d555c42e0dea9c48c89a9"
SOURCE_BRANCH="helix-encoded-sustained-torture-v1-built"
BUILD_ROOT="$HOME/helix-encoded-sustained-torture-v1-build-20261030-214240"
META="$BUILD_ROOT/metadata.txt"
SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"
MANIFEST="$BUILD_ROOT/worktree/build-everything/openxr_wivrn-dev.json"
APK="$BUILD_ROOT/helix-encoded-sustained-torture-v1-716e5280c327.apk"
SERVER_SHA256="d9b0b54d8d8ff5d977fa5f25867885b0d11ac433d4467eb66f7435506214f6e79"
APK_SHA256="5b4c4ba5dbc88ca74e7d232ea7432b0b0d2c088efd75adab8113f6ef99d1e75e"
VERSION_NAME="helix-encoded-sustained-torture-v1-716e5280c327c43fc95d555c42e0dea9c48c89a9"
ARTIFACT_GATE="artifact_gate=PASS encoded-sustained-torture-v1-server-apk-exact-source"
PACKAGE="org.meumeu.wivrn.local"
ACTIVITY="org.meumeu.wivrn.MainActivity"
FRAMES="${HELIX_SUSTAINED_FRAMES:-10800}"
CYCLES="${HELIX_ENCODED_TORTURE_CYCLES:-12}"
SPACING="${HELIX_ENCODED_TORTURE_SPACING_FRAMES:-300}"
START_DELAY="${HELIX_START_DELAY:-20}"
POSITION_LABEL="${HELIX_POSITION_LABEL:-vr_space_stationary}"
EXPECTED=$((CYCLES * 3))

V5_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$V5_ROOT/vulkan-stimulus-v5-seal.txt"
VULKAN_META="$V5_ROOT/vulkan-stimulus-v5-metadata.txt"
DRIVER="$V5_ROOT/helix-vulkan-stimulus-v5"

fail(){ echo "FAIL: $*" >&2; [[ -n "${OUT:-}" ]] && echo "evidence=$OUT" >&2; exit 1; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "missing command $1"; }
for c in adb awk cp dirname find grep head ip kill mkdir pgrep pkill python3 readlink sed seq sha256sum sleep systemctl tail timeout tr git; do need "$c"; done
[[ "$FRAMES" =~ ^[0-9]+$ && "$FRAMES" -ge 1000 ]] || fail "HELIX_SUSTAINED_FRAMES must be integer >=1000"
[[ "$CYCLES" =~ ^[0-9]+$ && "$CYCLES" -ge 1 && "$CYCLES" -le 1000 ]] || fail "HELIX_ENCODED_TORTURE_CYCLES out of range"
[[ "$SPACING" =~ ^[0-9]+$ && "$SPACING" -ge 20 ]] || fail "HELIX_ENCODED_TORTURE_SPACING_FRAMES must be >=20"
[[ "$START_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_START_DELAY must be nonnegative integer"
(( 30 + (EXPECTED - 1) * SPACING + 6 < FRAMES )) || fail "frame budget too small for expected injections"

for f in "$META" "$SERVER" "$MANIFEST" "$APK" "$SEAL" "$VULKAN_META" "$DRIVER"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" && -x "$DRIVER" ]] || fail "runtime executable missing"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
grep -Fqx "source_base=6e23563ec49c6ab8a5e76860b2497b5722c3f591" "$META" || fail "metadata source base mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"
grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "metadata remote mismatch"
grep -Fqx "version_name=$VERSION_NAME" "$META" || fail "metadata version mismatch"
grep -Fqx "server=$SERVER" "$META" || fail "metadata server mismatch"
grep -Fqx "openxr_manifest=$MANIFEST" "$META" || fail "metadata manifest mismatch"
grep -Fqx "apk=$APK" "$META" || fail "metadata APK mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$META" || fail "metadata server hash mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$META" || fail "metadata APK hash mismatch"
grep -Fqx 'server_provenance=PASS exact-patched-commit-direct-link' "$META" || fail "server provenance marker missing"
grep -Fqx "$ARTIFACT_GATE" "$META" || fail "artifact gate marker missing"
grep -Fq 'artifact_seal=PASS strict-v5-source-binary-metadata-deps' "$SEAL" || fail "v5 stimulus seal missing"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$VULKAN_META" || fail "v5 stimulus contract missing"

git fetch -q origin "$SOURCE_BRANCH"
[[ "$(git rev-parse "refs/remotes/origin/$SOURCE_BRANCH")" == "$SOURCE_COMMIT" ]] || fail "sustained source branch moved"

git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'HELIX_ENCODED_TORTURE_CYCLES' || fail "sustained cycles source missing"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'HELIX_ENCODED_TORTURE_SPACING_FRAMES' || fail "sustained spacing source missing"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'switch (helix_encoded_torture.next_case % 3u)' || fail "sustained scenario cycling missing"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3' || fail "fresh recovery semantics missing"

mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t usb < <(printf '%s\n' "${devs[@]}" | grep -v ':' || true)
if [[ ${#usb[@]} -eq 1 ]]; then SERIAL="${usb[0]}"; elif [[ ${#devs[@]} -eq 1 ]]; then SERIAL="${devs[0]}"; else fail "expected one usable ADB device"; fi
FORWARD_OUT="$(adb forward --list 2>/dev/null || true)"
REVERSE_OUT="$(adb reverse --list 2>/dev/null || true)"
[[ -z "$FORWARD_OUT" ]] || fail "ADB forward exists; refusing ambiguous path: $FORWARD_OUT"
[[ -z "$REVERSE_OUT" ]] || fail "ADB reverse exists; refusing ambiguous path: $REVERSE_OUT"
QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 2>/dev/null | awk '/inet / && !found {sub(/\/.*/,"",$2); value=$2; found=1} END {if(found) print value}' | tr -d '\r')"
[[ -n "$QUEST_IP" ]] || fail "Quest wlan0 IPv4 missing"
ROUTE="$(ip -4 route get "$QUEST_IP" 2>/dev/null | head -1)"
[[ -n "$ROUTE" ]] || fail "no host route to Quest"
echo "$ROUTE" | grep -Eq ' dev (lo|usb[^ ]*|rndis[^ ]*|adb[^ ]*) ' && fail "route is not accepted network path: $ROUTE"
HOST_IP="$(printf '%s\n' "$ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"
[[ -n "$HOST_IP" ]] || fail "host route source missing"
echo "SUSTAINED_NETWORK_PATH_GATE=PASS quest_wlan0=$QUEST_IP host_route=$ROUTE host_ip=$HOST_IP adb_forward=none adb_reverse=none"
echo "SUSTAINED_RUNTIME_BINDING=PASS source=$SOURCE_COMMIT frames=$FRAMES cycles=$CYCLES spacing=$SPACING expected=$EXPECTED"

if [[ "${HELIX_PRECHECK_ONLY:-0}" == "1" ]]; then
  echo 'SUSTAINED_AUDIT_A=PASS exact-source-server-apk-sealed-vulkan-lan-path'
  echo 'SUSTAINED_AUDIT_B=PASS frame-keyed-36-event-reducer-and-bounded-frame-budget'
  exit 0
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
OUT="$HOME/helix-encoded-sustained-runtime-$STAMP"
mkdir -p "$OUT"
cat >"$OUT/metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
server=$SERVER
server_sha256=$SERVER_SHA256
openxr_manifest=$MANIFEST
apk=$APK
apk_sha256=$APK_SHA256
vulkan_stimulus=$DRIVER
frames=$FRAMES
cycles=$CYCLES
spacing_frames=$SPACING
expected_injections=$EXPECTED
position_label=$POSITION_LABEL
quest_ip=$QUEST_IP
host_ip=$HOST_IP
host_route=$ROUTE
adb_forward=none
adb_reverse=none
EOF

active_units=()
SERVER_PID=""; LOGCAT_PID=""
cleanup(){
  set +e
  [[ -n "$LOGCAT_PID" ]] && kill "$LOGCAT_PID" >/dev/null 2>&1
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" >/dev/null 2>&1; then
    kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
    wait "$SERVER_PID" >/dev/null 2>&1 || true
  fi
  adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
  for u in "${active_units[@]}"; do systemctl --user start "$u" >/dev/null 2>&1; done
}
trap cleanup EXIT INT TERM

echo '[1/8] Installing exact sustained Quest APK'
adb -s "$SERIAL" install -r -d "$APK" >"$OUT/adb-install.txt" 2>&1 || fail "APK install failed"
adb -s "$SERIAL" shell dumpsys package "$PACKAGE" >"$OUT/package.txt"
grep -Fq "versionName=$VERSION_NAME" "$OUT/package.txt" || fail "installed versionName mismatch"

echo '[2/8] Establishing clean runtime ownership while preserving trust state'
mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
for u in "${active_units[@]}"; do systemctl --user stop "$u" || true; done
pkill -x wivrn-dashboard >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
sleep 1
pgrep -x wivrn-server >/dev/null && fail "old wivrn-server survived cleanup"
pgrep -x wivrn-dashboard >/dev/null && fail "old wivrn-dashboard survived cleanup"

TEST_CONFIG="$OUT/config.json"
cat >"$TEST_CONFIG" <<'EOF'
{
  "encoder": {"encoder": "nvenc", "codec": "h264"},
  "publish-service": "none"
}
EOF

adb -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
adb -s "$SERIAL" logcat -v threadtime >"$OUT/quest-logcat.txt" 2>&1 & LOGCAT_PID=$!
PREFIX="$(find "$(dirname "$(dirname "$SERVER")")" -type f -path '*/dashboard/prefix.sh' | head -1 || true)"
[[ -n "$PREFIX" && -f "$PREFIX" ]] || fail "runtime prefix.sh missing"
SERVER_LOG="$OUT/server-log.txt"
(
  set +u
  source "$PREFIX"
  set -u
  export HELIX_ENCODED_TORTURE=1
  export HELIX_ENCODED_TORTURE_CYCLES="$CYCLES"
  export HELIX_ENCODED_TORTURE_SPACING_FRAMES="$SPACING"
  exec "$SERVER" -f "$TEST_CONFIG" --no-publish-service --no-manage-active-runtime
) >"$SERVER_LOG" 2>&1 & SERVER_PID=$!
printf 'server_log=%s\nserver_pid=%s\n' "$SERVER_LOG" "$SERVER_PID" >>"$OUT/metadata.txt"
for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" && break
  sleep .1
done
grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing"
SERVER_EXE="$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)"
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server identity mismatch: $SERVER_EXE != $SERVER"
printf 'server_exe=%s\n' "$SERVER_EXE" >>"$OUT/metadata.txt"

echo '[3/8] Launching Quest directly and requiring trusted WLAN connection'
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb -s "$SERIAL" shell am start -W -a android.intent.action.VIEW -d "wivrn+tcp://${HOST_IP}" -n "$PACKAGE/$ACTIVITY" >"$OUT/launch.txt" 2>&1 || fail "Quest launch failed"
CONNECTED=0
for _ in $(seq 1 200); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited before trusted Quest connection"
  grep -Fq 'To pair a new headset use PIN code:' "$SERVER_LOG" && fail "server entered pairing mode"
  if grep -Fq 'Client connected' "$SERVER_LOG"; then CONNECTED=1; break; fi
  sleep .1
done
[[ "$CONNECTED" -eq 1 ]] || fail "Quest did not establish trusted connection"

echo 'SUSTAINED_UNPLUG_GATE=READY trusted-quest-connected network-path-proven unplug-usb-now'
echo "UNPLUG USB NOW - sustained WiVRn workload starts after ${START_DELAY}s"
echo "SUSTAINED_START_DELAY seconds=$START_DELAY position_label=$POSITION_LABEL"
for ((remaining=START_DELAY; remaining>0; remaining--)); do
  printf '\rSustained NVENC workload starts in %2d s ' "$remaining"
  sleep 1
done
printf '\rSustained NVENC workload starts now      \n'

echo "[4/8] Driving $FRAMES graphics-bound Vulkan/OpenXR frames through NVENC"
set +e
XR_RUNTIME_JSON="$MANIFEST" timeout --signal=TERM --kill-after=5s 240s "$DRIVER" "$FRAMES" >"$OUT/vulkan.txt" 2>&1
DRIVER_STATUS=$?
set -e
echo "driver_status=$DRIVER_STATUS" >>"$OUT/metadata.txt"
[[ "$DRIVER_STATUS" -eq 0 ]] || fail "graphics-bound Vulkan/OpenXR stimulus failed"
grep -Fq "HELIX_VULKAN_DONE frames=$FRAMES" "$OUT/vulkan.txt" || fail "Vulkan stimulus did not complete $FRAMES frames"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$OUT/vulkan.txt" || fail "Vulkan entropy contract did not execute"

sleep 3
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep 1
kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
for _ in $(seq 1 100); do kill -0 "$SERVER_PID" >/dev/null 2>&1 || break; sleep .1; done
kill -0 "$SERVER_PID" >/dev/null 2>&1 && fail "wivrn-server did not terminate for summary flush"
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
sleep .5
kill "$LOGCAT_PID" >/dev/null 2>&1 || true
wait "$LOGCAT_PID" >/dev/null 2>&1 || true
LOGCAT_PID=""

echo '[5/8] Verifying exact runtime identity and NVENC capability'
grep -Fq 'HELIX_ENCODED_NVENC_CAP stream=0 supported=1' "$SERVER_LOG" || fail "NVENC reference invalidation capability not active"
grep -Fq 'HELIX_ENCODED_NVENC_CAP stream=1 supported=1' "$SERVER_LOG" || fail "control stream NVENC capability not active"

echo '[6/8] Reducing sustained encoded recovery semantics'
set +e
python3 - "$SERVER_LOG" "$OUT/quest-logcat.txt" "$OUT/result.txt" "$EXPECTED" <<'PY'
import re,sys
from pathlib import Path
s=Path(sys.argv[1]).read_text(errors='replace')
q=Path(sys.argv[2]).read_text(errors='replace')
out=Path(sys.argv[3]); expected=int(sys.argv[4])
def lines(tag): return [x for x in s.splitlines() if tag in x]
def kv(line): return {k:v for k,v in re.findall(r'([A-Za-z_]+)=([^\s]+)',line)}
injs=[kv(x) for x in lines('HELIX_ENCODED_INJECT scenario=')]
dones=[kv(x) for x in lines('HELIX_ENCODED_INJECT_DONE')]
fbs=[kv(x) for x in lines('HELIX_ENCODED_FEEDBACK')]
recs=[kv(x) for x in lines('HELIX_ENCODED_RECOVERY')]
invs=[kv(x) for x in lines('HELIX_ENCODED_INVALIDATION')]
summ=[kv(x) for x in lines('HELIX_ENCODED_TORTURE_SUMMARY')]
errors=[]
def unique_by(items,key):
    d={}
    for x in items:
        k=x.get(key)
        if k in d: errors.append(f'duplicate_{key}={k}')
        d[k]=x
    return d
inj=unique_by(injs,'frame'); done=unique_by(dones,'frame'); fb=unique_by(fbs,'frame'); rec=unique_by(recs,'lost_frame')
if len(injs)!=expected: errors.append(f'injections={len(injs)} expected={expected}')
seq=['rtx8','gap9','full_reference']
for i,x in enumerate(injs):
    frame=x.get('frame'); scenario=x.get('scenario'); want=seq[i%3]
    if scenario!=want: errors.append(f'frame={frame}:scenario={scenario}:expected={want}')
    d=done.get(frame); f=fb.get(frame); r=rec.get(frame)
    if not d: errors.append(f'frame={frame}:missing_done'); continue
    if d.get('scenario')!=scenario: errors.append(f'frame={frame}:done_scenario_mismatch')
    try: dropped=int(d.get('dropped','-1')); total=int(d.get('total_shards','-2'))
    except: dropped,total=-1,-2
    if scenario=='rtx8' and dropped!=8: errors.append(f'frame={frame}:rtx8_drop={dropped}')
    if scenario=='gap9' and dropped!=9: errors.append(f'frame={frame}:gap9_drop={dropped}')
    if scenario=='full_reference' and (dropped<=0 or dropped!=total): errors.append(f'frame={frame}:full_reference_drop={dropped}/{total}')
    if not f: errors.append(f'frame={frame}:missing_feedback')
    elif f.get('sent_to_decoder')!='0': errors.append(f'frame={frame}:expected_incomplete')
    if not r: errors.append(f'frame={frame}:missing_recovery')
    else:
        if r.get('scenario')!=scenario: errors.append(f'frame={frame}:recovery_scenario_mismatch')
        if r.get('mode')!='fresh_frame': errors.append(f'frame={frame}:recovery_mode={r.get("mode")}')
        try: delta=int(r.get('delta','999'))
        except: delta=999
        if delta<1 or delta>3: errors.append(f'frame={frame}:recovery_delta={delta}')
    if not any(v.get('stream')=='0' and v.get('frame')==frame and v.get('action')=='applied' for v in invs):
        errors.append(f'frame={frame}:invalidation_not_applied')
if len(done)!=expected: errors.append(f'done={len(done)} expected={expected}')
if len(fb)!=expected: errors.append(f'feedback={len(fb)} expected={expected}')
if len(rec)!=expected: errors.append(f'recoveries={len(rec)} expected={expected}')
if not summ: errors.append('missing_summary')
else:
    z=summ[-1]
    for k,v in [('injected',expected),('feedback',expected),('recovered',expected),('next_case',expected)]:
        if z.get(k)!=str(v): errors.append(f'summary_{k}={z.get(k)} expected={v}')
    if z.get('dirty')!='0': errors.append(f'summary_dirty={z.get("dirty")}')
crash=bool(re.search(r'Fatal signal|SIGABRT|Assertion.*failed|FATAL EXCEPTION|ANR in org\.meumeu\.wivrn',q,re.I))
if crash: errors.append('quest_crash_marker')
verdict='PASS' if not errors else 'FAIL'
text='\n'.join([
    f'verdict={verdict}',
    f'expected={expected} injections={len(injs)} feedback={len(fbs)} recoveries={len(recs)} invalidations={len(invs)}',
    'errors=' + (','.join(errors) if errors else 'none')
])+'\n'
out.write_text(text); print(text,end='')
raise SystemExit(0 if verdict=='PASS' else 1)
PY
REDUCE_STATUS=$?
set -e

echo '[7/8] Final sustained NVENC verdict'
cat "$OUT/result.txt"
if [[ "$REDUCE_STATUS" -ne 0 ]]; then echo "evidence=$OUT"; exit 1; fi

echo '[8/8] PASS'
echo 'verdict=ENCODED_NVENC_SUSTAINED_PASS'
echo "evidence=$OUT"
