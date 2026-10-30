#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

branch="helix-quest-transport-torture"
base_commit="55a62a30671c19179701b686f469de377ba7865e"
transformer="tools/helix-apply-quest-transport-torture.py"
expected_transformer_blob="6ced85f2081a062dbe9502e9b90f993fcaa2164e"
source_path="server/helix_synthetic_transport.cpp"

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git fetch origin "${branch}"
remote_head="$(git rev-parse "refs/remotes/origin/${branch}")"
git merge-base --is-ancestor "${base_commit}" "${remote_head}" || {
    echo "error: torture branch no longer descends from compiled Quest transport checkpoint ${base_commit}" >&2
    exit 2
}

out="${HOME}/helix-quest-torture-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'remote_head=%s\nbase_commit=%s\ncaller_head=%s\n' \
    "${remote_head}" "${base_commit}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${remote_head}" >/dev/null
cd "${worktree}"
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty at creation" >&2; exit 2; }
[[ "$(git hash-object "${transformer}")" == "${expected_transformer_blob}" ]] || { echo "error: transformer blob mismatch" >&2; exit 2; }
[[ "$(git hash-object "${source_path}")" == "ce1294eb26d6fbef01d13cebe0345d8ac22be6d3" ]] || { echo "error: baseline synthetic transport source drifted" >&2; exit 2; }

echo "[1/6] Applying exact Quest transport torture slice"
python3 "${transformer}" | tee "${out}/transform.txt"

echo "[2/6] Formatting and exact-scope audit"
clang-format -i -style=file "${source_path}"
clang-format --dry-run --Werror "${source_path}"
git diff --check -- "${source_path}"
mapfile -t changed < <(git diff --name-only -- "${source_path}")
[[ "${#changed[@]}" -eq 1 && "${changed[0]}" == "${source_path}" ]] || { echo "error: unexpected changed paths" >&2; printf '%s\n' "${changed[@]}" >&2; exit 2; }
for marker in \
    'run_duplicate_case' \
    'run_reorder_case' \
    'run_late_old_case' \
    'run_frame_jump_case' \
    'run_rtx_rescue_case' \
    'HELIX_TRANSPORT_TORTURE' \
    'envelope_ratio' \
    'ordering_ratio' \
    'rtx_ratio'; do
    grep -Fq -- "${marker}" "${source_path}" || { echo "error: source marker missing: ${marker}" >&2; exit 2; }
done
# Preserve the known-safe surrounding transport mode and policy state.
grep -Fq -- '--helix-synthetic-transport' server/main.cpp || { echo "error: synthetic transport CLI mode missing" >&2; exit 2; }
grep -Fq -- '::connection.reset()' server/main.cpp || { echo "error: corrected synthetic cleanup missing" >&2; exit 2; }
grep -Fq -- 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
git diff --stat -- "${source_path}" | tee "${out}/source-stat.txt"
git diff -- "${source_path}" >"${out}/source.diff"

echo "[3/6] Committing exact torture source before compilation"
git add -- "${source_path}"
git commit -m "Helix: add Quest transport torture battery" | tee "${out}/commit.txt"
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
grep -Fq 'helix_synthetic_transport.cpp.o' "${out}/ninja-query.txt" || { echo "error: final server graph lacks torture transport object" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nprovenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[6/6] Publishing exact compiled torture checkpoint"
git push origin "HEAD:${branch}" 2>&1 | tee "${out}/push.txt"

printf '\nPASS: Quest transport torture server compiled and published with build-graph provenance.\n'
printf 'commit=%s\nserver=%s\nevidence=%s\n' "${source_commit}" "${server}" "${out}"
printf 'STATUS: built server only; Quest APK not built/installed and torture battery not runtime-tested.\n'
