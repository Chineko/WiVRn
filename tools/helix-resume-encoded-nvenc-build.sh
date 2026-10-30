#!/usr/bin/env bash
set -euo pipefail

worktree="${1:-$HOME/helix-encoded-nvenc-build-20261030-160211/worktree}"
base="a97cf8add2c0e90954b45523dca3346fbb40e93d"
branch="helix-encoded-nvenc-torture"
tooling="8425938797e311e33781d264869a0e92180dda32"
[[ -e "$worktree/.git" ]] || { echo "error: missing worktree $worktree" >&2; exit 2; }
worktree="$(realpath "$worktree")"; out="$(dirname "$worktree")"; cd "$worktree"
head="$(git rev-parse HEAD)"; version="helix-encoded-$head"

git merge-base --is-ancestor "$base" "$head"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || { echo "error: tracked tree dirty" >&2; exit 2; }
mapfile -t changed < <(git diff --name-only "$base..$head")
[[ ${#changed[@]} -eq 2 && " ${changed[*]} " == *" server/encoder/video_encoder.cpp "* && " ${changed[*]} " == *" server/encoder/video_encoder_nvenc.cpp "* ]] || { echo "error: unexpected source scope" >&2; printf '%s\n' "${changed[@]}" >&2; exit 2; }
for m in HELIX_ENCODED_INJECT HELIX_ENCODED_FEEDBACK HELIX_ENCODED_RECOVERY HELIX_ENCODED_TORTURE_SUMMARY; do grep -Fq "$m" server/encoder/video_encoder.cpp; done
for m in HELIX_ENCODED_NVENC_CAP HELIX_ENCODED_INVALIDATION 'inputTimeStamp = frame_index' 'helix_drain_reference_invalidations();'; do grep -Fq "$m" server/encoder/video_encoder_nvenc.cpp; done

echo '[1/5] Re-verifying already-built desktop provenance'
grep -Fq "const char git_commit[] = \"$head\";" build-everything/version.cpp
ninja -C build-everything -t query server/wivrn-server >"$out/resume-ninja-query.txt"
ninja -C build-everything -t commands server/wivrn-server >"$out/resume-ninja-commands.txt"
for obj in video_encoder.cpp.o video_encoder_nvenc.cpp.o; do grep -Fq "$obj" "$out/resume-ninja-query.txt"; grep -Fq "$obj" "$out/resume-ninja-commands.txt"; done
server="$(realpath build-everything/server/wivrn-server)"; dashboard="$(realpath build-everything/server/wivrn-dashboard)"; manifest="$(realpath build-everything/openxr_wivrn-dev.json)"
[[ -x "$server" && -x "$dashboard" && -s "$manifest" ]]

echo '[2/5] Building matching Quest APK only'
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version" -Pwivrn_app_name='Helix Encoded NVENC Torture' | tee "$out/resume-gradle.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]]
apk="$out/helix-encoded-nvenc-${head:0:12}.apk"; cp "$(realpath "${apks[0]}")" "$apk"; sha256sum "$apk" | tee "$out/resume-apk.sha256"

echo '[3/5] Building corrected headless OpenXR driver only'
script="$out/original-encoded-build.sh"; git show "$tooling:tools/helix-build-encoded-nvenc-torture-isolated.sh" >"$script"
python3 - "$script" "$out/helix_headless_driver.cpp" <<'PY'
from pathlib import Path
import sys,re
s=Path(sys.argv[1]).read_text()
m=re.search(r"cat >\"\$\{out\}/helix_headless_driver\.cpp\" <<'CPP'\n(.*?)\nCPP\n",s,re.S)
if not m: raise SystemExit('error: headless source block not found')
c=m.group(1)
c=c.replace('#include <cstdio>\n', '#include <cstdio>\n#include <cstdlib>\n')
c=c.replace('#include <thread>\n', '#include <thread>\n#include <type_traits>\n')
c=c.replace('std::vector<XrExtensionProperties> exts(ext_count, {XR_TYPE_EXTENSION_PROPERTIES});', 'std::vector<XrExtensionProperties> exts(ext_count);\n    for (auto & ext : exts) ext.type = XR_TYPE_EXTENSION_PROPERTIES;')
c=c.replace('std::strncpy(ici.applicationInfo.applicationName, "Helix Headless Driver", XR_MAX_APPLICATION_NAME_SIZE - 1);', 'std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "%s", "Helix Headless Driver");')
c=c.replace('std::strncpy(ici.applicationInfo.engineName, "Helix", XR_MAX_ENGINE_NAME_SIZE - 1);', 'std::snprintf(ici.applicationInfo.engineName, XR_MAX_ENGINE_NAME_SIZE, "%s", "Helix");')

# OpenXR headers intentionally expose C aggregate structs. Under -Werror,
# both declarations (XrFoo x{XR_TYPE_*}) and reassignments
# (x = {XR_TYPE_*}) trigger -Wmissing-field-initializers in C++.
# Zero the whole object and assign .type explicitly in both forms.
decl_pat=re.compile(r'(?m)^(\s*)(Xr[A-Za-z0-9_]+)\s+([A-Za-z_][A-Za-z0-9_]*)\{(XR_TYPE_[A-Z0-9_]+)\};$')
def decl_repl(m):
    indent, typ, var, xrtype = m.groups()
    return f'{indent}{typ} {var}{{}};\n{indent}{var}.type = {xrtype};'
c,decl_n=decl_pat.subn(decl_repl,c)
if decl_n < 8:
    raise SystemExit(f'error: expected to rewrite OpenXR declaration initializers, got {decl_n}')

assign_pat=re.compile(r'(?m)^(\s*)([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{(XR_TYPE_[A-Z0-9_]+)\};$')
def assign_repl(m):
    indent, var, xrtype = m.groups()
    return f'{indent}{var} = {{}};\n{indent}{var}.type = {xrtype};'
c,assign_n=assign_pat.subn(assign_repl,c)
if assign_n < 2:
    raise SystemExit(f'error: expected to rewrite OpenXR reassignment initializers, got {assign_n}')

# Whole generated-source guard: no warning-prone XR_TYPE aggregate form may survive.
if re.search(r'(?m)^\s*Xr[A-Za-z0-9_]+\s+[A-Za-z_][A-Za-z0-9_]*\s*\{XR_TYPE_[A-Z0-9_]+\};\s*$', c):
    raise SystemExit('error: stale OpenXR declaration aggregate initializer remains')
if re.search(r'(?m)^\s*[A-Za-z_][A-Za-z0-9_]*\s*=\s*\{XR_TYPE_[A-Z0-9_]+\};\s*$', c):
    raise SystemExit('error: stale OpenXR reassignment aggregate initializer remains')
Path(sys.argv[2]).write_text(c)
PY
hdr=""; for root in /usr/include build-everything .; do [[ -e "$root" ]] || continue; hdr="$(find "$root" -type f -path '*/openxr/openxr.h' -print -quit 2>/dev/null || true)"; [[ -n "$hdr" ]] && break; done
[[ -n "$hdr" ]]; inc="$(dirname "$(dirname "$hdr")")"
c++ -std=c++20 -O2 -Wall -Wextra -Werror -I"$inc" "$out/helix_headless_driver.cpp" -ldl -o "$out/helix-headless-driver"
[[ -x "$out/helix-headless-driver" ]]

echo '[4/5] Publishing exact already-compiled source commit'
remote="$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')"
[[ -z "$remote" || "$remote" == "$head" ]] || { echo "error: remote branch points elsewhere: $remote" >&2; exit 2; }
[[ -n "$remote" ]] || git push origin "HEAD:refs/heads/$branch"
remote="$(git ls-remote origin "refs/heads/$branch" | awk '{print $1}')"; [[ "$remote" == "$head" ]]

echo '[5/5] Final salvage gate'
cat >"$out/resume-metadata.txt" <<EOF
source_commit=$head
branch=$branch
server=$server
dashboard=$dashboard
openxr_manifest=$manifest
apk=$apk
headless_driver=$out/helix-headless-driver
provenance=PASS direct-executable-build-graph
artifact_gate=PASS salvaged-existing-desktop-plus-apk-headless
EOF
printf '\nPASS: verifier/headless harness failure classes closed; exact compiled source published and missing artifacts built.\ncommit=%s\nbranch=%s\napk=%s\nheadless_driver=%s\nevidence=%s\nSTATUS: built only; not installed and encoded runtime not executed.\n' "$head" "$branch" "$apk" "$out/helix-headless-driver" "$out"
