#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="6e23563ec49c6ab8a5e76860b2497b5722c3f591"
TRANSFORM_COMMIT="d792e25c40d0ca91b3096452a18b9cf9ef17ed69"
TRANSFORM_PATH="tools/helix-apply-encoded-sustained-torture-v1.py"
SOURCE_BRANCH="helix-encoded-sustained-torture-v1-built"
VERSION_PREFIX="helix-encoded-sustained-torture-v1"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 clang-format cmake ninja realpath grep find sha256sum java awk cp; do
    command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"
done
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

out="$HOME/helix-encoded-sustained-torture-v1-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
printf 'source_base=%s\ntransform_commit=%s\ntransform_path=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "$SOURCE_BASE" "$TRANSFORM_COMMIT" "$TRANSFORM_PATH" "$SOURCE_BRANCH" "$(git rev-parse HEAD)" >"$out/metadata.txt"

transform="$out/helix-apply-encoded-sustained-torture-v1.py"
git show "${TRANSFORM_COMMIT}:${TRANSFORM_PATH}" >"$transform"
[[ -s "$transform" ]] || fail "transform artifact empty"
python3 -m py_compile "$transform"
sha256sum "$transform" | tee "$out/transform.sha256"

worktree="$out/worktree"
git worktree add --detach "$worktree" "$SOURCE_BASE" >/dev/null
cd "$worktree"
[[ "$(git rev-parse HEAD)" == "$SOURCE_BASE" ]] || fail "wrong isolated source base"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source base dirty"

echo '[1/7] Applying sustained encoded torture transform'
python3 "$transform" | tee "$out/transform.txt"

echo '[2/7] Formatting and semantic source audit'
clang-format -i -style=file server/encoder/video_encoder.cpp
clang-format --dry-run --Werror server/encoder/video_encoder.cpp
git diff --check
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 1 ]] || fail "expected exactly one changed source file"
[[ "${changed[0]}" == "server/encoder/video_encoder.cpp" ]] || fail "unexpected changed source file: ${changed[*]}"

grep -Fq 'HELIX_ENCODED_TORTURE_CYCLES' server/encoder/video_encoder.cpp || fail "cycles env setting missing"
grep -Fq 'HELIX_ENCODED_TORTURE_SPACING_FRAMES' server/encoder/video_encoder.cpp || fail "spacing env setting missing"
grep -Fq 'next_case < helix_encoded_torture_cycles() * 3u' server/encoder/video_encoder.cpp || fail "sustained injection cap missing"
grep -Fq 'switch (helix_encoded_torture.next_case % 3u)' server/encoder/video_encoder.cpp || fail "3-case cycling missing"
grep -Fq 'helix_encoded_torture.last_injected_frame + helix_encoded_torture_spacing_frames()' server/encoder/video_encoder.cpp || fail "configurable spacing missing"
grep -Fq 'candidate == helix_encoded_case::rtx8 ? 8 : candidate == helix_encoded_case::gap9 ? 9' server/encoder/video_encoder.cpp || fail "drop semantics changed"
grep -Fq 'record.recovery_frame <= record.frame || record.recovery_frame - record.frame > 3' server/encoder/video_encoder.cpp || fail "fresh recovery semantics changed"
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d\n' server/helix_synthetic_transport.cpp || fail "promotion oracle marker lost"
git diff >"$out/source.diff"
git diff --stat | tee "$out/source-stat.txt"

echo '[3/7] Committing exact patched source before compilation'
git add server/encoder/video_encoder.cpp
git commit -m 'Helix: add opt-in repeated encoded torture cycles' | tee "$out/commit.txt"
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
encoder_obj="$(find build-everything -type f -name 'video_encoder.cpp.o' -print -quit)"
[[ -s "$encoder_obj" ]] || fail "video encoder object missing"
ninja -C build-everything -t query server/wivrn-server >"$out/ninja-server.txt"
ninja -C build-everything -t commands server/wivrn-server >"$out/ninja-server-commands.txt"
grep -Fq 'video_encoder.cpp.o' "$out/ninja-server.txt" || fail "server dependency graph lacks video encoder object"
grep -Fq 'video_encoder.cpp.o' "$out/ninja-server-commands.txt" || fail "server command graph lacks video encoder object"
server_sha="$(sha256sum "$server" | awk '{print $1}')"
printf '%s  %s\n' "$server_sha" "$server" | tee "$out/server.sha256"
printf 'server=%s\nopenxr_manifest=%s\nserver_sha256=%s\nserver_provenance=PASS exact-patched-commit-direct-link\n' \
    "$server" "$manifest" "$server_sha" | tee -a "$out/metadata.txt"

echo '[5/7] Building matching Quest APK'
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version_name" -Pwivrn_app_name='Helix Encoded Sustained Torture v1' 2>&1 | tee "$out/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK"
apk="$out/helix-encoded-sustained-torture-v1-${source_commit:0:12}.apk"
cp "$(realpath "${apks[0]}")" "$apk"
apk_sha="$(sha256sum "$apk" | awk '{print $1}')"
printf '%s  %s\n' "$apk_sha" "$apk" | tee "$out/apk.sha256"
printf 'apk=%s\napk_sha256=%s\n' "$apk" "$apk_sha" | tee -a "$out/metadata.txt"

echo '[6/7] Publishing only the exact fully-built source checkpoint'
git push origin "HEAD:refs/heads/${SOURCE_BRANCH}" 2>&1 | tee "$out/push.txt"
remote_head="$(git ls-remote origin "refs/heads/${SOURCE_BRANCH}" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || fail "remote source branch does not point to built commit"
printf 'remote_head=%s\n' "$remote_head" | tee -a "$out/metadata.txt"

echo '[7/7] Final artifact gate'
printf 'artifact_gate=PASS encoded-sustained-torture-v1-server-apk-exact-source\n' | tee -a "$out/metadata.txt"
printf '\nENCODED_SUSTAINED_TORTURE_BUILD=PASS\n'
printf 'commit=%s\nbranch=%s\nout=%s\nserver=%s\nserver_sha256=%s\napk=%s\napk_sha256=%s\n' \
    "$source_commit" "$SOURCE_BRANCH" "$out" "$server" "$server_sha" "$apk" "$apk_sha"
