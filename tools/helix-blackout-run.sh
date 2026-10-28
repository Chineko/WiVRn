#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
RUNTIME_BASE=${HELIX_RUNTIME_BASE:-ffdc6bb74a4cfafc1a03774f6e2413acfba9c60a}
RUNTIME_SHORT=${RUNTIME_BASE:0:8}
PACKAGE=org.meumeu.wivrn.local
CAPTURE="$ROOT/tools/helix-blackout-capture.sh"
REDUCER="$ROOT/tools/helix-blackout-reduce.py"

fail() {
    echo "Helix preflight: $*" >&2
    exit 1
}

need() {
    command -v "$1" >/dev/null 2>&1 || fail "missing required host command: $1"
}

for cmd in adb awk bash cut git grep ip mktemp ping pgrep pkill python3 rm sleep strings tcpdump timeout tr; do
    need "$cmd"
done

cd "$ROOT"

# Validate the tooling itself before touching the runtime session.
bash -n "$CAPTURE" || fail "capture harness failed bash syntax check"
python3 -c 'from pathlib import Path; p=Path("tools/helix-blackout-reduce.py"); compile(p.read_text(), str(p), "exec")' \
    || fail "capture reducer failed Python syntax check"

git cat-file -e "$RUNTIME_BASE^{commit}" 2>/dev/null || fail "runtime base $RUNTIME_BASE is not available locally"
if ! git diff --quiet "$RUNTIME_BASE" -- . ':(exclude)docs/**' ':(exclude)tools/**'; then
    fail "runtime source differs from validated base $RUNTIME_BASE"
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "tracked working-tree changes are present"
fi

DASHBOARD="$ROOT/build-dashboard/server/wivrn-dashboard"
SERVER="$ROOT/build-dashboard/server/wivrn-server"
[[ -x "$DASHBOARD" ]] || fail "missing executable dashboard build: $DASHBOARD"
[[ -x "$SERVER" ]] || fail "missing executable server build: $SERVER"
strings "$SERVER" | grep -F "$RUNTIME_SHORT" >/dev/null \
    || fail "desktop server binary does not contain validated runtime id $RUNTIME_SHORT; rebuild the validated runtime before VR"

ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || fail "Quest root shell is not active"

# Verify the actual installed APK/native runtime, not Android package versionName.
# WiVRn's Gradle versionName can legitimately remain 1.0 while the native binary
# embeds the git-derived runtime identity used in logcat.
APK_PATH=$(adb shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | awk -F: '/base\.apk$/{print $2; exit}')
[[ -n "$APK_PATH" ]] || fail "could not locate installed base APK for $PACKAGE"
APK_TMP=$(mktemp --suffix=.apk)
trap 'rm -f "$APK_TMP"' RETURN
if ! timeout 45s adb exec-out su -c "cat '$APK_PATH'" >"$APK_TMP"; then
    rm -f "$APK_TMP"
    fail "could not read installed APK for native runtime verification"
fi
if ! python3 - "$APK_TMP" "$RUNTIME_SHORT" <<'PY'
import sys, zipfile
apk, expected = sys.argv[1], sys.argv[2].encode()
try:
    with zipfile.ZipFile(apk) as z:
        libs = [n for n in z.namelist() if n.endswith('.so')]
        if not libs:
            raise SystemExit(2)
        if not any(expected in z.read(name) for name in libs):
            raise SystemExit(3)
except zipfile.BadZipFile:
    raise SystemExit(4)
PY
then
    rm -f "$APK_TMP"
    fail "installed Quest native libraries do not contain validated runtime id $RUNTIME_SHORT"
fi
rm -f "$APK_TMP"
trap - RETURN

# Do not reuse an unknown in-memory dashboard/server process. The audited harness
# will launch the verified dashboard binary itself.
if pgrep -f 'build-dashboard/server/wivrn-dashboard' >/dev/null 2>&1; then
    echo "Helix preflight: stopping existing dashboard so runtime identity is deterministic"
    pkill -f 'build-dashboard/server/wivrn-dashboard' || true
    sleep 1
fi
if pgrep -f 'build-dashboard/server/wivrn-server' >/dev/null 2>&1; then
    echo "Helix preflight: stopping existing server so runtime identity is deterministic"
    pkill -f 'build-dashboard/server/wivrn-server' || true
    sleep 1
fi

QUEST_ROUTE=$(adb shell su -c 'ip route show default 2>/dev/null | head -n1' | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell su -c "ip -4 -o addr show dev $QUEST_IF scope global 2>/dev/null | head -n1" \
    | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || fail "could not determine Quest IPv4 address"
HOST_IP=$(ip route get "$QUEST_IP" | head -n1 \
    | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
[[ -n "$HOST_IP" ]] || fail "could not determine host IPv4 address toward Quest"
QUEST_TCPDUMP=$(adb shell su -c 'command -v tcpdump 2>/dev/null || which tcpdump 2>/dev/null' \
    | tr -d '\r' | tail -n1)
[[ -n "$QUEST_TCPDUMP" ]] || fail "Quest tcpdump is unavailable"

# Verify the exact root-created-PCAP -> ordinary adb pull path before VR.
REMOTE_TEST=/data/local/tmp/helix-pull-preflight.pcap
LOCAL_TEST=$(mktemp --suffix=.pcap)
rm -f "$LOCAL_TEST"
adb shell su -c "rm -f $REMOTE_TEST" >/dev/null 2>&1 || true
timeout 8s adb shell su -c "$QUEST_TCPDUMP -Z root -i $QUEST_IF -s 96 -c 1 -w $REMOTE_TEST 'icmp and host $HOST_IP'" \
    >/dev/null 2>&1 &
PRE_PID=$!
sleep 0.5
ping -c 1 -W 1 "$QUEST_IP" >/dev/null 2>&1 || true
wait "$PRE_PID" || fail "Quest one-packet pull preflight capture failed"
adb pull "$REMOTE_TEST" "$LOCAL_TEST" >/dev/null 2>&1 \
    || fail "ordinary adb pull cannot read the root-created Quest PCAP"
tcpdump -nn -r "$LOCAL_TEST" -c 1 >/dev/null 2>&1 \
    || fail "pulled Quest preflight PCAP is unreadable"
rm -f "$LOCAL_TEST"
adb shell su -c "rm -f $REMOTE_TEST" >/dev/null 2>&1 || true

echo "Helix preflight passed: runtime identity, rooted capture, pull path, and tooling are verified."
exec bash "$CAPTURE"