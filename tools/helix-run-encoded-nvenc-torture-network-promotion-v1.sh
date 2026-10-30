#!/usr/bin/env bash
set -euo pipefail

PINNED_ENCODED_LAUNCHER_COMMIT="70c992215fdb512ec1389194f0199eb97c4b5ba1"
PINNED_ENCODED_LAUNCHER_PATH="tools/helix-run-encoded-nvenc-torture-fix-v3-strict-audited.sh"
PINNED_DIRECT_RUNNER_COMMIT="8c656f35e62fa4738230a8f99e942740b645122b"
PINNED_DIRECT_RUNNER_PATH="tools/helix-run-encoded-nvenc-torture.sh"

SOURCE_COMMIT="6e23563ec49c6ab8a5e76860b2497b5722c3f591"
SOURCE_BRANCH="helix-synthetic-network-promotion-v1-built"
BUILD_ROOT="$HOME/helix-synthetic-network-promotion-v1-build-20261030-195536"
META="$BUILD_ROOT/metadata.txt"
SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"
MANIFEST="$BUILD_ROOT/worktree/build-everything/openxr_wivrn-dev.json"
APK="$BUILD_ROOT/helix-synthetic-network-promotion-v1-6e23563ec49c.apk"
SERVER_SHA256="5ae4f34dec55b4ae0626bff20222bb81c65ebb2c3728bb69a72be227e4acb04e"
APK_SHA256="cdff41578fc307077b4d3ad05a90233dadec9146e5c8bb87243b4d83021abc76"
VERSION_NAME="helix-synthetic-network-promotion-v1-6e23563ec49c6ab8a5e76860b2497b5722c3f591"
ARTIFACT_GATE="artifact_gate=PASS synthetic-network-promotion-v1-server-apk-exact-source"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git adb sha256sum awk grep ip python3 bash tr head cp mktemp; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done

# Artifact/provenance gate before any headset runtime action.
for f in "$META" "$SERVER" "$MANIFEST" "$APK"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ -x "$SERVER" ]] || fail "server is not executable"
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
grep -Fqx "source_base=951ce95cd2ea14bf34e099d2b7e56f272d05cdac" "$META" || fail "metadata source base mismatch"
grep -Fqx "transform_commit=9299588c3080ed06d54ee39bc9b1e9d45b6bc638" "$META" || fail "metadata transform mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"
grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "metadata remote head mismatch"
grep -Fqx "version_name=$VERSION_NAME" "$META" || fail "metadata version mismatch"
grep -Fqx "server=$SERVER" "$META" || fail "metadata server path mismatch"
grep -Fqx "openxr_manifest=$MANIFEST" "$META" || fail "metadata manifest path mismatch"
grep -Fqx "apk=$APK" "$META" || fail "metadata APK path mismatch"
grep -Fqx 'server_provenance=PASS exact-patched-commit-direct-link' "$META" || fail "server provenance marker missing"
grep -Fqx "$ARTIFACT_GATE" "$META" || fail "artifact gate missing"

git fetch -q origin "$SOURCE_BRANCH"
[[ "$(git rev-parse "refs/remotes/origin/$SOURCE_BRANCH")" == "$SOURCE_COMMIT" ]] || fail "promotion source branch moved"

# Source semantics gate: encoded torture semantics must still be present on promotion source.
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'helix_force_torture_fragmentation' || fail "encoded fragmentation fix missing"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3' || fail "encoded fresh recovery semantic missing"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" | grep -Fq 'HELIX_ENCODED_TORTURE_SUMMARY' || fail "encoded torture summary missing"

# Network path proof. ADB is control-plane only; refuse any adb tunnel and USB/RNDIS route.
adb get-state >/dev/null 2>&1 || fail "Quest not visible to adb"
SERIAL="$(adb get-serialno | tr -d '\r')"
[[ -n "$SERIAL" && "$SERIAL" != unknown ]] || fail "ADB serial unavailable"
FORWARD_OUT="$(adb forward --list 2>/dev/null || true)"
REVERSE_OUT="$(adb reverse --list 2>/dev/null || true)"
[[ -z "$FORWARD_OUT" ]] || fail "ADB forward exists; refusing ambiguous transport path: $FORWARD_OUT"
[[ -z "$REVERSE_OUT" ]] || fail "ADB reverse exists; refusing ambiguous transport path: $REVERSE_OUT"
QUEST_IP="$(adb -s "$SERIAL" shell ip -4 addr show wlan0 2>/dev/null | awk '/inet / && !found {sub(/\/.*/,"",$2); value=$2; found=1} END {if(found) print value}' | tr -d '\r')"
[[ -n "$QUEST_IP" ]] || fail "Quest wlan0 IPv4 address unavailable"
ROUTE="$(ip -4 route get "$QUEST_IP" 2>/dev/null | head -1)"
[[ -n "$ROUTE" ]] || fail "host has no route to Quest wlan0 address $QUEST_IP"
echo "$ROUTE" | grep -Eq ' dev (lo|usb[^ ]*|rndis[^ ]*|adb[^ ]*) ' && fail "route to Quest is not accepted network path: $ROUTE"
HOST_IP="$(printf '%s\n' "$ROUTE" | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){value=$(i+1); found=1}} END {if(found) print value}')"
[[ -n "$HOST_IP" ]] || fail "host route source missing"
echo "ENCODED_NETWORK_PATH_GATE=PASS quest_wlan0=$QUEST_IP host_route=$ROUTE host_ip=$HOST_IP adb_forward=none adb_reverse=none"

