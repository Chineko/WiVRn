#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "${repo_root}"

v1_commit="8425938797e311e33781d264869a0e92180dda32"
v1_path="tools/helix-build-encoded-nvenc-torture-isolated.sh"

for cmd in git python3 bash; do
    command -v "$cmd" >/dev/null 2>&1 || { echo "error: missing command $cmd" >&2; exit 2; }
done

git cat-file -e "${v1_commit}^{commit}" 2>/dev/null || git fetch origin "$v1_commit"
git cat-file -e "${v1_commit}^{commit}" 2>/dev/null || { echo "error: pinned v1 tooling commit unavailable" >&2; exit 2; }

tmp="$(mktemp -d /tmp/helix-encoded-build-v2.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT INT TERM
v1="$tmp/v1.sh"
v2="$tmp/v2.sh"
git show "${v1_commit}:${v1_path}" >"$v1"
cp "$v1" "$v2"

python3 - "$v2" <<'PY'
from pathlib import Path
import sys

p = Path(sys.argv[1])
s = p.read_text()

def replace_once(old, new, label):
    global s
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"error: {label} anchor count={n}")
    s = s.replace(old, new, 1)

replace_once(
'''for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum c++ dlopen true; do
    if [[ "${cmd}" == dlopen || "${cmd}" == true ]]; then continue; fi
''',
'''for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum c++; do
''',
"tool list")

replace_once(
'''#include <chrono>
#include <cstdio>
#include <cstring>
#include <string>
#include <thread>
#include <vector>
''',
'''#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <type_traits>
#include <vector>
''',
"headless standard headers")

replace_once(
'''    std::vector<XrExtensionProperties> exts(ext_count, {XR_TYPE_EXTENSION_PROPERTIES});
    if (XR_FAILED(enumerate_ext(nullptr, ext_count, &ext_count, exts.data()))) die("enumerate_ext_values");
''',
'''    std::vector<XrExtensionProperties> exts(ext_count);
    for (auto & ext : exts) ext.type = XR_TYPE_EXTENSION_PROPERTIES;
    if (XR_FAILED(enumerate_ext(nullptr, ext_count, &ext_count, exts.data()))) die("enumerate_ext_values");
''',
"extension vector initialization")

replace_once(
'''    std::strncpy(ici.applicationInfo.applicationName, "Helix Headless Driver", XR_MAX_APPLICATION_NAME_SIZE - 1);
    ici.applicationInfo.applicationVersion = 1;
    std::strncpy(ici.applicationInfo.engineName, "Helix", XR_MAX_ENGINE_NAME_SIZE - 1);
''',
'''    std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "%s", "Helix Headless Driver");
    ici.applicationInfo.applicationVersion = 1;
    std::snprintf(ici.applicationInfo.engineName, XR_MAX_ENGINE_NAME_SIZE, "%s", "Helix");
''',
"headless application strings")

replace_once(
'''config_header="$(find build-everything -type f -name wivrn_config.h -print -quit)"
[[ -n "$config_header" ]] || { echo "error: generated wivrn_config.h missing" >&2; exit 2; }
grep -Eq '#define[[:space:]]+WIVRN_USE_NVENC[[:space:]]+1' "$config_header" || { echo "error: exact build does not enable NVENC" >&2; exit 2; }
''',
'''nvenc_obj="$(find build-everything -type f -name 'video_encoder_nvenc.cpp.o' -print -quit)"
[[ -n "$nvenc_obj" && -s "$nvenc_obj" ]] || { echo "error: exact build did not compile video_encoder_nvenc.cpp.o" >&2; exit 2; }
base_encoder_obj="$(find build-everything -type f -name 'video_encoder.cpp.o' -print -quit)"
[[ -n "$base_encoder_obj" && -s "$base_encoder_obj" ]] || { echo "error: exact build did not compile video_encoder.cpp.o" >&2; exit 2; }
''',
"NVENC build guard")

