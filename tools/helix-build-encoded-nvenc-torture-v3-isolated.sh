#!/usr/bin/env bash
set -euo pipefail
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "$repo_root"
v2_commit="0d892020aa92ad3252c7fab0752d5b833315600b"
v2_path="tools/helix-build-encoded-nvenc-torture-v2-isolated.sh"
for cmd in git python3 bash; do command -v "$cmd" >/dev/null || { echo "error: missing command $cmd" >&2; exit 2; }; done
git cat-file -e "${v2_commit}^{commit}" 2>/dev/null || git fetch origin "$v2_commit"
tmp="$(mktemp -d /tmp/helix-encoded-build-v3.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT INT TERM
v3="$tmp/v3.sh"
git show "${v2_commit}:${v2_path}" >"$v3"
python3 - "$v3" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''server_archive="$(find build-everything -type f -name 'libwivrn-server-library.a' -print -quit)"
[[ -n "$server_archive" && -s "$server_archive" ]] || { echo "error: wivrn server library archive missing" >&2; exit 2; }
ar t "$server_archive" >"${out}/server-archive-members.txt"
grep -Fq 'video_encoder.cpp.o' "${out}/server-archive-members.txt" || { echo "error: server archive lacks base encoder object" >&2; exit 2; }
grep -Fq 'video_encoder_nvenc.cpp.o' "${out}/server-archive-members.txt" || { echo "error: server archive lacks NVENC object" >&2; exit 2; }
nvenc_obj_rel="${nvenc_obj#build-everything/}"
ninja -C build-everything -t query "$nvenc_obj_rel" >"${out}/ninja-nvenc-object.txt"
ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
grep -Fq 'libwivrn-server-library.a' "${out}/ninja-server.txt" || { echo "error: final server graph lacks server library archive" >&2; exit 2; }
server="$(realpath build-everything/server/wivrn-server)"
'''
new='''nvenc_obj_rel="${nvenc_obj#build-everything/}"
ninja -C build-everything -t query "$nvenc_obj_rel" >"${out}/ninja-nvenc-object.txt"
ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
ninja -C build-everything -t commands server/wivrn-server >"${out}/ninja-server-commands.txt"
for obj in 'video_encoder.cpp.o' 'video_encoder_nvenc.cpp.o'; do
    grep -Fq "$obj" "${out}/ninja-server.txt" || { echo "error: final server dependency graph lacks $obj" >&2; exit 2; }
    grep -Fq "$obj" "${out}/ninja-server-commands.txt" || { echo "error: final server command graph lacks $obj" >&2; exit 2; }
done
server="$(realpath build-everything/server/wivrn-server)"
'''
if s.count(old)!=1: raise SystemExit(f"error: provenance anchor count={s.count(old)}")
s=s.replace(old,new,1)
s=s.replace('    "libwivrn-server-library.a" \\\n','    \'ninja-server-commands.txt\' \\\n',1)
s=s.replace('if grep -Fq \'wivrn_config.h\' "$v2"; then\n    echo "error: stale guessed wivrn_config.h guard survived v2 hardening" >&2\n    exit 2\nfi\n\nexec bash "$v2"\n', 'if grep -Fq \'wivrn_config.h\' "$v3"; then\n    echo "error: stale guessed wivrn_config.h guard survived v3 hardening" >&2\n    exit 2\nfi\nif grep -Fq \'libwivrn-server-library.a\' "$v3"; then\n    echo "error: stale nonexistent server archive assumption survived v3 hardening" >&2\n    exit 2\nfi\n\nexec bash "$v3"\n',1)
p.write_text(s)
PY
bash -n "$v3"
if grep -Fq 'libwivrn-server-library.a' "$v3"; then echo "error: v3 still contains invalid server archive assumption" >&2; exit 2; fi
exec bash "$v3"