# Audit the pinned encoded runner's actual transport contract before composing it.
git cat-file -e "${PINNED_DIRECT_RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_DIRECT_RUNNER_COMMIT"
DIRECT="$(mktemp)"
PATCHED="$(mktemp)"
ORIG="$(mktemp)"
trap 'rm -f "$DIRECT" "$PATCHED" "$ORIG"' EXIT INT TERM
git show "${PINNED_DIRECT_RUNNER_COMMIT}:${PINNED_DIRECT_RUNNER_PATH}" >"$DIRECT"
grep -Fq 'shell ip -4 addr show wlan0' "$DIRECT" || fail "encoded runner does not derive Quest wlan0 address"
grep -Fq 'ip -4 route get "$QUEST_IP"' "$DIRECT" || fail "encoded runner does not derive host route to Quest"
grep -Fq 'wivrn+tcp://${HOST_IP}' "$DIRECT" || fail "encoded runner does not launch explicit LAN URI"
grep -Fq 'export HELIX_ENCODED_TORTURE=1' "$DIRECT" || fail "encoded torture enable missing"

# Compose by changing only contextual artifact-identity anchors in the exact previously-passing v3 launcher.
git cat-file -e "${PINNED_ENCODED_LAUNCHER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_ENCODED_LAUNCHER_COMMIT"
git show "${PINNED_ENCODED_LAUNCHER_COMMIT}:${PINNED_ENCODED_LAUNCHER_PATH}" >"$ORIG"
cp "$ORIG" "$PATCHED"
python3 - "$PATCHED" "$ORIG" "$SOURCE_COMMIT" "$BUILD_ROOT" "$SERVER_SHA256" "$APK_SHA256" "$VERSION_NAME" "$ARTIFACT_GATE" <<'PY'
from pathlib import Path
import sys
patched=Path(sys.argv[1]); orig=Path(sys.argv[2]).read_text()
source,build_root,server_sha,apk_sha,version,gate=sys.argv[3:]
s=patched.read_text()
repls=[
('\'SOURCE_COMMIT="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"\',', f'\'SOURCE_COMMIT="{source}"\','),
('\'BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v3-build-20261030-185452"\',', f'\'BUILD_ROOT="{build_root}"\','),
('\'APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v3-951ce95cd2ea.apk"\',', '\'APK="$BUILD_ROOT/helix-synthetic-network-promotion-v1-6e23563ec49c.apk"\','),
('\'SERVER_SHA256="1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af"\',', f'\'SERVER_SHA256="{server_sha}"\','),
('\'APK_SHA256="1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c"\',', f'\'APK_SHA256="{apk_sha}"\','),
('\'VERSION_NAME="helix-encoded-fix-v3-951ce95cd2ea14bf34e099d2b7e56f272d05cdac"\',', f'\'VERSION_NAME="{version}"\','),
("new_gate='artifact_gate=PASS encoded-nvenc-fix-v3-server-apk-exact-source'", f"new_gate={gate!r}"),
("grep -Fq '951ce95cd2ea14bf34e099d2b7e56f272d05cdac' \"$tmp\" || { echo \"FAIL: v3 source binding missing\" >&2; exit 2; }", f"grep -Fq '{source}' \"$tmp\" || {{ echo \"FAIL: promotion source binding missing\" >&2; exit 2; }}"),
("grep -Fq '1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af' \"$tmp\" || { echo \"FAIL: v3 server hash binding missing\" >&2; exit 2; }", f"grep -Fq '{server_sha}' \"$tmp\" || {{ echo \"FAIL: promotion server hash binding missing\" >&2; exit 2; }}"),
("grep -Fq '1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c' \"$tmp\" || { echo \"FAIL: v3 APK hash binding missing\" >&2; exit 2; }", f"grep -Fq '{apk_sha}' \"$tmp\" || {{ echo \"FAIL: promotion APK hash binding missing\" >&2; exit 2; }}"),
]
for old,new in repls:
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: contextual identity anchor count={n}: {old}')
    s=s.replace(old,new,1)
patched.write_text(s)
normalized=s
for old,new in reversed(repls):
    n=normalized.count(new)
    if n != 1:
        raise SystemExit(f'FAIL: normalization anchor count={n}: {new}')
    normalized=normalized.replace(new,old,1)
if normalized != orig:
    raise SystemExit('FAIL: patched encoded launcher differs beyond approved contextual identity substitutions')
print('ENCODED_NETWORK_COMPOSITION_AUDIT=PASS byte-identical-after-contextual-identity-normalization')
PY

bash -n "$PATCHED"
grep -Fq "$SOURCE_COMMIT" "$PATCHED" || fail "promotion source binding missing"
grep -Fq "$SERVER_SHA256" "$PATCHED" || fail "promotion server hash binding missing"
grep -Fq "$APK_SHA256" "$PATCHED" || fail "promotion APK hash binding missing"
grep -Fq "$VERSION_NAME" "$PATCHED" || fail "promotion version binding missing"
grep -Fq "$ARTIFACT_GATE" "$PATCHED" || fail "promotion artifact gate binding missing"

echo 'ENCODED_NETWORK_PROMOTION_PREFLIGHT=PASS exact-promotion-artifacts proven-v3-encoded-runner explicit-lan-path'
exec bash "$PATCHED"
