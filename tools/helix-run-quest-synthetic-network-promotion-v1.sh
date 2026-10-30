#!/usr/bin/env bash
set -euo pipefail

BASE_LAUNCHER_COMMIT="636de16b06f445ee7e1f0f8dd611802389f80485"
BASE_LAUNCHER_PATH="tools/helix-run-quest-synthetic-network-v3.sh"
PROMO_SOURCE_COMMIT="6e23563ec49c6ab8a5e76860b2497b5722c3f591"
PROMO_SOURCE_BRANCH="helix-synthetic-network-promotion-v1-built"
PROMO_BUILD_ROOT="$HOME/helix-synthetic-network-promotion-v1-build-20261030-195536"
PROMO_SERVER="$PROMO_BUILD_ROOT/worktree/build-everything/server/wivrn-server"
PROMO_APK="$PROMO_BUILD_ROOT/helix-synthetic-network-promotion-v1-6e23563ec49c.apk"
PROMO_SERVER_SHA256="5ae4f34dec55b4ae0626bff20222bb81c65ebb2c3728bb69a72be227e4acb04e"
PROMO_APK_SHA256="cf441578fc307077b4d3ad05a90233dadec9146e5c8bb87243b4d83021abc76"
BASE_SOURCE_COMMIT="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"
BASE_SERVER_SHA256="1fcbb80dd25ea45c4228008da81d9dfcec9d930a9e8b673201866411d52b64af"
BASE_APK_SHA256="1feec0aa967a142188319b4489aa31b70b9d24b01216b31c89bcdd931a13e83c"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 sha256sum awk grep bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"; done
[[ -x "$PROMO_SERVER" && -s "$PROMO_SERVER" ]] || fail "promotion server missing: $PROMO_SERVER"
[[ -s "$PROMO_APK" ]] || fail "promotion APK missing: $PROMO_APK"
[[ "$(sha256sum "$PROMO_SERVER" | awk '{print $1}')" == "$PROMO_SERVER_SHA256" ]] || fail "promotion server hash mismatch"
[[ "$(sha256sum "$PROMO_APK" | awk '{print $1}')" == "$PROMO_APK_SHA256" ]] || fail "promotion APK hash mismatch"

git fetch -q origin "$PROMO_SOURCE_BRANCH"
[[ "$(git rev-parse "refs/remotes/origin/$PROMO_SOURCE_BRANCH")" == "$PROMO_SOURCE_COMMIT" ]] || fail "promotion source branch moved"
git show "$PROMO_SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d\n' || fail "deterministic oracle sanity marker missing from promotion source"
git show "$PROMO_SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 'constexpr double promotion_threshold = 0.95;' || fail "95 percent promotion gate missing"
git show "$PROMO_SOURCE_COMMIT:server/helix_synthetic_transport.cpp" | grep -Fq 's.catastrophic == 0' || fail "catastrophic zero gate missing"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "$BASE_LAUNCHER_COMMIT:$BASE_LAUNCHER_PATH" > "$tmp"

python3 - "$tmp" "$PROMO_SOURCE_COMMIT" "$PROMO_SOURCE_BRANCH" "$PROMO_BUILD_ROOT" "$PROMO_SERVER" "$PROMO_APK" "$PROMO_SERVER_SHA256" "$PROMO_APK_SHA256" "$BASE_SOURCE_COMMIT" "$BASE_SERVER_SHA256" "$BASE_APK_SHA256" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
(promo_source,promo_branch,promo_root,promo_server,promo_apk,promo_server_sha,promo_apk_sha,
 base_source,base_server_sha,base_apk_sha)=sys.argv[2:]
s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'FAIL: {label} anchor count={n}')
    s=s.replace(old,new,1)

once(f'SOURCE_COMMIT="{base_source}"', f'SOURCE_COMMIT="{promo_source}"', 'source commit')
once('SOURCE_BRANCH="helix-encoded-nvenc-torture-fix-v3-built"', f'SOURCE_BRANCH="{promo_branch}"', 'source branch')
once('BUILD_ROOT="$HOME/helix-encoded-nvenc-fix-v3-build-20261030-185452"', f'BUILD_ROOT={promo_root!r}', 'build root')
once('SERVER="$BUILD_ROOT/worktree/build-everything/server/wivrn-server"', f'SERVER={promo_server!r}', 'server path')
once('APK="$BUILD_ROOT/helix-encoded-nvenc-fix-v3-951ce95cd2ea.apk"', f'APK={promo_apk!r}', 'apk path')
once(f'SERVER_SHA256="{base_server_sha}"', f'SERVER_SHA256="{promo_server_sha}"', 'server hash')
once(f'APK_SHA256="{base_apk_sha}"', f'APK_SHA256="{promo_apk_sha}"', 'apk hash')
once('ARTIFACT_GATE="artifact_gate=PASS encoded-nvenc-fix-v3-server-apk-exact-source"', 'ARTIFACT_GATE="artifact_gate=PASS synthetic-network-promotion-v1-server-apk-exact-source"', 'artifact gate')
once("echo 'NETWORK_PREFLIGHT_ARTIFACT=PASS exact-v3-source-server-apk'\n", "echo 'NETWORK_PROMOTION_PREFLIGHT=PASS exact-promotion-source-server-apk'\n", 'preflight label')

required=[promo_source,promo_branch,promo_root,promo_server,promo_apk,promo_server_sha,promo_apk_sha,
          'artifact_gate=PASS synthetic-network-promotion-v1-server-apk-exact-source',
          'NETWORK_PROMOTION_PREFLIGHT=PASS exact-promotion-source-server-apk',
          'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=1',
          'recorded_total','recorded_good','catastrophic']
for x in required:
    if x not in s:
        raise SystemExit('FAIL: promotion launcher requirement missing: '+x)
p.write_text(s)
PY

bash -n "$tmp"
grep -Fq "$PROMO_SOURCE_COMMIT" "$tmp" || fail "promotion source binding missing"
grep -Fq "$PROMO_SERVER_SHA256" "$tmp" || fail "promotion server hash binding missing"
grep -Fq "$PROMO_APK_SHA256" "$tmp" || fail "promotion APK hash binding missing"
grep -Fq 'NETWORK_PROMOTION_PREFLIGHT=PASS exact-promotion-source-server-apk' "$tmp" || fail "promotion preflight marker missing"
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=1' "$tmp" || fail "oracle sanity runtime gate missing"
grep -Fq 'recorded corpus' "$tmp" || fail "recorded corpus 10/10 runtime gate missing"

echo 'PROMOTION_RUNTIME_BINDING=PASS exact-source-server-apk-hashes frozen-network-gates'
exec bash "$tmp"
