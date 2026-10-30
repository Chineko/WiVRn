#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="5568963b538eaae708b9f957a9a3c162ddaf5de4"
PATCH_COMMIT="b713db9d72927a99eca8070a4c1fa43d47220940"
PATCH_PATH="tools/helix-encoded-nvenc-torture-fix-v2.patch"
SOURCE_BRANCH="helix-encoded-nvenc-torture-fix-v2-built"
VERSION_PREFIX="helix-encoded-fix-v2"

fail(){ echo "error: $*" >&2; exit 2; }
for c in git clang-format cmake ninja realpath grep find sha256sum java; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"

git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || git fetch origin "$SOURCE_BASE"
git cat-file -e "${PATCH_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$PATCH_COMMIT"
git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || fail "source base unavailable"
git cat-file -e "${PATCH_COMMIT}^{commit}" 2>/dev/null || fail "patch commit unavailable"
if git ls-remote --exit-code --heads origin "$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail "origin/$SOURCE_BRANCH already exists; classify existing state before rebuilding"
fi

out="$HOME/helix-encoded-nvenc-fix-v2-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
printf 'source_base=%s\npatch_commit=%s\npatch_path=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "$SOURCE_BASE" "$PATCH_COMMIT" "$PATCH_PATH" "$SOURCE_BRANCH" "$(git rev-parse HEAD)" >"$out/metadata.txt"

patch="$out/helix-encoded-nvenc-torture-fix-v2.patch"
git show "${PATCH_COMMIT}:${PATCH_PATH}" >"$patch"
[[ -s "$patch" ]] || fail "patch artifact empty"
sha256sum "$patch" | tee "$out/patch.sha256"

worktree="$out/worktree"
git worktree add --detach "$worktree" "$SOURCE_BASE" >/dev/null
cd "$worktree"
[[ "$(git rev-parse HEAD)" == "$SOURCE_BASE" ]] || fail "wrong isolated source base"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source base dirty"

echo '[1/7] Checking and applying exact torture fix patch'
git apply --check "$patch"
git apply "$patch"

echo '[2/7] Formatting and source-scope audit'
clang-format -i -style=file server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
clang-format --dry-run --Werror server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
git diff --check
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 2 ]] || fail "expected exactly two changed source files"
[[ " ${changed[*]} " == *" server/encoder/video_encoder.cpp "* ]] || fail "video_encoder.cpp not changed"
[[ " ${changed[*]} " == *" server/encoder/video_encoder_nvenc.cpp "* ]] || fail "video_encoder_nvenc.cpp not changed"

grep -Fq 'helix_force_torture_fragmentation' server/encoder/video_encoder.cpp || fail "forced torture fragmentation missing"
grep -Fq 'encoded_case == helix_encoded_case::rtx8 || encoded_case == helix_encoded_case::gap9' server/encoder/video_encoder.cpp || fail "partial-loss fragmentation scope missing"
grep -Fq 'helix_encoded_note_feedback_for_nvenc(feedback);' server/encoder/video_encoder_nvenc.cpp || fail "NVENC pre-return torture observation missing"
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 10' server/encoder/video_encoder.cpp || fail "rtx8 exact drop window lost"
grep -Fq 'shard.shard_idx >= 2 && shard.shard_idx < 11' server/encoder/video_encoder.cpp || fail "gap9 exact drop window lost"
grep -Fq 'HELIX_ENCODED_TORTURE_SUMMARY' server/encoder/video_encoder.cpp || fail "strict torture summary lost"
grep -Fq 'HELIX_ENCODED_INVALIDATION' server/encoder/video_encoder_nvenc.cpp || fail "NVENC invalidation evidence lost"
git diff >"$out/source.diff"
git diff --stat | tee "$out/source-stat.txt"

echo '[3/7] Committing exact patched source before compilation'
git add server/encoder/video_encoder.cpp server/encoder/video_encoder_nvenc.cpp
git commit -m 'Helix: make encoded NVENC torture transport-independent' | tee "$out/commit.txt"
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
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version_name" -Pwivrn_app_name='Helix Encoded NVENC Torture Fix v2' 2>&1 | tee "$out/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK"
apk="$out/helix-encoded-nvenc-fix-v2-${source_commit:0:12}.apk"
cp "$(realpath "${apks[0]}")" "$apk"
sha256sum "$apk" | tee "$out/apk.sha256"
printf 'apk=%s\n' "$apk" | tee -a "$out/metadata.txt"

echo '[6/7] Publishing only the exact fully-built source checkpoint'
git push origin "HEAD:refs/heads/${SOURCE_BRANCH}" 2>&1 | tee "$out/push.txt"
remote_head="$(git ls-remote origin "refs/heads/${SOURCE_BRANCH}" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || fail "remote source branch does not point to built commit"
printf 'remote_head=%s\n' "$remote_head" | tee -a "$out/metadata.txt"

echo '[7/7] Final artifact gate'
printf 'artifact_gate=PASS encoded-nvenc-fix-v2-server-apk-exact-source\n' | tee -a "$out/metadata.txt"
printf '\nPASS: patched encoded NVENC torture source, server, and matching APK built and published.\n'
printf 'commit=%s\nbranch=%s\nout=%s\nserver=%s\napk=%s\n' "$source_commit" "$SOURCE_BRANCH" "$out" "$server" "$apk"
