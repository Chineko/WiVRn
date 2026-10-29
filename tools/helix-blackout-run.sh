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

for cmd in adb awk bash git grep mktemp pgrep pkill python3 rm sleep strings timeout tr; do
    need "$cmd"
done

cd "$ROOT"

# First audit gate: validate the concrete tooling artifacts before touching runtime state.
bash -n "$CAPTURE" || fail "capture harness failed Bash syntax check"
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
APK_PATH=$(adb shell pm path "$PACKAGE" 2>/dev/null | tr -d '\r' | awk -F: '/base\.apk$/{print $2; exit}')
[[ -n "$APK_PATH" ]] || fail "could not locate installed base APK for $PACKAGE"
APK_TMP=$(mktemp --suffix=.apk)
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

# Do not reuse an unknown in-memory dashboard/server process. The capture harness
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

echo "Helix preflight passed: tooling syntax and matching desktop/Quest runtime identity are verified."
exec bash "$CAPTURE"
