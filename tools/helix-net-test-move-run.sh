#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
SRC="$ROOT/tools/helix-net-test-run.sh"
[[ -f "$SRC" ]] || { echo "missing $SRC" >&2; exit 1; }

TMP=$(mktemp "${TMPDIR:-/tmp}/helix-net-test-move.XXXXXX.sh")
cleanup() { rm -f "$TMP"; }
trap cleanup EXIT INT TERM

python3 - "$SRC" "$TMP" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
s = src.read_text()

def replace_once(old: str, new: str) -> None:
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"move-run patch expected exactly one match, found {n}: {old[:80]!r}")
    s = s.replace(old, new, 1)

replace_once(
    "RECEIVER_EXTRA_S=3\n",
    "RECEIVER_EXTRA_S=120\nMOVE_SEND_TARGET_S=115\n",
)

replace_once(
    '    echo "experiment=standalone_pc_to_quest_udp_no_wivrn_no_tcpdump"\n'
    '    echo "adb_transport=usb"\n',
    '    echo "experiment=standalone_pc_to_quest_udp_no_wivrn_no_tcpdump_position_matched"\n'
    '    echo "adb_transport=usb_setup_and_retrieval_only"\n'
    '    echo "usb_detached_during_workload=true"\n'
    '    echo "move_send_target_s=$MOVE_SEND_TARGET_S"\n',
)

replace_once(
    "RECEIVER_STARTED=1\nsleep 0.5\n",
    "RECEIVER_STARTED=1\nRECEIVER_LAUNCH_SECONDS=$SECONDS\nsleep 0.5\n",
)

replace_once(
    'echo "No ADB command will run during the sender workload."\n\nset +e\n',
    '''echo "No ADB command will run during the sender workload."\necho\necho "POSITION-MATCHED MODE"\necho "  1. Unplug the Quest USB cable now."\necho "  2. Move the Quest to your normal VR position (~2 m, direct line of sight)."\necho "  3. Return to this terminal and press Enter."\necho "You have roughly 110 seconds from receiver launch; moving promptly is recommended."\necho\nread -r -p "Press Enter only after USB is unplugged and the Quest is in the normal VR position: " _\n\nADB_DURING_MOVE=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')\n[[ "$ADB_DURING_MOVE" -eq 0 ]] || fail "Quest is still visible to ADB; unplug USB and ensure wireless ADB is not connected"\n\nMOVE_ELAPSED=$((SECONDS - RECEIVER_LAUNCH_SECONDS))\nif (( MOVE_ELAPSED >= MOVE_SEND_TARGET_S )); then\n    echo "Helix net test: move/setup took ${MOVE_ELAPSED}s; receiver timing window was missed." >&2\n    echo "Reconnect USB, then rerun this command and complete the move sooner." >&2\n    exit 1\nfi\nWAIT_TO_SEND=$((MOVE_SEND_TARGET_S - MOVE_ELAPSED))\necho "Quest detached from ADB. Holding until the fixed sender start point (${WAIT_TO_SEND}s)..."\nsleep "$WAIT_TO_SEND"\necho "Starting 300-second workload now. Do not reconnect USB until prompted."\necho\n\nset +e\n''',
)

replace_once(
    '''# Receiver was started before the sender and intentionally runs a few seconds longer.\nsleep $((RECEIVER_EXTRA_S + 1))\nif adb shell "kill -0 \\$(cat '$REMOTE_PID') 2>/dev/null" >/dev/null 2>&1; then\n    fail "Quest receiver did not exit after its bounded duration; evidence preserved on device at $REMOTE_BASE.*"\nfi\nRECEIVER_STARTED=0\n\nadb exec-out cat "$REMOTE_RX" >"$OUT/receiver.bin" || fail "failed to retrieve Quest receiver log"\n''',
    '''# The receiver was launched before the move. The fixed sender start point leaves\n# approximately five seconds of receiver tail after the 300-second workload.\nELAPSED_FROM_RX=$((SECONDS - RECEIVER_LAUNCH_SECONDS))\nREMAINING_RX=$((RECEIVER_DURATION - ELAPSED_FROM_RX + 1))\nif (( REMAINING_RX > 0 )); then\n    sleep "$REMAINING_RX"\nfi\n\necho\necho "WORKLOAD COMPLETE"\necho "Reconnect the Quest to this PC over USB now. Do not enable wireless ADB."\nread -r -p "Press Enter after USB ADB has reconnected: " _\n\nADB_COUNT_AFTER=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')\n[[ "$ADB_COUNT_AFTER" -eq 1 ]] || fail "expected exactly one USB ADB device after reconnect, found $ADB_COUNT_AFTER"\nADB_SERIAL_AFTER=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')\n[[ "$ADB_SERIAL_AFTER" != *:* ]] || fail "wireless ADB is connected after the workload; disconnect it and rerun retrieval"\n[[ "$ADB_SERIAL_AFTER" == "$ADB_SERIAL" ]] || fail "reconnected ADB device does not match the Quest used for setup"\n\nif adb shell "kill -0 \\$(cat '$REMOTE_PID') 2>/dev/null" >/dev/null 2>&1; then\n    fail "Quest receiver did not exit after its bounded duration; evidence preserved on device at $REMOTE_BASE.*"\nfi\nRECEIVER_STARTED=0\n\nadb exec-out cat "$REMOTE_RX" >"$OUT/receiver.bin" || fail "failed to retrieve Quest receiver log"\n''',
)

out.write_text(s)
PY

bash -n "$TMP"
exec bash "$TMP"
