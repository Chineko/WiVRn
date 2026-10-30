#!/usr/bin/env bash
set -euo pipefail

PINNED_SPATIAL_COMMIT="4eaefdb1b7ff9cad56b76f44a5011fdb65f006de"
PINNED_SPATIAL_PATH="tools/helix-run-encoded-network-spatial-unplug-v1.sh"
START_DELAY="${HELIX_START_DELAY:-20}"
POSITION_LABEL="${HELIX_POSITION_LABEL:-spatial_unlabeled}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash mktemp tee sed tail cp grep; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
[[ "$START_DELAY" =~ ^[0-9]+$ ]] || fail "HELIX_START_DELAY must be a nonnegative integer"

runner="$(mktemp)"
console="$(mktemp)"
trap 'rm -f "$runner" "$console"' EXIT INT TERM

git cat-file -e "${PINNED_SPATIAL_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PINNED_SPATIAL_COMMIT"
git show "${PINNED_SPATIAL_COMMIT}:${PINNED_SPATIAL_PATH}" >"$runner"
[[ -s "$runner" ]] || fail "pinned passing spatial runner unavailable"
bash -n "$runner"
grep -Fq 'PINNED_NETWORK_RUNNER_COMMIT="b2111b38e734c3c22c65ca0a3450008afc016edc"' "$runner" || fail "pinned network runner binding missing"
grep -Fq 'SPATIAL_WRAPPER_COMPOSITION_AUDIT=PASS' "$runner" || fail "spatial composition audit marker missing"
grep -Fq 'SPATIAL_UNPLUG_WRAPPER_AUDIT=PASS' "$runner" || fail "spatial wrapper audit marker missing"

echo "SPATIAL_EVIDENCE_CAPTURE_AUDIT=PASS pinned_spatial_runner=$PINNED_SPATIAL_COMMIT runtime-unchanged"
echo "SPATIAL_POSITION_LABEL=$POSITION_LABEL"

set +e
HELIX_START_DELAY="$START_DELAY" bash "$runner" 2>&1 | tee "$console"
status=${PIPESTATUS[0]}
set -e

evidence="$(sed -n 's/^evidence=//p' "$console" | tail -1)"
if [[ -n "$evidence" && -d "$evidence" ]]; then
    cp "$console" "$evidence/spatial-console.txt"
    printf 'position_label=%s\nstart_delay_seconds=%s\npinned_spatial_runner_commit=%s\nconsole_capture=spatial-console.txt\n' \
        "$POSITION_LABEL" "$START_DELAY" "$PINNED_SPATIAL_COMMIT" >"$evidence/spatial-run.txt"
    echo "SPATIAL_EVIDENCE_CAPTURE=PASS evidence=$evidence console=$evidence/spatial-console.txt label=$POSITION_LABEL"
else
    echo "SPATIAL_EVIDENCE_CAPTURE=NO_EVIDENCE_DIR runtime_status=$status" >&2
fi

exit "$status"
