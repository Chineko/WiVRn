#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="b8c9cac4ecc63ca92984c0f02238a2d0263fad0e"
SEAL_TOOLING_COMMIT="f18d7eded6dc4cf69a4a80190330798f73d53184"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
META="$OUT_ROOT/runtime-v1-metadata.txt"
SEAL="$OUT_ROOT/runtime-v1-seal.txt"
SERVER="$OUT_ROOT/wivrn-server-hevc10-recovery-v1"
APK="$OUT_ROOT/helix-hevc10-recovery-392bb662ed20.apk"
SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"
APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"
META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
VERSION_NAME="helix-hevc10-decoder-recovery-v1-${SOURCE_COMMIT}"

STIM_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
STIM_SRC="$STIM_ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
STIM_BIN="$STIM_ROOT/helix-vulkan-stimulus-sustained-v1"
STIM_META="$STIM_ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
STIM_SEAL="$STIM_ROOT/vulkan-stimulus-sustained-v1-seal.txt"
STIM_SRC_SHA256="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
STIM_BIN_SHA256="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
STIM_META_SHA256="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"
FRAMES=1200

PACKAGE="org.meumeu.wivrn.local"
ACTIVITY="org.meumeu.wivrn.MainActivity"
QUEST_IP_EXPECTED="192.168.0.54"
HOST_IP_EXPECTED="192.168.0.44"
HOST_DEV_EXPECTED="enp14s0"
URI="wivrn+tcp://${HOST_IP_EXPECTED}"
STAMP="$(date +%Y%m%d-%H%M%S)"
EVIDENCE="$OUT_ROOT/run-$STAMP"
mkdir -p "$EVIDENCE"

fail(){ echo "FAIL: $*" >&2; echo "evidence=$EVIDENCE" >&2; exit 2; }
need(){ command -v "$1" >/dev/null 2>&1 || fail "missing command $1"; }
for c in adb awk find grep ip kill mkdir pgrep pkill python3 readlink seq sha256sum sleep systemctl timeout tr; do need "$c"; done

# Exact artifact and frozen stimulus identity before touching the headset.
for f in "$META" "$SEAL" "$SERVER" "$APK" "$STIM_SRC" "$STIM_BIN" "$STIM_META" "$STIM_SEAL"; do
  [[ -s "$f" ]] || fail "required sealed artifact missing: $f"
done
[[ -x "$SERVER" && -x "$STIM_BIN" ]] || fail "runtime executable missing"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$META_SHA256" ]] || fail "runtime metadata hash mismatch"
[[ "$(sha256sum "$STIM_SRC" | awk '{print $1}')" == "$STIM_SRC_SHA256" ]] || fail "sustained stimulus source hash mismatch"
[[ "$(sha256sum "$STIM_BIN" | awk '{print $1}')" == "$STIM_BIN_SHA256" ]] || fail "sustained stimulus binary hash mismatch"
[[ "$(sha256sum "$STIM_META" | awk '{print $1}')" == "$STIM_META_SHA256" ]] || fail "sustained stimulus metadata hash mismatch"

grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"
grep -Fqx "version_name=$VERSION_NAME" "$META" || fail "metadata version mismatch"
grep -Fqx "server=$SERVER" "$META" || fail "metadata server path mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$META" || fail "metadata server hash mismatch"
grep -Fqx "apk=$APK" "$META" || fail "metadata APK path mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$META" || fail "metadata APK hash mismatch"
grep -Fqx 'encoder_contract=nvenc-h265-main10-both-eye-streams-runtime-hard-gate' "$META" || fail "encoder contract missing"
grep -Fqx 'fault_contract=one-cached-shard0-withheld-per-eye-ordinals-600-900-exact-packet-rtx-bound' "$META" || fail "fault contract missing"
grep -Fqx 'runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts' "$META" || fail "runtime oracle mismatch"
grep -Fqx 'probe_overflow_required=0' "$META" || fail "probe overflow contract missing"
grep -Fqx 'pixel_cleanliness=NOT_ESTABLISHED' "$META" || fail "claim boundary missing"
grep -Fqx 'artifact_gate=PASS hevc10-decoder-recovery-v1-exact-source-server-apk' "$META" || fail "build gate marker missing"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "seal source mismatch"
grep -Fqx "build_tooling_commit=$BUILD_TOOLING_COMMIT" "$SEAL" || fail "seal build tooling mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$SEAL" || fail "seal server hash mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$SEAL" || fail "seal APK hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA256" "$SEAL" || fail "seal metadata hash mismatch"
grep -Fqx 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$SEAL" || fail "seal gate marker missing"

