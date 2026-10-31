#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="709fa5f71c07c596a68ed4dfa7f3f38f65816c9b"
BUILD_TOOLING_COMMIT="0960d6451b1c903a7a3bc8c673cd9b42963b69a8"
SEAL_TOOLING_COMMIT="ee8aead20c57f259803ea779335546fd37a4e5ed"
AUDIT_TOOLING_COMMIT="94a0b125b01e6655e84e639c62aedc3d61b7fc39"
ROOT="$HOME/helix-vrchat-representative-runtime-v1"
META="$ROOT/metadata.txt"
SEAL="$ROOT/runtime-v1-seal.txt"
TRACE_ROOT="$HOME/helix-vrchat-representative-torture-v1"
TRACE="$TRACE_ROOT/vrchat-torture-300s-seed20261031.trace"
TRACE_META="$TRACE_ROOT/vrchat-representative-trace-v4-metadata.txt"
SERVER="$ROOT/wivrn-server-representative-v1"
APK="$ROOT/helix-vrchat-representative-${SOURCE_COMMIT:0:12}.apk"
SERVER_SHA256="e31820d0e4433b5ef35a0e251d328a082802001de33b3a96c5c2d704d1c57498"
APK_SHA256="5777f2d86db1bcc701215b3adef83f61bc7542eec9c4f9f78ef63ddd5e4a2b22"
TRACE_SHA256="9c233a73d119109a141f9ce961b93725e7b93700f45f19071bf4f57c54f57138"
TRACE_META_SHA256="dd36e22d4284a495c66d1ab4a250e63cdb37abd6e4dd578ac71a3e91042eb232"
RUNTIME_META_SHA256="2f20cef41d4b588c76ab6856a727fedf5e703d76f4be04131ac21114a24f1bc9"
PACKAGE="org.meumeu.wivrn.local"
ACTIVITY="org.meumeu.wivrn.MainActivity"
TIMEOUT_SECONDS=420

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git adb sha256sum awk sed grep ip python3 timeout stdbuf systemctl pkill seq; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done

