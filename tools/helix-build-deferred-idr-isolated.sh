#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

branch="helix-prediction-chain-defer-idr"
transformer="tools/helix-apply-deferred-idr.py"
simulator="tools/helix-matrix-sim.py"
expected_transformer_blob="72d39fa1b8c63aa65adbd1575b05ecfc0cacd8e6"
expected_simulator_blob="046da009cc242f42cbf829ad10c42cb823104129"
source_paths=(
    server/encoder/idr_handler.h
    server/encoder/idr_handler.cpp
    server/encoder/video_encoder_nvenc.h
    server/encoder/video_encoder_nvenc.cpp
)

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git fetch origin "${branch}"
remote_head="$(git rev-parse "refs/remotes/origin/${branch}")"
out="${HOME}/helix-deferred-idr-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'remote_head=%s\ncaller_head=%s\n' "${remote_head}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${remote_head}" >/dev/null
cd "${worktree}"
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty at creation" >&2; exit 2; }

[[ "$(git hash-object "${transformer}")" == "${expected_transformer_blob}" ]] || { echo "error: transformer blob mismatch" >&2; exit 2; }
[[ "$(git hash-object "${simulator}")" == "${expected_simulator_blob}" ]] || { echo "error: simulator blob mismatch" >&2; exit 2; }

echo "[1/6] Deterministic model sanity gate"
python3 "${simulator}" --self-test-cases 1000 | tee "${out}/simulator.txt"

echo "[2/6] Applying deferred-IDR source policy"
python3 "${transformer}" | tee "${out}/transform.txt"

echo "[3/6] Formatting and exact-scope audit"
tmp="${out}/formatted"
mkdir -p "${tmp}"
for path in "${source_paths[@]}"; do
    mkdir -p "${tmp}/$(dirname "${path}")"
    clang-format -style=file "${path}" >"${tmp}/${path}"
done
for path in "${source_paths[@]}"; do
    cp "${tmp}/${path}" "${path}"
done
clang-format --dry-run --Werror "${source_paths[@]}"
git diff --check -- "${source_paths[@]}"
mapfile -t changed < <(git diff --name-only -- "${source_paths[@]}")
[[ "${#changed[@]}" -eq "${#source_paths[@]}" ]] || { echo "error: unexpected changed-file count" >&2; printf '%s\n' "${changed[@]}" >&2; exit 2; }
for path in "${source_paths[@]}"; do
    printf '%s\n' "${changed[@]}" | grep -Fxq "${path}" || { echo "error: missing transformed path ${path}" >&2; exit 2; }
done
for marker in \
    'can_defer_failed_reference' \
    'helix_invalidation_fallback_idr' \
    'nvEncInvalidateRefFrames' \
    'helix_drain_reference_invalidations();' \
    'inputTimeStamp = frame_index'; do
    grep -R -Fq "${marker}" "${source_paths[@]}" || { echo "error: source marker missing: ${marker}" >&2; exit 2; }
done
# The full-replay experiment must remain disabled in the base video encoder.
grep -Fq 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
git diff --stat -- "${source_paths[@]}" | tee "${out}/source-stat.txt"
git diff -- "${source_paths[@]}" >"${out}/source.diff"

echo "[4/6] Committing exact source before compilation"
git add -- "${source_paths[@]}"
git commit -m "Helix: defer IDR behind bounded NVENC invalidation" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
printf 'source_commit=%s\n' "${source_commit}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated source tree dirty after commit" >&2; exit 2; }

echo "[5/6] Building exact committed wivrn-server"
cmake --preset server 2>&1 | tee "${out}/configure.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "${out}/build.txt"
build_status=${PIPESTATUS[0]}
set -e
(( build_status == 0 )) || exit "${build_status}"

grep -Fq "const char git_commit[] = \"${source_commit}\";" build-server/version.cpp || { echo "error: generated version.cpp does not contain exact source commit" >&2; exit 2; }
mapfile -t version_objects < <(find build-server -type f -name 'version.cpp.o' -print)
[[ "${#version_objects[@]}" -ge 1 ]] || { echo "error: compiled version.cpp.o not found" >&2; exit 2; }
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "${common_archive}" && -s "${common_archive}" ]] || { echo "error: common-base archive not found" >&2; exit 2; }
ar t "${common_archive}" | grep -Fq 'version.cpp.o' || { echo "error: common-base archive lacks version.cpp.o" >&2; exit 2; }
nm -C "${common_archive}" | grep -Fq 'wivrn::display_version()' || { echo "error: common-base archive lacks display_version symbol" >&2; exit 2; }
ninja -C build-server -t query server/wivrn-server >"${out}/ninja-query.txt"
grep -Fq 'wivrn-common-base' "${out}/ninja-query.txt" || grep -Fq 'wivrn-common' "${out}/ninja-query.txt" || { echo "error: final server build graph lacks WiVRn common dependency" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nprovenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[6/6] Publishing exact compiled source checkpoint"
git push origin "HEAD:${branch}" 2>&1 | tee "${out}/push.txt"

printf '\nPASS: deferred-IDR source compiled and published with build-graph provenance.\n'
printf 'commit=%s\nserver=%s\nevidence=%s\n' "${source_commit}" "${server}" "${out}"
printf 'STATUS: built server only; not installed and not runtime-tested.\n'
