#!/usr/bin/env bash
set -euo pipefail

BASE_SEAL_COMMIT="bc93c030bd71becd120ff84e5f2210d8df062a19"
BASE_SEAL_BLOB="7731fb596e8230b99b115cc2cc980fa0b43016b7"
BASE_PATH="tools/helix-seal-vulkan-texture-churn-4k-live4-burst4-v1.sh"
BUILD_TOOLING="c3ed8c824a98b4cada80d635787c6af788084583"
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
[[ "$(git rev-parse "$BASE_SEAL_COMMIT:$BASE_PATH")" == "$BASE_SEAL_BLOB" ]] || fail "base v1 seal blob mismatch"
git show "$BASE_SEAL_COMMIT:$BASE_PATH" > "$TMP"

python3 - "$TMP" "$BUILD_TOOLING" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); new=sys.argv[2]; s=p.read_text()
old='BUILD_TOOLING="dbfea104b250d9271839d0912b6b4a50a6170dcd"'
repl=f'BUILD_TOOLING="{new}"'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: tooling binding count={s.count(old)}')
s=s.replace(old,repl,1)
anchor="grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' \"$SRC\" || fail \"source dwell mismatch\""
if s.count(anchor) != 1:
    raise SystemExit(f'FAIL: source audit anchor count={s.count(anchor)}')
s=s.replace(anchor, anchor+'\n! grep -Fq \'auto next=\' "$SRC" || fail "stale dead next variable present"',1)
p.write_text(s)
PY

grep -Fqx "BUILD_TOOLING=\"$BUILD_TOOLING\"" "$TMP" || fail "corrected tooling binding missing"
grep -Fq "stale dead next variable present" "$TMP" || fail "dead-next seal audit missing"
echo "PASS: v2 burst4 seal correction audit; tooling=$BUILD_TOOLING dead_next_guard=present base_blob=$BASE_SEAL_BLOB"
bash "$TMP"
