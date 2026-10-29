#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
BASE_RUN="$ROOT/tools/helix-blackout-run.sh"
BASE_CAPTURE="$ROOT/tools/helix-blackout-capture.sh"
[[ -f "$BASE_RUN" ]] || { echo "missing $BASE_RUN" >&2; exit 1; }
[[ -f "$BASE_CAPTURE" ]] || { echo "missing $BASE_CAPTURE" >&2; exit 1; }

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/helix-blackout-usb-detached.XXXXXX")
TMP_RUN="$TMP_DIR/helix-blackout-run.sh"
TMP_CAPTURE="$TMP_DIR/helix-blackout-capture.sh"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT INT TERM

python3 - "$BASE_RUN" "$BASE_CAPTURE" "$TMP_RUN" "$TMP_CAPTURE" <<'PY'
from pathlib import Path
import sys

run_src, capture_src, run_out, capture_out = map(Path, sys.argv[1:])
run = run_src.read_text()
capture = capture_src.read_text()


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match, found {count}: {old[:100]!r}")
    return text.replace(old, new, 1)

capture = replace_once(
    capture,
    '''ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\\r' || true)
''',
    '''ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || fail "expected exactly one connected ADB device, found $ADB_COUNT"
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
[[ "$ADB_SERIAL" != *:* ]] || fail "wireless ADB would share the path under test; connect the Quest over USB and disconnect wireless ADB"
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\\r' || true)
''',
    "USB preflight",
)

capture = replace_once(
    capture,
    '''    echo "attribution_scope=host_capture_to_quest_wlan"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
''',
    '''    echo "attribution_scope=host_capture_to_quest_wlan"
    echo "adb_transport=usb_setup_and_retrieval_only"
    echo "usb_detached_during_workload=true"
    echo "branch=$(git -C "$ROOT" branch --show-current)"
''',
    "metadata transport identity",
)

capture = replace_once(
    capture,
    '''CAPTURE_START_EPOCH_NS=$(date +%s%N)
echo "capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS" >>"$OUT/metadata.txt"
echo "capture_started_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

adb shell "su -c 'rm -f $QUEST_TMP.pcap $QUEST_TMP.tcpdump.pid $QUEST_TMP.tcpdump.err'" >/dev/null 2>&1 || true
''',
    '''adb shell "su -c 'rm -f $QUEST_TMP.pcap $QUEST_TMP.tcpdump.pid $QUEST_TMP.tcpdump.err'" >/dev/null 2>&1 || true
''',
    "defer capture start timestamp",
)

capture = replace_once(
    capture,
    '''adb shell "su -c '$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- \\"$FILTER\\" >/dev/null 2>$QUEST_TMP.tcpdump.err </dev/null & echo \\$! > $QUEST_TMP.tcpdump.pid'" >/dev/null 2>&1 \\
    || fail "could not launch detached Quest tcpdump"

sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap" -- "$FILTER" >"$OUT/host-tcpdump.txt" 2>&1 &
''',
    '''adb shell "su -c '$QUEST_NOHUP $QUEST_TCPDUMP -Z root -B $CAPTURE_BUFFER_KIB -i $QUEST_IF -s 96 -w $QUEST_TMP.pcap -- \\"$FILTER\\" >/dev/null 2>$QUEST_TMP.tcpdump.err </dev/null & echo \\$! > $QUEST_TMP.tcpdump.pid'" >/dev/null 2>&1 \\
    || fail "could not launch detached Quest tcpdump"

sleep 1
adb shell "su -c 'kill -0 \\$(cat $QUEST_TMP.tcpdump.pid)'" >/dev/null 2>&1 || fail "detached Quest tcpdump exited before USB detach"
QUEST_TCPDUMP_STATUS=$(adb shell "su -c 'cat $QUEST_TMP.tcpdump.err 2>/dev/null || true'" | tr -d '\\r')
if [[ "$QUEST_TCPDUMP_STATUS" != *"listening on $QUEST_IF"* ]]; then
    printf '%s\\n' "$QUEST_TCPDUMP_STATUS" >&2
    fail "Quest tcpdump did not report an active capture loop before USB detach"
fi

echo
echo "USB-DETACHED WORKLOAD MODE"
echo "  1. Unplug the Quest USB cable now."
echo "  2. Move to your normal VR position."
echo "  3. Return to this terminal and press Enter."
read -r -p "Press Enter only after USB is unplugged and the Quest is in the normal VR position: " _

ADB_DURING_WORKLOAD=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_DURING_WORKLOAD" -eq 0 ]] || fail "Quest is still visible to ADB; unplug USB and ensure wireless ADB is disconnected"

CAPTURE_START_EPOCH_NS=$(date +%s%N)
echo "capture_start_epoch_ns=$CAPTURE_START_EPOCH_NS" >>"$OUT/metadata.txt"
echo "capture_started_utc=$(date -u +%FT%TZ)" >>"$OUT/metadata.txt"

sudo tcpdump -B "$CAPTURE_BUFFER_KIB" -i "$HOST_IF" -s 96 -w "$OUT/host.pcap" -- "$FILTER" >"$OUT/host-tcpdump.txt" 2>&1 &
''',
    "USB detach before host capture",
)

