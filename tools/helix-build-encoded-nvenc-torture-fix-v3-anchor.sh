#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="22fb078d1e294a04c20fe9ba512b63d39d4e9f45"
TRANSFORM_COMMIT="cb6394ad270f87c378b691d4d5c3383fec965be6"
TRANSFORM_PATH="tools/helix-apply-encoded-nvenc-torture-fix-v3.py"
SOURCE_BRANCH="helix-encoded-nvenc-torture-fix-v3-built"
VERSION_PREFIX="helix-encoded-fix-v3"

fail(){ echo "error: $*" >&2; exit 2; }
for c in git python3 clang-format cmake ninja realpath grep find sha256sum java; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"

git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || git fetch origin "$SOURCE_BASE"
git cat-file -e "${TRANSFORM_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$TRANSFORM_COMMIT"
git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || fail "source base unavailable"
git cat-file -e "${TRANSFORM_COMMIT}^{commit}" 2>/dev/null || fail "transform commit unavailable"
if git ls-remote --exit-code --heads origin "$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail "origin/$SOURCE_BRANCH already exists; classify existing state before rebuilding"
fi

out="$HOME/helix-encoded-nvenc-fix-v3-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
printf 'source_base=%s\ntransform_commit=%s\ntransform_path=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "$SOURCE_BASE" "$TRANSFORM_COMMIT" "$TRANSFORM_PATH" "$SOURCE_BRANCH" "$(git rev-parse HEAD)" >"$out/metadata.txt"

transform="$out/helix-apply-encoded-nvenc-torture-fix-v3.py"
git show "${TRANSFORM_COMMIT}:${TRANSFORM_PATH}" >"$transform"
[[ -s "$transform" ]] || fail "transformer artifact empty"
sha256sum "$transform" | tee "$out/transform.sha256"

worktree="$out/worktree"
git worktree add --detach "$worktree" "$SOURCE_BASE" >/dev/null
cd "$worktree"
[[ "$(git rev-parse HEAD)" == "$SOURCE_BASE" ]] || fail "wrong isolated source base"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source base dirty"

echo '[1/7] Applying anchor-checked rtx8 semantics fix'
python3 "$transform"

echo '[2/7] Formatting and source-scope audit'
clang-format -i -style=file server/encoder/video_encoder.cpp
clang-format --dry-run --Werror server/encoder/video_encoder.cpp
git diff --check
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 1 ]] || fail "expected exactly one changed source file"
[[ "${changed[0]}" == "server/encoder/video_encoder.cpp" ]] || fail "unexpected changed source file: ${changed[*]}"

grep -Fq 'else if (!record.incomplete_seen)' server/encoder/video_encoder.cpp || fail "unified incomplete-feedback semantic missing"
grep -Fq 'record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3' server/encoder/video_encoder.cpp || fail "fresh recovery delta semantic missing"
! grep -Fq 'record.scenario == helix_encoded_case::rtx8 && !record.sent_to_decoder' server/encoder/video_encoder.cpp || fail "stale rtx8 same-frame summary requirement remains"
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 10' server/encoder/video_encoder.cpp || fail "rtx8 exact drop window lost"
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 11' server/encoder/video_encoder.cpp || fail "gap9 exact drop window lost"
grep -Fq 'helix_force_torture_fragmentation' server/encoder/video_encoder.cpp || fail "transport-independent fragmentation fix lost"
git diff >"$out/source.diff"
git diff --stat | tee "$out/source-stat.txt"

echo '[3/7] Committing exact patched source before compilation'
git add server/encoder/video_encoder.cpp
git commit -m 'Helix: align rtx8 torture recovery semantics with Quest behavior' | tee "$out/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${VERSION_PREFIX}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "$source_commit" "$version_name" | tee -a "$out/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || fail "source tree dirty after commit"

echo '[4/7] Building runtime-complete desktop artifacts'
cmake --preset everything 2>&1 | tee "$out/configure.txt"
cmake --build build-everything --target wivrn-server wivrn-dashboard openxr_wivrn monado -j 2 2>&1 | tee "$out/build.txt"
server="$(realpath build-everything/server/wivrn-server)"
manifest="$(realpath build-everything/openxr_wivrn-dev.json)"
[[ -s "$server" && -x "$server" && -s "$manifest" ]] || fail "desktop runtime artifact missing"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-everything/version.cpp || fail "generated version.cpp lacks exact patched source commit"
nvenc_obj="$(find build-everything -type f -name 'video_encoder_nvenc.cpp.o' -print -quit)"
base_obj="$(find build-everything -type f -name 'video_encoder.cpp.o' -print -quit)"
[[ -s "$nvenc_obj" && -s "$base_obj" ]] || fail "patched encoder objects missing"
ninja -C build-everything -t query server/wivrn-server >"$out/ninja-server.txt"
ninja -C build-everything -t commands server/wivrn-server >"$out/ninja-server-commands.txt"
for obj in video_encoder.cpp.o video_encoder_nvenc.cpp.o; do
    grep -Fq "$obj" "$out/ninja-server.txt" || fail "server dependency graph lacks $obj"
    grep -Fq "$obj" "$out/ninja-server-commands.txt" || fail "server command graph lacks $obj"
done
sha256sum "$server" | tee "$out/server.sha256"
printf 'server=%s\nopenxr_manifest=%s\nserver_provenance=PASS exact-patched-commit-direct-link\n' "$server" "$manifest" | tee -a "$out/metadata.txt"

echo '[5/7] Building matching Quest APK'
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version_name" -Pwivrn_app_name='Helix Encoded NVENC Torture Fix v3' 2>&1 | tee "$out/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK"
apk="$out/helix-encoded-nvenc-fix-v3-${source_commit:0:12}.apk"
cp "$(realpath "${apks[0]}")" "$apk"
sha256sum "$apk" | tee "$out/apk.sha256"
printf 'apk=%s\n' "$apk" | tee -a "$out/metadata.txt"

echo '[6/7] Publishing only the exact fully-built source checkpoint'
git push origin "HEAD:refs/heads/${SOURCE_BRANCH}" 2>&1 | tee "$out/push.txt"
remote_head="$(git ls-remote origin "refs/heads/${SOURCE_BRANCH}" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || fail "remote source branch does not point to built commit"
printf 'remote_head=%s\n' "$remote_head" | tee -a "$out/metadata.txt"

echo '[7/7] Final artifact gate'
printf 'artifact_gate=PASS encoded-nvenc-fix-v3-server-apk-exact-source\n' | tee -a "$out/metadata.txt"
printf '\nPASS: rtx8 semantics source, server, and matching APK built and published.\n'
printf 'commit=%s\nbranch=%s\nout=%s\nserver=%s\napk=%s\n' "$source_commit" "$SOURCE_BRANCH" "$out" "$server" "$apk"
