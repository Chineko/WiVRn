#!/usr/bin/env bash
set -euo pipefail

SOURCE_BASE="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"
TRANSFORM_COMMIT="9299588c3080ed06d54ee39bc9b1e9d45b6bc638"
TRANSFORM_PATH="tools/helix-apply-synthetic-network-promotion-v1.py"
SOURCE_BRANCH="helix-synthetic-network-promotion-v1-built"
VERSION_PREFIX="helix-synthetic-network-promotion-v1"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 clang-format cmake ninja realpath grep find sha256sum java; do command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"

# Repository rules are intentionally not modified by this builder. No PR/issue actions.
git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || git fetch origin "$SOURCE_BASE"
git cat-file -e "${TRANSFORM_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$TRANSFORM_COMMIT"
git cat-file -e "${SOURCE_BASE}^{commit}" 2>/dev/null || fail "source base unavailable"
git cat-file -e "${TRANSFORM_COMMIT}^{commit}" 2>/dev/null || fail "transform commit unavailable"
if git ls-remote --exit-code --heads origin "$SOURCE_BRANCH" >/dev/null 2>&1; then
    fail "origin/$SOURCE_BRANCH already exists; classify existing state before rebuilding"
fi

out="$HOME/helix-synthetic-network-promotion-v1-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$out"
printf 'source_base=%s\ntransform_commit=%s\ntransform_path=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "$SOURCE_BASE" "$TRANSFORM_COMMIT" "$TRANSFORM_PATH" "$SOURCE_BRANCH" "$(git rev-parse HEAD)" >"$out/metadata.txt"

transform="$out/helix-apply-synthetic-network-promotion-v1.py"
git show "${TRANSFORM_COMMIT}:${TRANSFORM_PATH}" >"$transform"
[[ -s "$transform" ]] || fail "transform artifact empty"
python3 -m py_compile "$transform"
sha256sum "$transform" | tee "$out/transform.sha256"

worktree="$out/worktree"
git worktree add --detach "$worktree" "$SOURCE_BASE" >/dev/null
cd "$worktree"
[[ "$(git rev-parse HEAD)" == "$SOURCE_BASE" ]] || fail "wrong isolated source base"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source base dirty"

echo '[1/7] Applying deterministic oracle sanity marker fix'
python3 "$transform" | tee "$out/transform.txt"

echo '[2/7] Formatting and semantic source audit'
clang-format -i -style=file server/helix_synthetic_transport.cpp
clang-format --dry-run --Werror server/helix_synthetic_transport.cpp
git diff --check
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 1 ]] || fail "expected exactly one changed source file"
[[ "${changed[0]}" == "server/helix_synthetic_transport.cpp" ]] || fail "unexpected changed source file: ${changed[*]}"

grep -Fq 'U_LOG_I("HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d", oracle_ok);' server/helix_synthetic_transport.cpp || fail "existing logger sanity marker lost"
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY pass=%d\n' server/helix_synthetic_transport.cpp || fail "deterministic stderr sanity marker missing"
grep -Fq 'oracle_ok);' server/helix_synthetic_transport.cpp || fail "oracle stderr value binding missing"
grep -Fq 'std::fflush(stderr);' server/helix_synthetic_transport.cpp || fail "stderr flush missing"
grep -Fq 'if (!oracle_ok)' server/helix_synthetic_transport.cpp || fail "oracle fail gate missing"
grep -Fq 'return 2;' server/helix_synthetic_transport.cpp || fail "oracle fail return missing"
grep -Fq 'constexpr double promotion_threshold = 0.95;' server/helix_synthetic_transport.cpp || fail "95 percent gate missing"
grep -Fq 's.catastrophic == 0' server/helix_synthetic_transport.cpp || fail "catastrophic zero gate missing"
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_RESULT' server/helix_synthetic_transport.cpp || fail "result marker missing"
git diff >"$out/source.diff"
git diff --stat | tee "$out/source-stat.txt"

echo '[3/7] Committing exact patched source before compilation'
git add server/helix_synthetic_transport.cpp
git commit -m 'Helix: make synthetic transport oracle sanity marker deterministic' | tee "$out/commit.txt"
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
synthetic_obj="$(find build-everything -type f -name 'helix_synthetic_transport.cpp.o' -print -quit)"
[[ -s "$synthetic_obj" ]] || fail "synthetic transport object missing"
ninja -C build-everything -t query server/wivrn-server >"$out/ninja-server.txt"
ninja -C build-everything -t commands server/wivrn-server >"$out/ninja-server-commands.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "$out/ninja-server.txt" || fail "server dependency graph lacks synthetic transport object"
grep -Fq 'helix_synthetic_transport.cpp.o' "$out/ninja-server-commands.txt" || fail "server command graph lacks synthetic transport object"
sha256sum "$server" | tee "$out/server.sha256"
printf 'server=%s\nopenxr_manifest=%s\nserver_provenance=PASS exact-patched-commit-direct-link\n' "$server" "$manifest" | tee -a "$out/metadata.txt"

echo '[5/7] Building matching Quest APK'
./gradlew --no-daemon assembleDebug -Pwivrn_version="$version_name" -Pwivrn_app_name='Helix Synthetic Network Promotion v1' 2>&1 | tee "$out/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ ${#apks[@]} -eq 1 ]] || fail "expected exactly one debug APK"
apk="$out/helix-synthetic-network-promotion-v1-${source_commit:0:12}.apk"
cp "$(realpath "${apks[0]}")" "$apk"
sha256sum "$apk" | tee "$out/apk.sha256"
printf 'apk=%s\n' "$apk" | tee -a "$out/metadata.txt"

echo '[6/7] Publishing only the exact fully-built source checkpoint'
git push origin "HEAD:refs/heads/${SOURCE_BRANCH}" 2>&1 | tee "$out/push.txt"
remote_head="$(git ls-remote origin "refs/heads/${SOURCE_BRANCH}" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || fail "remote source branch does not point to built commit"
printf 'remote_head=%s\n' "$remote_head" | tee -a "$out/metadata.txt"

echo '[7/7] Final artifact gate'
printf 'artifact_gate=PASS synthetic-network-promotion-v1-server-apk-exact-source\n' | tee -a "$out/metadata.txt"
printf '\nSYNTHETIC_NETWORK_PROMOTION_BUILD=PASS\n'
printf 'commit=%s\nbranch=%s\nout=%s\nserver=%s\napk=%s\n' "$source_commit" "$SOURCE_BRANCH" "$out" "$server" "$apk"
