#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

branch="helix-quest-synthetic-transport"
policy_commit="cc9e68c09d863ed32559116a0edea2e1caa5ffde"
transformer="tools/helix-apply-quest-synthetic-transport.py"
expected_transformer_blob="f9e4138f812cd97365ca37f7f4215d02dc5c4114"
source_paths=(
    server/main.cpp
    server/CMakeLists.txt
    server/helix_synthetic_transport.cpp
)
format_paths=(
    server/main.cpp
    server/helix_synthetic_transport.cpp
)

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git fetch origin "${branch}"
remote_head="$(git rev-parse "refs/remotes/origin/${branch}")"
git merge-base --is-ancestor "${policy_commit}" "${remote_head}" || {
    echo "error: transport branch no longer descends from hammered policy commit ${policy_commit}" >&2
    exit 2
}

out="${HOME}/helix-quest-transport-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'remote_head=%s\npolicy_commit=%s\ncaller_head=%s\n' \
    "${remote_head}" "${policy_commit}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${remote_head}" >/dev/null
cd "${worktree}"
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty at creation" >&2; exit 2; }
[[ "$(git hash-object "${transformer}")" == "${expected_transformer_blob}" ]] || { echo "error: transformer blob mismatch" >&2; exit 2; }

echo "[1/6] Applying exact Quest synthetic transport source slice"
python3 "${transformer}" | tee "${out}/transform.txt"

echo "[2/6] Formatting and exact-scope audit"
tmp="${out}/formatted"
mkdir -p "${tmp}"
for path in "${format_paths[@]}"; do
    mkdir -p "${tmp}/$(dirname "${path}")"
    clang-format -style=file "${path}" >"${tmp}/${path}"
done
for path in "${format_paths[@]}"; do
    cp "${tmp}/${path}" "${path}"
done
clang-format --dry-run --Werror "${format_paths[@]}"
git diff --check -- "${source_paths[@]}"
mapfile -t changed < <(git diff --name-only -- "${source_paths[@]}")
[[ "${#changed[@]}" -eq "${#source_paths[@]}" ]] || { echo "error: unexpected changed-file count" >&2; printf '%s\n' "${changed[@]}" >&2; exit 2; }
for path in "${source_paths[@]}"; do
    printf '%s\n' "${changed[@]}" | grep -Fxq "${path}" || { echo "error: missing transformed path ${path}" >&2; exit 2; }
done
for marker in \
    '--helix-synthetic-transport' \
    'helix_synthetic_transport::run' \
    'HELIX_SYNTHETIC_TRANSPORT_EXIT' \
    'HELIX_SYNTHETIC_TRANSPORT_ORACLE_SANITY' \
    'HELIX_SYNTHETIC_TRANSPORT_RESULT' \
    'shards_per_frame, 0, false' \
    '::connection.reset()'; do
    grep -R -Fq -- "${marker}" "${source_paths[@]}" || { echo "error: source marker missing: ${marker}" >&2; exit 2; }
done
grep -Fq 'helix_synthetic_transport.cpp' server/CMakeLists.txt || { echo "error: synthetic transport source is not in server target" >&2; exit 2; }
grep -Fq 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
git diff --stat -- "${source_paths[@]}" | tee "${out}/source-stat.txt"
git diff -- "${source_paths[@]}" >"${out}/source.diff"

echo "[3/6] Committing exact transport source before compilation"
git add -- "${source_paths[@]}"
git commit -m "Helix: add bounded Quest synthetic transport mode" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
printf 'source_commit=%s\n' "${source_commit}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated source tree dirty after commit" >&2; exit 2; }

echo "[4/6] Building exact committed wivrn-server"
cmake --preset server 2>&1 | tee "${out}/configure.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "${out}/build.txt"
build_status=${PIPESTATUS[0]}
set -e
(( build_status == 0 )) || exit "${build_status}"

echo "[5/6] Verifying build-graph provenance"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-server/version.cpp || { echo "error: generated version.cpp does not contain exact source commit" >&2; exit 2; }
mapfile -t version_objects < <(find build-server -type f -name 'version.cpp.o' -print)
[[ "${#version_objects[@]}" -ge 1 ]] || { echo "error: compiled version.cpp.o not found" >&2; exit 2; }
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "${common_archive}" && -s "${common_archive}" ]] || { echo "error: common-base archive not found" >&2; exit 2; }
ar t "${common_archive}" | grep -Fq 'version.cpp.o' || { echo "error: common-base archive lacks version.cpp.o" >&2; exit 2; }
nm -C "${common_archive}" | grep -Fq 'wivrn::display_version()' || { echo "error: common-base archive lacks display_version symbol" >&2; exit 2; }
ninja -C build-server -t query server/wivrn-server >"${out}/ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "${out}/ninja-query.txt" || { echo "error: final server graph lacks synthetic transport object" >&2; exit 2; }
grep -Fq 'wivrn-common-base' "${out}/ninja-query.txt" || grep -Fq 'wivrn-common' "${out}/ninja-query.txt" || { echo "error: final server graph lacks WiVRn common dependency" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nprovenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[6/6] Publishing exact compiled transport checkpoint"
git push origin "HEAD:${branch}" 2>&1 | tee "${out}/push.txt"

printf '\nPASS: Quest synthetic transport server compiled and published with build-graph provenance.\n'
printf 'commit=%s\nserver=%s\nevidence=%s\n' "${source_commit}" "${server}" "${out}"
printf 'STATUS: built server only; Quest APK not built/installed and transport battery not runtime-tested.\n'
