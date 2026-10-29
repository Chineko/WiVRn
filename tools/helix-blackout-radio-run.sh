#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
USB_RUN="$ROOT/tools/helix-blackout-usb-detached-run.sh"
PATCH="$ROOT/tools/helix-blackout-radio-patch-v4.py"
AUDIT="$ROOT/tools/helix-blackout-radio-audit-v4.py"
RADIO_REDUCER="$ROOT/tools/helix-blackout-radio-reduce-v4.py"
SELFTEST="$ROOT/tools/helix-blackout-radio-selftest.py"
BASE_REDUCER="$ROOT/tools/helix-blackout-reduce.py"

for path in "$USB_RUN" "$PATCH" "$AUDIT" "$RADIO_REDUCER" "$SELFTEST" "$BASE_REDUCER"; do
    [[ -f "$path" ]] || { echo "missing $path" >&2; exit 1; }
done
for cmd in adb awk bash basename cp cut date dirname git grep mktemp mv python3 rm sha256sum sleep sudo tar tr; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing required host command: $cmd" >&2; exit 1; }
done

DRY_CAPTURE=""
PARSER_SAMPLE=""
PARSER_INSTANCE=""
cleanup_top() {
    rm -f "$DRY_CAPTURE" "$PARSER_SAMPLE" >/dev/null 2>&1 || true
    if [[ -n "$PARSER_INSTANCE" ]]; then
        local adb_count
        adb_count=$(adb devices 2>/dev/null | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
        if [[ "$adb_count" -eq 1 ]]; then
            adb shell "su -c 'echo 0 > $PARSER_INSTANCE/tracing_on 2>/dev/null || true; echo 0 > $PARSER_INSTANCE/events/enable 2>/dev/null || true; rmdir $PARSER_INSTANCE 2>/dev/null || true'" >/dev/null 2>&1 || true
        fi
    fi
}
trap cleanup_top EXIT INT TERM

python3 -m py_compile "$PATCH" "$AUDIT" "$RADIO_REDUCER" "$SELFTEST" "$BASE_REDUCER"
bash -n "$USB_RUN"
python3 "$SELFTEST"

export HELIX_CAPTURE_PATCH="$PATCH"
export HELIX_CAPTURE_AUDIT="$AUDIT"

# First gate: generate and audit the exact final capture artifact without any
# Quest/device/runtime interaction. Audit exits 42 intentionally after copying
# the artifact. This catches generation and Bash-syntax defects before ADB.
DRY_CAPTURE=$(mktemp "${TMPDIR:-/tmp}/helix-blackout-radio-audited.XXXXXX.sh")
set +e
HELIX_AUDIT_CAPTURE_ONLY_OUT="$DRY_CAPTURE" bash "$USB_RUN"
DRY_RC=$?
set -e
[[ "$DRY_RC" -eq 42 ]] || { echo "dry generated-artifact audit did not finish with expected gate code 42 (got $DRY_RC)" >&2; exit 1; }
[[ -s "$DRY_CAPTURE" ]] || { echo "dry generated capture artifact is missing or empty" >&2; exit 1; }
AUDITED_SHA=$(sha256sum "$DRY_CAPTURE" | awk '{print $1}')
[[ "$AUDITED_SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "could not compute audited capture SHA-256" >&2; exit 1; }
unset HELIX_AUDIT_CAPTURE_ONLY_OUT
export HELIX_AUDIT_EXPECT_SHA256="$AUDITED_SHA"

# Second gate: actual-device format compatibility. The synthetic self-test
# proves reducer logic; this proves the Quest renders dp_rx_udp_pkt text in the
# exact form consumed by the active reducer. USB/setup-only, no VR workload.
ADB_COUNT=$(adb devices | awk 'NR>1 && $2 == "device" {n++} END {print n+0}')
[[ "$ADB_COUNT" -eq 1 ]] || { echo "expected exactly one connected ADB device for radio parser preflight, found $ADB_COUNT" >&2; exit 1; }
ADB_SERIAL=$(adb devices | awk 'NR>1 && $2 == "device" {print $1; exit}')
[[ -n "$ADB_SERIAL" && "$ADB_SERIAL" != *:* ]] || { echo "radio parser preflight requires USB ADB only" >&2; exit 1; }
ROOT_ID=$(adb shell su -c id 2>/dev/null | tr -d '\r' || true)
[[ "$ROOT_ID" == *"uid=0"* ]] || { echo "Quest root shell is not active for radio parser preflight" >&2; exit 1; }
QUEST_ROUTE=$(adb shell "su -c 'ip route show default 2>/dev/null | head -n1'" | tr -d '\r')
QUEST_IF=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<<"$QUEST_ROUTE")
[[ -n "$QUEST_IF" ]] || QUEST_IF=wlan0
QUEST_IP=$(adb shell "su -c 'ip -4 -o addr show dev $QUEST_IF scope global 2>/dev/null | head -n1'" | tr -d '\r' | awk '{print $4}' | cut -d/ -f1)
[[ -n "$QUEST_IP" ]] || { echo "could not determine Quest IPv4 address for radio parser preflight" >&2; exit 1; }

PARSER_INSTANCE="/sys/kernel/tracing/instances/helix_radio_parser_$$"
PARSER_PORT=30969
PARSER_SAMPLE=$(mktemp "${TMPDIR:-/tmp}/helix-radio-parser.XXXXXX.txt")
adb shell "su -c 'test -r /sys/kernel/tracing/events/wlan/dp_rx_udp_pkt/format && mkdir $PARSER_INSTANCE && echo 0 > $PARSER_INSTANCE/tracing_on && echo 0 > $PARSER_INSTANCE/events/enable && echo 256 > $PARSER_INSTANCE/buffer_size_kb && echo 1 > $PARSER_INSTANCE/events/wlan/dp_rx_udp_pkt/enable && echo 1 > $PARSER_INSTANCE/tracing_on'" >/dev/null 2>&1 \
    || { echo "could not arm temporary Quest dp_rx_udp_pkt parser preflight" >&2; exit 1; }
python3 - "$QUEST_IP" "$PARSER_PORT" <<'PYRADIOPARSER'
import socket, sys
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b"helix-radio-parser-preflight", (sys.argv[1], int(sys.argv[2])))
s.close()
PYRADIOPARSER
sleep 0.2
adb exec-out su -c "grep 'dstport=$PARSER_PORT' '$PARSER_INSTANCE/trace' | tail -n1" >"$PARSER_SAMPLE" 2>/dev/null || true
adb shell "su -c 'echo 0 > $PARSER_INSTANCE/tracing_on; echo 0 > $PARSER_INSTANCE/events/enable; rmdir $PARSER_INSTANCE 2>/dev/null || true'" >/dev/null 2>&1 || true
PARSER_INSTANCE=""
python3 - "$RADIO_REDUCER" "$PARSER_SAMPLE" "$PARSER_PORT" <<'PYRADIOPARSECHECK'
import importlib.util
import sys
from pathlib import Path
reducer, sample, port = Path(sys.argv[1]), Path(sys.argv[2]), int(sys.argv[3])
spec = importlib.util.spec_from_file_location("helix_radio_reduce_device_check", reducer)
mod = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(mod)
rows = mod.parse_trace(sample)
if not any(key[2] == port for _ts, key in rows):
    raise SystemExit("actual Quest dp_rx_udp_pkt sample is not parseable by the active radio reducer")
PYRADIOPARSECHECK
rm -f "$PARSER_SAMPLE"
PARSER_SAMPLE=""
echo "Quest radio parser preflight PASS"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-radio-$STAMP"}
[[ ! -e "$OUT" && ! -e "${OUT}-reduced" && ! -e "${OUT}-reduced.tar.gz" ]] \
    || { echo "refusing to mix this run with existing output path: $OUT" >&2; exit 1; }
export HELIX_CAPTURE_DIR="$OUT"

echo "Helix one-run Quest WLAN attribution"
echo "  generated artifact: Audit A PASS / sha256=$AUDITED_SHA"
echo "  device trace parser: PASS"
echo "  output: $OUT"
echo "  observer: wlan:dp_rx_udp_pkt + existing paired PCAPs"
echo "  workload: unchanged WiVRn/avatar reproduction"
echo "  target: 2-3 characteristic lag events, then stop promptly"
echo

# USB_RUN regenerates the capture artifact. Audit A compares its SHA-256 with
# the dry-audited artifact before TMP_RUN is allowed to touch runtime state.
bash "$USB_RUN"

[[ -d "$OUT" ]] || { echo "radio run completed without expected capture directory: $OUT" >&2; exit 1; }
[[ -s "$OUT/quest-wlan-dp-rx-udp.trace" ]] || { echo "full Quest driver trace is missing after capture" >&2; exit 1; }

# The proven base reducer runs during capture teardown. Its decision gate is a
# prerequisite for deeper radio attribution; the radio layer may add evidence
# but may not override a failed paired-PCAP integrity gate.
REDUCED="${OUT}-reduced"
ARCHIVE="${OUT}-reduced.tar.gz"
BASE_SUMMARY="$REDUCED/reduction-summary.txt"
[[ -d "$REDUCED" ]] || { echo "expected reduced directory is missing: $REDUCED" >&2; exit 1; }
[[ -s "$ARCHIVE" ]] || { echo "initial reduced archive is missing: $ARCHIVE" >&2; exit 1; }
[[ -s "$BASE_SUMMARY" ]] || { echo "base reduction summary is missing: $BASE_SUMMARY" >&2; exit 1; }
BASE_DECISION=$(awk -F= '$1=="decision_capable" {print $2; exit}' "$BASE_SUMMARY")
[[ "$BASE_DECISION" == "true" || "$BASE_DECISION" == "false" ]] || { echo "base reduction summary lacks a valid decision_capable gate" >&2; exit 1; }

# Trim only the copied full text trace from the upload-oriented reduced tree;
# the raw trace and the already-created archive remain preserved locally until
# the replacement archive succeeds.
rm -f "$REDUCED/quest-wlan-dp-rx-udp.trace"

python3 "$RADIO_REDUCER" "$OUT"
[[ -s "$OUT/radio-attribution-summary.txt" ]] || { echo "radio attribution summary is missing" >&2; exit 1; }
RADIO_DECISION=$(awk -F= '$1=="radio_decision_capable" {print $2; exit}' "$OUT/radio-attribution-summary.txt")
[[ "$RADIO_DECISION" == "true" || "$RADIO_DECISION" == "false" ]] || { echo "radio attribution summary lacks a valid radio_decision_capable gate" >&2; exit 1; }
OVERALL_DECISION=false
if [[ "$BASE_DECISION" == "true" && "$RADIO_DECISION" == "true" ]]; then
    OVERALL_DECISION=true
fi
{
    echo "base_paired_pcap_decision_capable=$BASE_DECISION"
    echo "overall_decision_capable=$OVERALL_DECISION"
    if [[ "$BASE_DECISION" != "true" ]]; then
        echo "overall_decision_blocker=base_paired_pcap_gate_failed"
    elif [[ "$RADIO_DECISION" != "true" ]]; then
        echo "overall_decision_blocker=quest_driver_trace_gate_failed_or_ambiguous"
    fi
} >>"$OUT/radio-attribution-summary.txt"
cp "$OUT/radio-attribution-summary.txt" "$REDUCED/radio-attribution-summary.txt"

TMP_ARCHIVE="${ARCHIVE}.tmp"
rm -f "$TMP_ARCHIVE"
tar -C "$(dirname "$REDUCED")" -czf "$TMP_ARCHIVE" "$(basename "$REDUCED")"
[[ -s "$TMP_ARCHIVE" ]] || { echo "temporary reduced radio attribution archive is empty" >&2; exit 1; }
mv -f "$TMP_ARCHIVE" "$ARCHIVE"

trap - EXIT INT TERM
rm -f "$DRY_CAPTURE"
DRY_CAPTURE=""

echo
echo "Radio attribution run complete."
echo "Base paired-PCAP gate: $BASE_DECISION"
echo "Quest driver-trace gate: $RADIO_DECISION"
echo "Overall decision gate: $OVERALL_DECISION"
echo "Summary: $OUT/radio-attribution-summary.txt"
echo "Full driver trace retained locally: $OUT/quest-wlan-dp-rx-udp.trace"
echo "Upload: $ARCHIVE"
