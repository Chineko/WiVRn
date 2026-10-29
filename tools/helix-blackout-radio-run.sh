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
for cmd in python3 bash sha256sum mktemp awk; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "missing required host command: $cmd" >&2; exit 1; }
done

python3 -m py_compile "$PATCH" "$AUDIT" "$RADIO_REDUCER" "$SELFTEST" "$BASE_REDUCER"
bash -n "$USB_RUN"
python3 "$SELFTEST"

export HELIX_CAPTURE_PATCH="$PATCH"
export HELIX_CAPTURE_AUDIT="$AUDIT"

DRY_CAPTURE=$(mktemp "${TMPDIR:-/tmp}/helix-blackout-radio-audited.XXXXXX.sh")
cleanup_dry() { rm -f "$DRY_CAPTURE"; }
trap cleanup_dry EXIT INT TERM

# Generate and audit the exact final capture artifact without executing the
# runtime/device path. Audit exits 42 intentionally after copying the artifact.
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

STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${HELIX_CAPTURE_DIR:-"$HOME/helix-blackout-radio-$STAMP"}
export HELIX_CAPTURE_DIR="$OUT"

echo "Helix one-run Quest WLAN attribution"
echo "  generated artifact: Audit A PASS / sha256=$AUDITED_SHA"
echo "  output: $OUT"
echo "  observer: wlan:dp_rx_udp_pkt + existing paired PCAPs"
echo "  workload: unchanged WiVRn/avatar reproduction"
echo "  target: 2-3 characteristic lag events, then stop promptly"
echo

# USB_RUN regenerates the capture artifact. Audit A compares its SHA-256 with
# the dry-audited artifact before TMP_RUN is allowed to touch runtime state.
bash "$USB_RUN"

[[ -d "$OUT" ]] || { echo "radio run completed without expected capture directory: $OUT" >&2; exit 1; }
python3 "$RADIO_REDUCER" "$OUT"
# Re-run the proven reducer once so radio-attribution-summary.txt is copied into
# the reduced directory/archive that the user uploads.
python3 "$BASE_REDUCER" "$OUT"

trap - EXIT INT TERM
rm -f "$DRY_CAPTURE"

echo
echo "Radio attribution complete."
echo "Summary: $OUT/radio-attribution-summary.txt"
echo "Upload: ${OUT}-reduced.tar.gz"