grep -Fqx "source_sha256=$STIM_SRC_SHA256" "$STIM_SEAL" || fail "stimulus seal source mismatch"
grep -Fqx "binary_sha256=$STIM_BIN_SHA256" "$STIM_SEAL" || fail "stimulus seal binary mismatch"
grep -Fqx "metadata_sha256=$STIM_META_SHA256" "$STIM_SEAL" || fail "stimulus seal metadata mismatch"
grep -Fqx 'artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps' "$STIM_SEAL" || fail "stimulus seal marker missing"
grep -Fqx 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360' "$STIM_META" || fail "stimulus contract missing"
grep -Fqx 'render_deadline_seconds=360' "$STIM_META" || fail "stimulus deadline mismatch"

# Resolve build-generated OpenXR manifest and runtime environment from this exact source build.
mapfile -t manifests < <(find "$OUT_ROOT/worktree/build-server" -type f -name 'openxr_wivrn-dev.json' -print 2>/dev/null)
[[ ${#manifests[@]} -eq 1 ]] || fail "expected one exact-source OpenXR manifest, found ${#manifests[@]}"
MANIFEST="${manifests[0]}"
mapfile -t prefixes < <(find "$OUT_ROOT/worktree/build-server" -type f -path '*/dashboard/prefix.sh' -print 2>/dev/null)
[[ ${#prefixes[@]} -eq 1 ]] || fail "expected one exact-source prefix.sh, found ${#prefixes[@]}"
PREFIX="${prefixes[0]}"

# Require exactly one usable ADB device. ADB is control/evidence only; transport is LAN.
mapfile -t devs < <(adb devices | awk 'NR>1 && $2=="device" {print $1}')
mapfile -t usb < <(printf '%s\n' "${devs[@]}" | grep -v ':' || true)
if [[ ${#usb[@]} -eq 1 ]]; then SERIAL="${usb[0]}"; elif [[ ${#devs[@]} -eq 1 ]]; then SERIAL="${devs[0]}"; else fail "expected one usable ADB device"; fi

FORWARD_LIST="$(adb forward --list 2>/dev/null || true)"
REVERSE_LIST="$(adb -s "$SERIAL" reverse --list 2>/dev/null || true)"
[[ -z "$FORWARD_LIST" ]] || fail "ADB forward exists; LAN-only transport proof requires none"
[[ -z "$REVERSE_LIST" ]] || fail "ADB reverse exists; LAN-only transport proof requires none"
QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 | tr -d '\r' | awk '/inet / && !found {sub(/\/.*/,"",$2); value=$2; found=1} END {if(found) print value}')"
[[ "$QUEST_IP" == "$QUEST_IP_EXPECTED" ]] || fail "Quest wlan0 address mismatch: $QUEST_IP"
ROUTE="$(ip -4 route get "$QUEST_IP_EXPECTED" | head -1)"
HOST_IP="$(awk '{for(i=1;i<=NF;i++) if($i=="src" && !s){s=$(i+1)}} END{print s}' <<<"$ROUTE")"
HOST_DEV="$(awk '{for(i=1;i<=NF;i++) if($i=="dev" && !d){d=$(i+1)}} END{print d}' <<<"$ROUTE")"
[[ "$HOST_IP" == "$HOST_IP_EXPECTED" ]] || fail "host route source mismatch: $HOST_IP"
[[ "$HOST_DEV" == "$HOST_DEV_EXPECTED" ]] || fail "host route device mismatch: $HOST_DEV"

cat >"$EVIDENCE/metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
server=$SERVER
server_sha256=$SERVER_SHA256
apk=$APK
apk_sha256=$APK_SHA256
runtime_metadata_sha256=$META_SHA256
openxr_manifest=$MANIFEST
prefix=$PREFIX
stimulus=$STIM_BIN
stimulus_source_sha256=$STIM_SRC_SHA256
stimulus_binary_sha256=$STIM_BIN_SHA256
stimulus_metadata_sha256=$STIM_META_SHA256
frames=$FRAMES
adb_serial=$SERIAL
quest_ip=$QUEST_IP
host_ip=$HOST_IP
host_dev=$HOST_DEV
uri=$URI
transport=LAN-only-no-adb-forward-reverse
requested_encoder=nvenc
requested_codec=h265
requested_bit_depth=10
runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts
pixel_cleanliness=NOT_ESTABLISHED
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
  for u in "${active_units[@]}"; do systemctl --user start "$u" >/dev/null 2>&1 || true; done
}
trap cleanup EXIT INT TERM

echo '[1/8] Installing exact matching Quest APK'
adb -s "$SERIAL" install -r -d "$APK" >"$EVIDENCE/adb-install.txt" 2>&1 || fail "APK install failed"
adb -s "$SERIAL" shell dumpsys package "$PACKAGE" >"$EVIDENCE/package.txt"
grep -Fq "versionName=$VERSION_NAME" "$EVIDENCE/package.txt" || fail "installed versionName mismatch"

echo '[2/8] Taking exclusive WiVRn runtime ownership without touching trust state'
mapfile -t active_units < <(systemctl --user list-units --type=service --state=active --no-legend 2>/dev/null | awk 'tolower($1) ~ /wivrn/ {print $1}')
for u in "${active_units[@]}"; do systemctl --user stop "$u" || true; done
pkill -x wivrn-dashboard >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
sleep 1
pgrep -x wivrn-server >/dev/null && fail "old wivrn-server survived cleanup"
pgrep -x wivrn-dashboard >/dev/null && fail "old wivrn-dashboard survived cleanup"

TEST_CONFIG="$EVIDENCE/config.json"
cat >"$TEST_CONFIG" <<'EOF'
{
  "encoder": {"encoder": "nvenc", "codec": "h265"},
  "bit-depth": 10,
  "publish-service": "none"
}
EOF
python3 - "$TEST_CONFIG" <<'PY'
import json,sys
j=json.load(open(sys.argv[1]))
assert j == {"encoder":{"encoder":"nvenc","codec":"h265"},"bit-depth":10,"publish-service":"none"}
PY

adb -s "$SERIAL" logcat -c >/dev/null 2>&1 || true
adb -s "$SERIAL" logcat -v threadtime >"$EVIDENCE/quest-logcat.txt" 2>&1 & LOGCAT_PID=$!
SERVER_LOG="$EVIDENCE/server-log.txt"
(
  set +u
  source "$PREFIX"
  set -u
  export HELIX_HEVC10_RECOVERY=1
  exec "$SERVER" -f "$TEST_CONFIG" --no-publish-service --no-manage-active-runtime
) >"$SERVER_LOG" 2>&1 & SERVER_PID=$!
printf 'server_log=%s\nserver_pid=%s\n' "$SERVER_LOG" "$SERVER_PID" >>"$EVIDENCE/metadata.txt"
for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" && break
  sleep .1
done
grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing"
SERVER_EXE="$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)"
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server identity mismatch: $SERVER_EXE"
printf 'server_exe=%s\n' "$SERVER_EXE" >>"$EVIDENCE/metadata.txt"

echo '[3/8] Launching Quest over explicit LAN URI and requiring trusted connection'
adb -s "$SERIAL" shell input keyevent 224 >/dev/null 2>&1 || true
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
adb -s "$SERIAL" shell am start -W -a android.intent.action.VIEW -d "$URI" -n "$PACKAGE/$ACTIVITY" >"$EVIDENCE/launch.txt" 2>&1 || fail "Quest launch failed"
CONNECTED=0
for _ in $(seq 1 200); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited before trusted Quest connection"
  grep -Fq 'To pair a new headset use PIN code:' "$SERVER_LOG" && fail "server entered pairing mode; existing trust state was not visible"
  if grep -Fq 'Client connected' "$SERVER_LOG"; then CONNECTED=1; break; fi
  sleep .1
done
[[ "$CONNECTED" -eq 1 ]] || fail "Quest did not establish trusted connection"

# Do not trust the request alone: wait for the resolved encoder path to prove Main10 on both eyes.
echo '[4/8] Proving resolved NVENC H.265 Main10 on both eyes'
for _ in $(seq 1 200); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "server exited before HEVC10 encoder gates"
  if grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" &&
     grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" &&
     grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG" &&
     grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG"; then
    break
  fi
  sleep .1
done
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" || fail "eye 0 HEVC10 encoder gate missing"
grep -Fq 'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10' "$SERVER_LOG" || fail "eye 1 HEVC10 encoder gate missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG" || fail "eye 0 Main10 profile marker missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10' "$SERVER_LOG" || fail "eye 1 Main10 profile marker missing"
grep -Fq 'HELIX_HEVC10_FAULT_PLAN stream=0 target_ordinal=600 shard=0' "$SERVER_LOG" || fail "eye 0 fault plan missing"
grep -Fq 'HELIX_HEVC10_FAULT_PLAN stream=1 target_ordinal=900 shard=0' "$SERVER_LOG" || fail "eye 1 fault plan missing"

echo '[5/8] Driving 1200 sealed graphics-bound OpenXR frames'
set +e
XR_RUNTIME_JSON="$MANIFEST" timeout --signal=TERM --kill-after=5s 180s "$STIM_BIN" "$FRAMES" >"$EVIDENCE/vulkan.txt" 2>&1
STIM_STATUS=$?
set -e
printf 'stimulus_status=%s\n' "$STIM_STATUS" >>"$EVIDENCE/metadata.txt"
[[ "$STIM_STATUS" -eq 0 ]] || fail "sustained Vulkan stimulus failed"
grep -Fq "HELIX_VULKAN_DONE frames=$FRAMES" "$EVIDENCE/vulkan.txt" || fail "stimulus did not complete $FRAMES renderable frames"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$EVIDENCE/vulkan.txt" || fail "sealed entropy stimulus contract did not execute"

# Give asynchronous decoder output a bounded drain, then close the server so the
# Quest decoder emits its bounded-ledger summary before logcat is stopped.
sleep 2
kill -TERM "$SERVER_PID" >/dev/null 2>&1 || true
for _ in $(seq 1 150); do
  kill -0 "$SERVER_PID" >/dev/null 2>&1 || break
  sleep .1
done
kill -0 "$SERVER_PID" >/dev/null 2>&1 && fail "wivrn-server did not terminate for summary flush"
wait "$SERVER_PID" >/dev/null 2>&1 || true
SERVER_PID=""
for _ in $(seq 1 100); do
  if grep -Fq 'HELIX_HEVC10_PROBE_SUMMARY stream=0' "$EVIDENCE/quest-logcat.txt" &&
     grep -Fq 'HELIX_HEVC10_PROBE_SUMMARY stream=1' "$EVIDENCE/quest-logcat.txt"; then break; fi
  sleep .1
done
adb -s "$SERIAL" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true
sleep .5
kill "$LOGCAT_PID" >/dev/null 2>&1 || true
wait "$LOGCAT_PID" >/dev/null 2>&1 || true
LOGCAT_PID=""

echo '[6/8] Reducing exact per-eye transport-to-decoder evidence'
set +e
python3 - "$SERVER_LOG" "$EVIDENCE/quest-logcat.txt" "$EVIDENCE/result.txt" <<'PY'
from pathlib import Path
import re,sys
s=Path(sys.argv[1]).read_text(errors='replace')
q=Path(sys.argv[2]).read_text(errors='replace')
out=Path(sys.argv[3])

def parse(line):
    return {k:v for k,v in re.findall(r'([A-Za-z_]+)=([^\s]+)',line)}
def tagged(text,tag):
    return [parse(x) for x in text.splitlines() if tag in x]
def by_stream(rows):
    d={}
    for x in rows:
        if x.get('stream') in ('0','1'): d.setdefault(x['stream'],[]).append(x)
    return d

err=[]
drops=by_stream(tagged(s,'HELIX_HEVC10_DROP '))
rtx=by_stream(tagged(s,'HELIX_HEVC10_RTX_SENT '))
faultsum=by_stream(tagged(s,'HELIX_HEVC10_FAULT_SUMMARY '))
assembled=by_stream(tagged(q,'HELIX_HEVC10_RTX_ASSEMBLED '))
media=by_stream(tagged(q,'HELIX_HEVC10_RTX_MEDIA_OUTPUT '))
images=by_stream(tagged(q,'HELIX_HEVC10_IMAGE_AFTER_RTX '))
probes=by_stream(tagged(q,'HELIX_HEVC10_PROBE_SUMMARY '))
expected={'0':'600','1':'900'}
report=[]
for stream,ordinal in expected.items():
    ds=drops.get(stream,[])
    if len(ds)!=1:
        err.append(f'stream{stream}:drop_count={len(ds)}'); continue
    d=ds[0]
    if d.get('ordinal')!=ordinal or d.get('shard')!='0' or d.get('cached')!='1': err.append(f'stream{stream}:bad_drop_contract')
    frame=d.get('frame'); seq=d.get('packet_sequence')
    if not frame or not seq: err.append(f'stream{stream}:drop_identity_missing'); continue
    rs=[x for x in rtx.get(stream,[]) if x.get('frame')==frame and x.get('packet_sequence')==seq and x.get('exact_canary')=='1']
    if len(rs)!=1: err.append(f'stream{stream}:exact_rtx_match={len(rs)}')
    aa=[x for x in assembled.get(stream,[]) if x.get('frame')==frame]
    if len(aa)<1: err.append(f'stream{stream}:rtx_not_assembled')
    mm=[x for x in media.get(stream,[]) if x.get('frame')==frame and x.get('exact_recovered_frame')=='1']
    if len(mm)<1: err.append(f'stream{stream}:exact_mediacodec_output_missing')
    ii=[]
    for x in images.get(stream,[]):
        if x.get('recovered_frame')!=frame: continue
        try: ok=int(x.get('image_frame','-1')) >= int(frame)
        except ValueError: ok=False
        if ok: ii.append(x)
    if len(ii)<1: err.append(f'stream{stream}:aimage_after_recovered_frame_missing')
    fs=faultsum.get(stream,[])
    if len(fs)!=1 or fs[0].get('target_ordinal')!=ordinal or fs[0].get('injected')!='1' or fs[0].get('exact_rtx_sent')!='1' or fs[0].get('pending_sequence')!='no':
        err.append(f'stream{stream}:fault_summary_bad')
    ps=probes.get(stream,[])
    if len(ps)!=1:
        err.append(f'stream{stream}:probe_summary_count={len(ps)}')
    else:
        p=ps[0]
        if p.get('overflow')!='0': err.append(f'stream{stream}:probe_overflow={p.get("overflow")}')
        for key in ('rtx_assembled','media_exact','image_after'):
            try: nonzero=int(p.get(key,'0')) >= 1
            except ValueError: nonzero=False
            if not nonzero: err.append(f'stream{stream}:probe_{key}_zero')
    report.append(f'stream={stream} ordinal={ordinal} frame={frame} packet_sequence={seq} exact_rtx={len(rs)} assembled={len(aa)} media_exact={len(mm)} image_after={len(ii)}')

if re.search(r'Fatal signal|SIGABRT|Assertion.*failed|FATAL EXCEPTION|ANR in org\.meumeu\.wivrn',q,re.I): err.append('quest_crash_marker')
if 'HELIX_HEVC10_RECOVERY requires NVENC H.265 Main10 on both eye streams' in s: err.append('encoder_hard_gate_exception')
verdict='PASS' if not err else 'FAIL'
text='\n'.join([
    f'verdict={verdict}',
    *report,
    'errors=' + (','.join(err) if err else 'none'),
    'decoder_recovery=ESTABLISHED exact-rtx-to-mediacodec-to-aimage-per-eye' if not err else 'decoder_recovery=NOT_ESTABLISHED',
    'pixel_cleanliness=NOT_ESTABLISHED',
])+'\n'
out.write_text(text); print(text,end='')
raise SystemExit(0 if verdict=='PASS' else 1)
PY
REDUCE_STATUS=$?
set -e

echo '[7/8] Final HEVC10 decoder-recovery verdict'
cat "$EVIDENCE/result.txt"
if [[ "$REDUCE_STATUS" -ne 0 ]]; then
  echo 'RUNTIME=FAIL'
  echo 'DECODER_RECOVERY=NOT_ESTABLISHED'
  echo 'PIXEL_CLEANLINESS=NOT_ESTABLISHED'
  echo "evidence=$EVIDENCE"
  exit 1
fi

echo '[8/8] PASS'
echo 'RUNTIME=PASS hevc10-both-eye-exact-rtx-mediacodec-aimage-recovery'
echo 'DECODER_RECOVERY=ESTABLISHED exact-frame-correlation-per-eye'
echo 'PIXEL_CLEANLINESS=NOT_ESTABLISHED'
echo 'TRANSPORT=LAN-only-no-adb-forward-reverse'
echo "evidence=$EVIDENCE"
