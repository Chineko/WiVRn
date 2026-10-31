#!/usr/bin/env bash
set -euo pipefail

BASE_AUDIT_COMMIT="58c6a7bc8c9c49ae1fd6bc5fba281f4202e5ffad"
BASE_AUDIT_PATH="tools/helix-audit-hevc10-decoder-recovery-runtime-v2.sh"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 grep mktemp cp rm cat; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done

git cat-file -e "${BASE_AUDIT_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$BASE_AUDIT_COMMIT"
git cat-file -e "${BASE_AUDIT_COMMIT}^{commit}" 2>/dev/null || fail "pinned v2 audit commit unavailable"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT INT TERM
git show "${BASE_AUDIT_COMMIT}:${BASE_AUDIT_PATH}" >"$tmp"

python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='for c in git bash python3 grep mktemp cp rm; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done'
new='for c in git bash python3 grep mktemp cp rm cat; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done'
if s.count(old) != 1:
    raise SystemExit(f'FAIL: audit command-gate anchor count={s.count(old)}')
s=s.replace(old,new,1)
old2='''base_log="$(mktemp)"
trap 'rm -f "$base_audit" "$runner_v2" "$final_v2" "$base_log"' EXIT INT TERM'''
new2='''base_log="$(mktemp)"
v2_log="$(mktemp)"
trap 'rm -f "$base_audit" "$runner_v2" "$final_v2" "$base_log" "$v2_log"' EXIT INT TERM'''
if s.count(old2) != 1:
    raise SystemExit(f'FAIL: audit temp-log anchor count={s.count(old2)}')
s=s.replace(old2,new2,1)
old3='''bash "$runner_v2" --emit-only "$final_v2" >"$base_log.v2"
grep -Fqx 'RUNTIME=NOT_RUN' "$base_log.v2" || fail "v2 emit-only crossed runtime boundary"'''
new3='''bash "$runner_v2" --emit-only "$final_v2" >"$v2_log"
grep -Fqx 'RUNTIME=NOT_RUN' "$v2_log" || fail "v2 emit-only crossed runtime boundary"'''
if s.count(old3) != 1:
    raise SystemExit(f'FAIL: audit v2-log anchor count={s.count(old3)}')
s=s.replace(old3,new3,1)
p.write_text(s)
PY

bash -n "$tmp"
grep -Fq 'for c in git bash python3 grep mktemp cp rm cat;' "$tmp" || fail "hardened audit command gate missing"
grep -Fq 'v2_log="$(mktemp)"' "$tmp" || fail "dedicated v2 emit log missing"
! grep -Fq '$base_log.v2' "$tmp" || fail "stale untracked v2 emit log remains"
grep -Fq 'RUNNER_V2_COMMIT="75d8f3dc4d24ca85606094412b70cd5fda6a3ae7"' "$tmp" || fail "runtime v2 commit binding missing"
grep -Fq 'AUDIT_A=PASS hevc10-runtime-v2-inherits-exact-source-artifacts-hashes-seals-stimulus-and-v1-oracle-audit' "$tmp" || fail "Audit A marker missing"
grep -Fq 'AUDIT_B=PASS openxr-drive-before-resolved-main10-gates-both-eye-exact-frame-decoder-oracle-lan-only-claim-boundary' "$tmp" || fail "Audit B marker missing"
grep -Fq "echo 'RUNTIME=NOT_RUN'" "$tmp" || fail "runtime boundary marker missing"

echo 'AUDIT_HARNESS_PREFLIGHT=PASS v2-audit-command-gate-and-temp-logs-hardened'
exec bash "$tmp"