capture = replace_once(
    capture,
    '''adb shell "su -c 'kill -0 \\$(cat $QUEST_TMP.tcpdump.pid)'" >/dev/null 2>&1 || fail "detached Quest tcpdump exited before CAPTURE ARMED"
QUEST_TCPDUMP_STATUS=$(adb shell "su -c 'cat $QUEST_TMP.tcpdump.err 2>/dev/null || true'" | tr -d '\\r')
if [[ "$QUEST_TCPDUMP_STATUS" != *"listening on $QUEST_IF"* ]]; then
    printf '%s\\n' "$QUEST_TCPDUMP_STATUS" >&2
    fail "Quest tcpdump did not report an active capture loop before CAPTURE ARMED"
fi
''',
    '''# Quest tcpdump was verified before USB detach; no ADB command is issued here.
''',
    "remove workload ADB verification",
)

capture = replace_once(
    capture,
    '''snapshot_host after
snapshot_quest after

WIFI_STATUS_AFTER=$(cat "$OUT/quest-wifi-status-after.txt" 2>/dev/null || true)
''',
    '''snapshot_host after

# Stop host-side observers at the declared capture end before USB is reattached.
if [[ -n "$HOST_TCPDUMP_PID" ]]; then
    sudo kill -2 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
fi
if [[ -n "$HOST_SAMPLER_PID" ]]; then
    kill "$HOST_SAMPLER_PID" >/dev/null 2>&1 || true
fi
sleep 1
if [[ -n "$HOST_TCPDUMP_PID" ]]; then
    sudo kill -15 "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
    wait "$HOST_TCPDUMP_PID" >/dev/null 2>&1 || true
    HOST_TCPDUMP_PID=""
fi
if [[ -n "$HOST_SAMPLER_PID" ]]; then
    wait "$HOST_SAMPLER_PID" >/dev/null 2>&1 || true
    HOST_SAMPLER_PID=""
fi

echo
echo "WORKLOAD COMPLETE"
echo "Reconnect the Quest to this PC over USB now. Do not enable wireless ADB."
read -r -p "Press Enter after USB ADB has reconnected: " _
ADB_COUNT_AFTER=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT_AFTER" -eq 1 ]] || fail "expected exactly one USB ADB device after reconnect, found $ADB_COUNT_AFTER"
ADB_SERIAL_AFTER=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
[[ "$ADB_SERIAL_AFTER" != *:* ]] || fail "wireless ADB is connected after the workload; disconnect it before retrieval"
[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"

snapshot_quest after

WIFI_STATUS_AFTER=$(cat "$OUT/quest-wifi-status-after.txt" 2>/dev/null || true)
''',
    "USB reconnect before Quest after-snapshot",
)

capture_out.write_text(capture)

run = replace_once(
    run,
    'CAPTURE="$ROOT/tools/helix-blackout-capture.sh"\n',
    f'CAPTURE="{capture_out}"\n',
    "route preflight to audited temporary capture",
)
run_out.write_text(run)
PY

# Optional, explicit post-generation hook. The hook receives the exact capture
# artifact that will be executed. It must fail closed on any mismatch.
if [[ -n "${HELIX_CAPTURE_PATCH:-}" ]]; then
    [[ -f "$HELIX_CAPTURE_PATCH" ]] || { echo "missing HELIX_CAPTURE_PATCH=$HELIX_CAPTURE_PATCH" >&2; exit 1; }
    python3 "$HELIX_CAPTURE_PATCH" "$TMP_CAPTURE"
fi

bash -n "$TMP_CAPTURE"
bash -n "$TMP_RUN"

# Expose the exact final artifact to an optional audit command before runtime.
if [[ -n "${HELIX_CAPTURE_AUDIT:-}" ]]; then
    [[ -f "$HELIX_CAPTURE_AUDIT" ]] || { echo "missing HELIX_CAPTURE_AUDIT=$HELIX_CAPTURE_AUDIT" >&2; exit 1; }
    python3 "$HELIX_CAPTURE_AUDIT" "$TMP_CAPTURE"
fi

bash "$TMP_RUN"
