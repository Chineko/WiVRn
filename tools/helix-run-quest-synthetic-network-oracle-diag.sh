#!/usr/bin/env bash
set -euo pipefail

BASE_LAUNCHER_COMMIT="636de16b06f445ee7e1f0f8dd611802389f80485"
BASE_LAUNCHER_PATH="tools/helix-run-quest-synthetic-network-v3.sh"
DIAG_SOURCE_COMMIT="2022843f829ac6aff8af4741557c9b35d0651dce"
DIAG_SOURCE_BRANCH="helix-synthetic-network-oracle-diag"
DIAG_BUILD_ROOT="$HOME/helix-synthetic-oracle-diag-build-20261030-194105"
DIAG_SERVER="$DIAG_BUILD_ROOT/wivrn-server"
DIAG_SERVER_SHA256="7f2951dfeca6703227b25f847fe39af6a3d24a30063ee59cd39da88ee34b9232"
BASE_SOURCE_COMMIT="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"
BASE_SERVER_SHA256="1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 sha256sum awk grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"; done
[[ -x "$DIAG_SERVER" && -s "$DIAG_SERVER" ]] || fail "diagnostic server missing: $DIAG_SERVER"
[[ "$(sha256sum "$DIAG_SERVER" | awk '{print $1}')" == "$DIAG_SERVER_SHA256" ]] || fail "diagnostic server hash mismatch"

git fetch -q origin "$DIAG_SOURCE_BRANCH"
[[ "$(git rev-parse "refs/remotes/origin/$DIAG_SOURCE_BRANCH")" == "$DIAG_SOURCE_COMMIT" ]] || fail "diagnostic source branch moved"
git show "$DIAG_SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_DETAIL' || fail "diagnostic oracle marker missing from source"
git show "$DIAG_SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'return accepts_expected && rejects_mutations;' || fail "oracle pass semantics changed"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "$BASE_LAUNCHER_COMMIT:$BASE_LAUNCHER_PATH" > "$tmp"

python3 - "$tmp" "$DIAG_SOURCE_COMMIT" "$DIAG_SOURCE_BRANCH" "$DIAG_SERVER" "$DIAG_SERVER_SHA256" "$BASE_SOURCE_COMMIT" "$BASE_SERVER_SHA256" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
diag_source, diag_branch, diag_server, diag_sha, base_source, base_sha = sys.argv[2:]
s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

once(f'SOURCE_COMMIT="{base_source}"', f'SOURCE_COMMIT="{diag_source}"', 'source commit')
once('SOURCE_BRANCH="helix-encoded-nvenc-torture-fix-v3-built"', f'SOURCE_BRANCH="{diag_branch}"', 'source branch')
once('SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"', f'SERVER={diag_server!r}', 'server path')
once(f'SERVER_SHA256="{base_sha}"', f'SERVER_SHA256="{diag_sha}"', 'server hash')

for old in [
    'grep -Fqx "source_commit=$SOURCE_COMMIT" "$META" || fail "metadata source mismatch"\n',
    'grep -Fqx "remote_head=$SOURCE_COMMIT" "$META" || fail "metadata remote-head mismatch"\n',
    'grep -Fqx "$ARTIFACT_GATE" "$META" || fail "artifact gate missing"\n',
]:
    if s.count(old) != 1:
        raise SystemExit('FAIL: base metadata identity anchor count='+str(s.count(old)))
    s=s.replace(old,'',1)

old="echo 'NETWORK_PREFLIGHT_ARTIFACT=PASS exact-v3-source-server-apk'\n"
new=(
    "echo 'NETWORK_DIAGNOSTIC_PREFLIGHT=PASS exact-diag-server plus proven-v3-apk'\n"
    "echo 'NETWORK_DIAGNOSTIC_ONLY=1 not-a-promotion-artifact'\n"
)
once(old,new,'preflight label')

old="grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=1' \"$evidence/server-log.txt\" || fail \"oracle sanity did not pass\"\n"
new=(
    "grep -E 'HELIX_SYNTHETIC_TRANSPORT_(ORACLE_DETAIL|ORACLE_SANITY|EXIT|RESULT)' \"$evidence/server-log.txt\" || true\n"
    "grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=1' \"$evidence/server-log.txt\" || { echo \"EVIDENCE=$evidence\"; fail \"oracle sanity did not pass\"; }\n"
)
once(old,new,'oracle diagnostic print')

once("echo 'verdict=QUEST_SYNTHETIC_NETWORK_PASS'\n", "echo 'verdict=QUEST_SYNTHETIC_NETWORK_DIAGNOSTIC_PASS'\n", 'diagnostic verdict')

required=[diag_source,diag_branch,diag_server,diag_sha,'NETWORK_DIAGNOSTIC_ONLY=1','HELIX_SYNTHETIC_TRANSPORT_ORACLE_DETAIL']
for x in required:
    if x not in s:
        raise SystemExit('FAIL: diagnostic launcher requirement missing: '+x)
p.write_text(s)
PY

bash -n "$tmp"
grep -Fq "$DIAG_SOURCE_COMMIT" "$tmp" || fail "diagnostic source binding missing"
grep -Fq "$DIAG_SERVER_SHA256" "$tmp" || fail "diagnostic server hash binding missing"
grep -Fq 'NETWORK_DIAGNOSTIC_ONLY=1 not-a-promotion-artifact' "$tmp" || fail "diagnostic-only marker missing"
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_DETAIL' "$tmp" || fail "oracle detail output missing"
! grep -Fq 'verdict=QUEST_SYNTHETIC_NETWORK_PASS' "$tmp" || fail "production PASS verdict leaked into diagnostic launcher"

echo 'DIAGNOSTIC_RUNTIME_BINDING=PASS exact-source-server-hash plus-proven-apk'
exec bash "$tmp"
