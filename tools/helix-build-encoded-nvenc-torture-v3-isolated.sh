#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "$repo_root"

v2_commit="0d892020aa92ad3252c7fab0752d5b833315600b"
v2_path="tools/helix-build-encoded-nvenc-torture-v2-isolated.sh"
for cmd in git python3 bash; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing command $cmd" >&2; exit 2; }
done

git cat-file -e "${v2_commit}^{commit}" 2>/dev/null || git fetch origin "$v2_commit"
git cat-file -e "${v2_commit}^{commit}" 2>/dev/null || { echo "error: pinned v2 tooling commit unavailable" >&2; exit 2; }

tmp="$(mktemp -d /tmp/helix-encoded-build-v3.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT INT TERM
v2="$tmp/v2.sh"
v3="$tmp/v3.sh"
git show "${v2_commit}:${v2_path}" >"$v2"
cp "$v2" "$v3"

python3 - "$v3" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

old = '''server_archive="$(find build-everything -type f -name 'libwivrn-server-library.a' -print -quit)"
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
new = '''nvenc_obj_rel="${nvenc_obj#build-everything/}"
ninja -C build-everything -t query "$nvenc_obj_rel" >"${out}/ninja-nvenc-object.txt"
ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
ninja -C build-everything -t commands server/wivrn-server >"${out}/ninja-server-commands.txt"
for obj in 'video_encoder.cpp.o' 'video_encoder_nvenc.cpp.o'; do
    grep -Fq "$obj" "${out}/ninja-server.txt" || { echo "error: final server dependency graph lacks $obj" >&2; exit 2; }
    grep -Fq "$obj" "${out}/ninja-server-commands.txt" || { echo "error: final server command graph lacks $obj" >&2; exit 2; }
done
server="$(realpath build-everything/server/wivrn-server)"
'''
count = s.count(old)
if count != 1:
    raise SystemExit(f"error: direct-link provenance anchor count={count}")
s = s.replace(old, new, 1)

old_marker = '''    "video_encoder_nvenc.cpp.o" \\
    "libwivrn-server-library.a" \\
    'XR_MND_headless' \\
'''
new_marker = '''    "video_encoder_nvenc.cpp.o" \\
    'ninja-server-commands.txt' \\
    'XR_MND_headless' \\
'''
count = s.count(old_marker)
if count != 1:
    raise SystemExit(f"error: static marker anchor count={count}")
s = s.replace(old_marker, new_marker, 1)

# The final generated build script must no longer assert the nonexistent archive.
# Keep v2 wrapper execution semantics unchanged; only its generated script is hardened.
p.write_text(s)
PY

bash -n "$v3"
grep -Fq "ninja -C build-everything -t commands server/wivrn-server" "$v3" || {
    echo "error: v3 direct executable command-graph proof missing" >&2; exit 2;
}
grep -Fq "final server dependency graph lacks" "$v3" || {
    echo "error: v3 dependency-graph guard missing" >&2; exit 2;
}

exec bash "$v3"
