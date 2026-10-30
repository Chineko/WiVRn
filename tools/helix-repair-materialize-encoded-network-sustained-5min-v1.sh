#!/usr/bin/env bash
set -euo pipefail

BASE_MATERIALIZER_COMMIT="976cf7b35beb63eafb4162a6d75fd93c0ad4af08"
BASE_MATERIALIZER_PATH="tools/helix-materialize-encoded-network-sustained-5min-v1.sh"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
META="$ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
BIN="$ROOT/helix-vulkan-stimulus-sustained-v1"
RUNNER="$ROOT/helix-run-encoded-network-sustained-5min-v1.sh"
PINNED_META_SHA="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"
BAD_BINARY_SHA="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8bace15c0c534a85d9a"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk bash git grep python3 sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"

[[ -s "$META" && -x "$BIN" ]] || fail "sealed sustained Vulkan artifacts missing"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$PINNED_META_SHA" ]] || fail "sustained Vulkan metadata hash mismatch"
GOOD_BINARY_SHA="$(awk -F= '$1=="binary_sha256" {print $2}' "$META" | tail -1)"
[[ "$GOOD_BINARY_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "metadata binary_sha256 is not exactly 64 hex characters"
[[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$GOOD_BINARY_SHA" ]] || fail "actual sustained Vulkan binary does not match pinned metadata"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git cat-file -e "${BASE_MATERIALIZER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_MATERIALIZER_COMMIT"
git show "${BASE_MATERIALIZER_COMMIT}:${BASE_MATERIALIZER_PATH}" >"$tmp"
bash "$tmp"

python3 - "$RUNNER" "$BAD_BINARY_SHA" "$GOOD_BINARY_SHA" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); bad=sys.argv[2]; good=sys.argv[3]
s=p.read_text()
if len(bad) != 65:
    raise SystemExit(f'FAIL: expected known bad digest length 65, got {len(bad)}')
if len(good) != 64:
    raise SystemExit(f'FAIL: authoritative digest length {len(good)}')
n=s.count(bad)
if n != 1:
    raise SystemExit(f'FAIL: bad binary hash occurrence count={n}, expected=1')
s=s.replace(bad,good,1)
p.write_text(s)
PY

bash -n "$RUNNER" || fail "repaired 5-minute runner syntax invalid"
grep -Fqx "VULKAN_BINARY_SHA256=\"$GOOD_BINARY_SHA\"" "$RUNNER" || fail "repaired runner binary hash binding missing"
! grep -Fq "$BAD_BINARY_SHA" "$RUNNER" || fail "bad 65-character binary hash remains"
ACTUAL_RUNNER_BINARY_SHA="$(awk -F'"' '/^VULKAN_BINARY_SHA256=/ {print $2}' "$RUNNER")"
[[ "$ACTUAL_RUNNER_BINARY_SHA" == "$GOOD_BINARY_SHA" ]] || fail "runner binary binding differs from authoritative metadata"
[[ "$(sha256sum "$BIN" | awk '{print $1}')" == "$ACTUAL_RUNNER_BINARY_SHA" ]] || fail "runner binary binding does not match actual binary"
RUNNER_SHA="$(sha256sum "$RUNNER" | awk '{print $1}')"
printf 'PASS: repaired deterministic 5-minute sustained runner.\nauthoritative_binary_sha256=%s\nrunner=%s\nrunner_sha256=%s\nframes=27000\ncycles=30\nspacing=300\nexpected=90\ndriver_timeout_seconds=420\n' "$GOOD_BINARY_SHA" "$RUNNER" "$RUNNER_SHA"