for h in "$SERVER_SHA256" "$APK_SHA256" "$TRACE_SHA256" "$TRACE_META_SHA256" "$RUNTIME_META_SHA256"; do
    [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid lowercase sha256 binding: $h"
done
[[ -s "$META" && -s "$SEAL" ]] || fail "runtime metadata/seal missing"
[[ -s "$SERVER" && -x "$SERVER" ]] || fail "server missing/not executable"
[[ -s "$APK" ]] || fail "APK missing"
[[ -s "$TRACE" && -s "$TRACE_META" ]] || fail "representative trace artifacts missing"
[[ "$(sha256sum "$SERVER"|awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK"|awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$TRACE"|awk '{print $1}')" == "$TRACE_SHA256" ]] || fail "trace hash mismatch"
[[ "$(sha256sum "$TRACE_META"|awk '{print $1}')" == "$TRACE_META_SHA256" ]] || fail "trace metadata hash mismatch"
[[ "$(sha256sum "$META"|awk '{print $1}')" == "$RUNTIME_META_SHA256" ]] || fail "runtime metadata hash mismatch"

grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$META" || fail "metadata server hash mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$META" || fail "metadata APK hash mismatch"
grep -Fqx "trace_sha256=$TRACE_SHA256" "$META" || fail "metadata trace hash mismatch"
grep -Fqx "trace_metadata_sha256=$TRACE_META_SHA256" "$META" || fail "metadata trace metadata hash mismatch"
grep -Fqx 'artifact_gate=PASS representative-v1-exact-source-server-apk-trace-bound' "$META" || fail "build artifact gate missing"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "seal source mismatch"
grep -Fqx "build_tooling_commit=$BUILD_TOOLING_COMMIT" "$SEAL" || fail "seal build tooling mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$SEAL" || fail "seal server hash mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$SEAL" || fail "seal APK hash mismatch"
grep -Fqx "trace_sha256=$TRACE_SHA256" "$SEAL" || fail "seal trace hash mismatch"
grep -Fqx "trace_metadata_sha256=$TRACE_META_SHA256" "$SEAL" || fail "seal trace metadata mismatch"
grep -Fqx "runtime_metadata_sha256=$RUNTIME_META_SHA256" "$SEAL" || fail "seal runtime metadata mismatch"
grep -Fqx 'artifact_seal=PASS vrchat-representative-runtime-v1-exact-source-server-apk-trace-v4-bound' "$SEAL" || fail "runtime seal marker mismatch"
grep -Fqx 'runtime_status=NOT_RUN' "$SEAL" || fail "runtime seal status is not frozen NOT_RUN"

# Re-audit the exact local source checkpoint rather than trusting a mutable branch.
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
git cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null || fail "exact source commit unavailable locally"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'HELIX_SYNTHETIC_TRACE' || fail "representative trace selector absent"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'rtx_canary_candidates == 2' || fail "two-canary candidate gate absent"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'rtx_canary_recovered == 2' || fail "two-canary recovery gate absent"
git show "$SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'payload_would_clamp' || fail "payload clamp gate absent"
git show "$SOURCE_COMMIT:server/main.cpp" | grep -Fq -- '--helix-synthetic-transport' || fail "synthetic CLI absent"

echo 'RUNTIME_PREFLIGHT_ARTIFACT=PASS exact-source-server-apk-trace-v4-sealed'

adb get-state >/dev/null 2>&1 || fail "Quest not visible to adb"
serial="$(adb get-serialno | tr -d '\r')"
[[ -n "$serial" && "$serial" != unknown ]] || fail "ADB serial unavailable"

forward_out="$(adb -s "$serial" forward --list 2>/dev/null || true)"
reverse_out="$(adb -s "$serial" reverse --list 2>/dev/null || true)"
[[ -z "$forward_out" ]] || fail "ADB forward exists; refusing ambiguous transport path: $forward_out"
[[ -z "$reverse_out" ]] || fail "ADB reverse exists; refusing ambiguous transport path: $reverse_out"

quest_ip="$(adb -s "$serial" shell ip -4 addr show wlan0 2>/dev/null | awk '/inet / && !found {sub(/\/.*/,"",$2); value=$2; found=1} END {if(found) print value}' | tr -d '\r')"
[[ -n "$quest_ip" ]] || fail "Quest wlan0 IPv4 address unavailable"
route="$(ip -4 route get "$quest_ip" 2>/dev/null | head -1)"
[[ -n "$route" ]] || fail "host has no route to Quest wlan0 address $quest_ip"
echo "$route" | grep -Eq ' dev (lo|usb[^ ]*|rndis[^ ]*|adb[^ ]*) ' && fail "route to Quest is not accepted LAN/Wi-Fi path: $route"
host_ip="$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"
[[ -n "$host_ip" ]] || fail "host route source missing"
echo "NETWORK_PATH_GATE=PASS quest_wlan0=$quest_ip host_route=$route host_ip=$host_ip adb_forward=none adb_reverse=none"

VERSION_NAME="$(sed -n 's/^version_name=//p' "$META" | tail -1)"
[[ -n "$VERSION_NAME" ]] || fail "metadata version_name missing"
echo "Installing exact Quest APK version=$VERSION_NAME"
adb -s "$serial" install -r -d "$APK" >/dev/null || fail "APK install failed"
package_dump="$(adb -s "$serial" shell dumpsys package "$PACKAGE" 2>/dev/null | tr -d '\r')"
printf '%s\n' "$package_dump" | grep -Fq "versionName=$VERSION_NAME" || fail "installed versionName mismatch"

evidence="$HOME/helix-vrchat-representative-runtime-evidence-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$evidence"
printf '%s\n' "$package_dump" > "$evidence/package.txt"
printf 'source_commit=%s\nbuild_tooling_commit=%s\nseal_tooling_commit=%s\naudit_tooling_commit=%s\nserver_sha256=%s\napk_sha256=%s\ntrace_sha256=%s\ntrace_metadata_sha256=%s\nruntime_metadata_sha256=%s\npackage=%s\nversion=%s\nquest_wlan0=%s\nhost_ip=%s\nhost_route=%s\ntransport=explicit-wivrn-tcp-over-wlan-no-adb-forward-reverse\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$SEAL_TOOLING_COMMIT" "$AUDIT_TOOLING_COMMIT" "$SERVER_SHA256" "$APK_SHA256" "$TRACE_SHA256" "$TRACE_META_SHA256" "$RUNTIME_META_SHA256" "$PACKAGE" "$VERSION_NAME" "$quest_ip" "$host_ip" "$route" > "$evidence/metadata.txt"

service_was_active=0
systemctl --user is-active --quiet wivrn.service && service_was_active=1 || true
cleanup(){
    set +e
    [[ -n "${server_pid:-}" ]] && kill "$server_pid" 2>/dev/null
    adb -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1
    if (( service_was_active )); then systemctl --user start wivrn.service >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT INT TERM

systemctl --user stop wivrn.service >/dev/null 2>&1 || true
pkill -x wivrn-server >/dev/null 2>&1 || true
sleep 1
adb -s "$serial" logcat -c >/dev/null 2>&1 || true
adb -s "$serial" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
adb -s "$serial" shell am force-stop "$PACKAGE" >/dev/null 2>&1 || true

# The environment variable selects the sealed representative trace path. The CLI
# still selects the synthetic receiver mode. USB/ADB is used only for install,
# launch and evidence; streaming is forced to the explicit LAN host URI.
HELIX_SYNTHETIC_TRACE="$TRACE" stdbuf -oL -eL "$SERVER" --helix-synthetic-transport --no-fork --no-publish-service > "$evidence/server-log.txt" 2>&1 &
server_pid=$!
sleep 2
kill -0 "$server_pid" 2>/dev/null || { cat "$evidence/server-log.txt" >&2; fail "server exited before Quest launch"; }

adb -s "$serial" shell am start -W -a android.intent.action.VIEW -d "wivrn+tcp://${host_ip}" -n "$PACKAGE/$ACTIVITY" > "$evidence/launch.txt" 2>&1 || fail "Quest launch failed"

connected=0
for _ in $(seq 1 300); do
    kill -0 "$server_pid" 2>/dev/null || fail "server exited before trusted Quest connection"
    grep -Fq 'To pair a new headset use PIN code:' "$evidence/server-log.txt" && fail "server entered pairing mode; existing trust state unavailable"
    if grep -Fq 'Client connected' "$evidence/server-log.txt"; then connected=1; break; fi
    sleep .1
done
[[ "$connected" -eq 1 ]] || fail "Quest did not establish trusted LAN connection"
echo 'NETWORK_TRUSTED_CONNECTION=PASS explicit-wivrn-tcp-uri'

set +e
timeout "$TIMEOUT_SECONDS" bash -c '
  log="$1"; pid="$2"
  while kill -0 "$pid" 2>/dev/null; do
    if grep -Fq "HELIX_SYNTHETIC_TRANSPORT_EXIT" "$log"; then exit 0; fi
    sleep 1
  done
  grep -Fq "HELIX_SYNTHETIC_TRANSPORT_EXIT" "$log"
' _ "$evidence/server-log.txt" "$server_pid"
wait_status=$?
set -e

adb -s "$serial" logcat -d > "$evidence/logcat.txt" 2>/dev/null || true
[[ $wait_status -eq 0 ]] || { tail -250 "$evidence/server-log.txt" >&2; fail "representative runtime timed out/exited without completion"; }

exit_line="$(grep 'HELIX_SYNTHETIC_TRANSPORT_EXIT' "$evidence/server-log.txt" | tail -1 || true)"
[[ -n "$exit_line" ]] || fail "synthetic exit marker missing"
echo "$exit_line" | grep -Fq 'result=0' || fail "representative runner exited nonzero: $exit_line"

# Do not infer a PASS merely from process exit. The representative source itself
# gates these fields; require their emitted runtime evidence as an independent check.
python3 - "$evidence/server-log.txt" <<'PY'
import re, sys
p=sys.argv[1]
text=open(p, errors='replace').read()

def latest_int(name):
    vals=re.findall(r'\b'+re.escape(name)+r'=([0-9]+)\b', text)
    if not vals:
        raise SystemExit(f'FAIL: representative runtime field missing: {name}')
    return int(vals[-1])

candidates=latest_int('rtx_canary_candidates')
recovered=latest_int('rtx_canary_recovered')
clamp=latest_int('payload_would_clamp')
if candidates != 2:
    raise SystemExit(f'FAIL: rtx_canary_candidates={candidates} expected=2')
if recovered != 2:
    raise SystemExit(f'FAIL: rtx_canary_recovered={recovered} expected=2')
if clamp != 0:
    raise SystemExit(f'FAIL: payload_would_clamp={clamp} expected=0')

# Prefer explicit pass/runtime fields when emitted, but never manufacture them.
pass_fields=re.findall(r'\bpass=([01])\b', text)
if pass_fields and pass_fields[-1] != '1':
    raise SystemExit(f'FAIL: final emitted pass={pass_fields[-1]}')
print(f'REPRESENTATIVE_RUNTIME_CONTRACT=PASS rtx_canary_candidates={candidates} rtx_canary_recovered={recovered} payload_would_clamp={clamp}')
PY

# Preserve the exact terminal summary for later Rule-40 classification.
grep -E 'HELIX_|rtx_canary_|payload_would_clamp|trace_' "$evidence/server-log.txt" | tail -120 > "$evidence/representative-summary.txt" || true
printf '%s\n' "$exit_line"
echo "EVIDENCE=$evidence"
echo 'verdict=QUEST_VRCHAT_REPRESENTATIVE_TRANSPORT_PASS'