replace_once(
'''ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
grep -Fq 'video_encoder.cpp.o' "${out}/ninja-server.txt" || { echo "error: final server graph lacks base encoder object" >&2; exit 2; }
grep -Fq 'video_encoder_nvenc.cpp.o' "${out}/ninja-server.txt" || { echo "error: final server graph lacks NVENC object" >&2; exit 2; }
server="$(realpath build-everything/server/wivrn-server)"
''',
'''server_archive="$(find build-everything -type f -name 'libwivrn-server-library.a' -print -quit)"
[[ -n "$server_archive" && -s "$server_archive" ]] || { echo "error: wivrn server library archive missing" >&2; exit 2; }
ar t "$server_archive" >"${out}/server-archive-members.txt"
grep -Fq 'video_encoder.cpp.o' "${out}/server-archive-members.txt" || { echo "error: server archive lacks base encoder object" >&2; exit 2; }
grep -Fq 'video_encoder_nvenc.cpp.o' "${out}/server-archive-members.txt" || { echo "error: server archive lacks NVENC object" >&2; exit 2; }
nvenc_obj_rel="${nvenc_obj#build-everything/}"
ninja -C build-everything -t query "$nvenc_obj_rel" >"${out}/ninja-nvenc-object.txt"
ninja -C build-everything -t query server/wivrn-server >"${out}/ninja-server.txt"
grep -Fq 'libwivrn-server-library.a' "${out}/ninja-server.txt" || { echo "error: final server graph lacks server library archive" >&2; exit 2; }
server="$(realpath build-everything/server/wivrn-server)"
''',
"server build graph proof")

replace_once(
'''openxr_header="$(find build-everything/_deps -type f -path '*/openxr/openxr.h' -print -quit)"
[[ -n "$openxr_header" ]] || { echo "error: OpenXR headers not found in configured dependency tree" >&2; exit 2; }
openxr_include="$(dirname "$(dirname "$openxr_header")")"
''',
'''openxr_header=""
for root in /usr/include build-everything .; do
    [[ -e "$root" ]] || continue
    candidate="$(find "$root" -type f -path '*/openxr/openxr.h' -print -quit 2>/dev/null || true)"
    if [[ -n "$candidate" ]]; then
        openxr_header="$candidate"
        break
    fi
done
[[ -n "$openxr_header" ]] || { echo "error: OpenXR headers not found in system/configured/source trees" >&2; exit 2; }
openxr_include="$(dirname "$(dirname "$openxr_header")")"
''',
"OpenXR header discovery")

# Add static self-audit markers after the v1 source markers are checked.
needle = '''grep -Fq 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old replay not disabled" >&2; exit 2; }
'''
replacement = needle + '''grep -Fq 'dynamic_cast<default_idr_handler *>' server/encoder/video_encoder.cpp || { echo "error: reference-P selection missing" >&2; exit 2; }
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 10' server/encoder/video_encoder.cpp || { echo "error: RTX8 drop window missing" >&2; exit 2; }
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 11' server/encoder/video_encoder.cpp || { echo "error: GAP9 drop window missing" >&2; exit 2; }
grep -Fq 'helix_drop = !control;' server/encoder/video_encoder.cpp || { echo "error: full reference-frame drop missing" >&2; exit 2; }
'''
replace_once(needle, replacement, "encoded source invariants")

p.write_text(s)
PY

# Whole-script static gate: syntax plus required hardened markers.
bash -n "$v2"
for marker in \
    '#include <cstdlib>' \
    '#include <type_traits>' \
    "video_encoder_nvenc.cpp.o" \
    "libwivrn-server-library.a" \
    'XR_MND_headless' \
    'HELIX_ENCODED_TORTURE_SUMMARY' \
    'HELIX_ENCODED_INVALIDATION'; do
    grep -Fq -- "$marker" "$v2" || { echo "error: hardened build-script marker missing: $marker" >&2; exit 2; }
done
if grep -Fq 'wivrn_config.h' "$v2"; then
    echo "error: stale guessed wivrn_config.h guard survived v2 hardening" >&2
    exit 2
fi

exec bash "$v2"
