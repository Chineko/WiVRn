#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
USB_RUN="$ROOT/tools/helix-blackout-usb-detached-run.sh"
PATCH="$ROOT/tools/helix-blackout-radio-patch-v2.py"
AUDIT="$ROOT/tools/helix-blackout-radio-audit.py"
RADIO_REDUCER="$ROOT/tools/helix-blackout-radio-reduce.py"
BASE_REDUCER="$ROOT/tools/helix-blackout-reduce.py"

for path in "$USB_RUN" "$PATCH" "$AUDIT" "$RADIO_REDUCER" "$BASE_REDUCER"; do
    [[ -f "$path" ]] || { echo "missing $path" >&2; exit 1; }
done

python3 -m py_compile "$PATCH" "$AUDIT" "$RADIO_REDUCER" "$BASE_REDUCER"
bash -n "$USB_RUN"

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-radio-$STAMP"}
export HELIX_CAPTURE_DIR="$OUT"
export HELIX_CAPTURE_PATCH="$PATCH"
export HELIX_CAPTURE_AUDIT="$AUDIT"

echo "Helix one-run Quest WLAN attribution"
echo "  output: $OUT"
echo "  observer: wlan:dp_rx_udp_pkt + existing paired PCAPs"
echo "  workload: unchanged WiVRn/avatar reproduction"
echo "  target: 2-3 characteristic lag events, then stop promptly"
echo

bash "$USB_RUN"

[[ -d "$OUT" ]] || { echo "radio run completed without expected capture directory: $OUT" >&2; exit 1; }
python3 "$RADIO_REDUCER" "$OUT"
# Re-run the existing reducer once so radio-attribution-summary.txt is copied
# into the reduced bundle/archive produced for upload.
python3 "$BASE_REDUCER" "$OUT"

echo
echo "Radio attribution complete."
echo "Summary: $OUT/radio-attribution-summary.txt"
echo "Upload: ${OUT}-reduced.tar.gz"
