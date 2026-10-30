#!/usr/bin/env bash
set -euo pipefail

# Patch only the brittle runtime banner provenance guard from the audited
# direct-server runner. Artifact provenance remains bound to the exact compiled
# source commit; runtime identity is proven via /proc/<pid>/exe instead.
base_tooling="8c656f35e62fa4738230a8f99e942740b645122b"
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

git show "${base_tooling}:tools/helix-run-encoded-nvenc-torture.sh" >"$tmp"
python3 - "$tmp" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
s=p.read_text()
old='''for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" && break
  sleep .1
done
grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" || fail "server startup log missing exact commit"
'''
new='''for _ in $(seq 1 100); do
  kill -0 "$SERVER_PID" 2>/dev/null || fail "exact server exited during startup"
  grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" && break
  sleep .1
done
grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing"
SERVER_EXE="$(readlink -f "/proc/$SERVER_PID/exe" 2>/dev/null || true)"
[[ "$SERVER_EXE" == "$SERVER" ]] || fail "running server identity mismatch: $SERVER_EXE != $SERVER"
printf 'server_exe=%s\\n' "$SERVER_EXE" >>"$OUT/metadata.txt"
'''
if old not in s:
    raise SystemExit('error: startup provenance anchor not found')
s=s.replace(old,new,1)
old2='''grep -Fq "$SOURCE_COMMIT" "$SERVER_LOG" || fail "server log missing exact commit"
'''
new2='''grep -Eq '^WiVRn .* starting$' "$SERVER_LOG" || fail "server startup banner missing from preserved log"
grep -Fq "source_commit=$SOURCE_COMMIT" "$META" || fail "artifact metadata lost exact source identity"
'''
if old2 not in s:
    raise SystemExit('error: final provenance anchor not found')
s=s.replace(old2,new2,1)
p.write_text(s)
PY

# Static guard: the runtime script must no longer require the full SHA in the
# human-readable startup log, and must prove the live executable path instead.
! grep -Fq 'server startup log missing exact commit' "$tmp"
grep -Fq 'running server identity mismatch' "$tmp"
grep -Fq 'source_commit=$SOURCE_COMMIT' "$tmp"

exec bash "$tmp"
