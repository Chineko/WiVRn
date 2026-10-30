#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

expected_branch="helix-cross-frame-matrix-prototype"
helper="tools/helix-apply-prediction-invalidation.py"
transformer="tools/helix-apply-prediction-chain.py"
simulator="tools/helix-matrix-sim.py"
expected_helper_blob="abdcdd3d98f3bd8899e82ce9cfcce978a33fc8e5"
expected_transformer_blob="e32bbfa587a06ae07618156d0bc1e54bccbe33de"
expected_simulator_blob="046da009cc242f42cbf829ad10c42cb823104129"
tracked_paths=(
    server/encoder/video_encoder.h
    server/encoder/video_encoder.cpp
    server/encoder/video_encoder_nvenc.h
    server/encoder/video_encoder_nvenc.cpp
)

branch="$(git branch --show-current)"
if [[ "${branch}" != "${expected_branch}" ]]; then
    echo "error: expected branch ${expected_branch}, got ${branch:-DETACHED}" >&2
    exit 2
fi
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: worktree is not clean; refusing to mix prediction-chain source with unrelated changes" >&2
    exit 2
fi

for pair in \
    "${helper}:${expected_helper_blob}" \
    "${transformer}:${expected_transformer_blob}" \
    "${simulator}:${expected_simulator_blob}"; do
    path="${pair%%:*}"
    expected="${pair##*:}"
    actual="$(git hash-object "${path}")"
    if [[ "${actual}" != "${expected}" ]]; then
        echo "error: ${path} blob mismatch: expected ${expected}, got ${actual}" >&2
        exit 2
    fi
done

for command in python3 clang-format cmake git; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 2
    fi
done

out="${HOME}/helix-prediction-chain-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'branch=%s\nhead_before=%s\n' "${branch}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"

source_dirty=0
committed=0
cleanup_on_error() {
    status=$?
    if (( status != 0 )); then
        echo "Helix build gate failed (status ${status}). Evidence: ${out}" >&2
        if (( source_dirty == 1 && committed == 0 )); then
            git diff -- "${tracked_paths[@]}" >"${out}/failed-source.diff" || true
            git checkout -- "${tracked_paths[@]}" || true
            echo "Source files restored to the pre-run commit; failed diff preserved at ${out}/failed-source.diff" >&2
        fi
    fi
    exit "${status}"
}
trap cleanup_on_error EXIT

echo "[1/6] Deterministic recovery-model gate"
python3 "${simulator}" --self-test-cases 1000 | tee "${out}/simulator.txt"

echo "[2/6] Applying exact prediction-chain source transformation"
python3 "${transformer}" | tee "${out}/transform.txt"
source_dirty=1

echo "[3/6] Formatting and source-scope audit"
tmpdir="$(mktemp -d)"
for path in "${tracked_paths[@]}"; do
    mkdir -p "${tmpdir}/$(dirname "${path}")"
    clang-format -style=file "${path}" >"${tmpdir}/${path}"
done
format_changed_lines=0
for path in "${tracked_paths[@]}"; do
    changed="$(diff -U0 "${path}" "${tmpdir}/${path}" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l || true)"
    format_changed_lines=$((format_changed_lines + changed))
done
printf 'format_changed_lines=%d\n' "${format_changed_lines}" | tee -a "${out}/metadata.txt"
if (( format_changed_lines > 180 )); then
    echo "error: clang-format delta unexpectedly large (${format_changed_lines} lines)" >&2
    rm -rf "${tmpdir}"
    exit 2
fi
for path in "${tracked_paths[@]}"; do
    cp "${tmpdir}/${path}" "${path}"
done
rm -rf "${tmpdir}"
clang-format --dry-run --Werror "${tracked_paths[@]}"
git diff --check -- "${tracked_paths[@]}"
changed_paths="$(git diff --name-only -- "${tracked_paths[@]}")"
for path in "${tracked_paths[@]}"; do
    if ! grep -Fxq "${path}" <<<"${changed_paths}"; then
        echo "error: expected transformed path missing from diff: ${path}" >&2
        exit 2
    fi
done
if [[ "$(wc -l <<<"${changed_paths}")" -ne "${#tracked_paths[@]}" ]]; then
    echo "error: unexpected source-path count after transformation" >&2
    printf '%s\n' "${changed_paths}" >&2
    exit 2
fi
git diff --stat -- "${tracked_paths[@]}" | tee "${out}/source-stat.txt"
git diff -- "${tracked_paths[@]}" >"${out}/source.diff"
changed_total="$(git diff --numstat -- "${tracked_paths[@]}" | awk '{a+=$1; d+=$2} END {print a+d+0}')"
printf 'source_changed_lines=%s\n' "${changed_total}" | tee -a "${out}/metadata.txt"
if (( changed_total > 320 )); then
    echo "error: final source diff unexpectedly large (${changed_total} changed lines)" >&2
    exit 2
fi
for marker in \
    'helix_td_enabled(false)' \
    'inputTimeStamp = frame_index' \
    'NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION' \
    'nvEncInvalidateRefFrames' \
    'Helix NVENC invalidation summary'; do
    if ! grep -R -Fq "${marker}" "${tracked_paths[@]}"; then
        echo "error: required final-source marker missing: ${marker}" >&2
        exit 2
    fi
done

echo "[4/6] Building wivrn-server"
if [[ ! -f build-server/build.ninja ]]; then
    cmake --preset server 2>&1 | tee "${out}/cmake-configure.txt"
fi
set +e
cmake --build build-server --target wivrn-server -j 2>&1 | tee "${out}/build.txt"
build_status=${PIPESTATUS[0]}
set -e
if (( build_status != 0 )); then
    exit "${build_status}"
fi

server="$(find build-server -type f -name wivrn-server -perm -111 -print | head -n 1)"
if [[ -z "${server}" || ! -s "${server}" ]]; then
    echo "error: build completed but nonempty wivrn-server artifact was not found" >&2
    exit 2
fi
server="$(realpath "${server}")"
printf 'server=%s\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[5/6] Committing exact compiled source"
git add -- "${tracked_paths[@]}"
git commit -m "Helix: prototype bounded prediction-chain invalidation" | tee "${out}/commit.txt"
committed=1
commit="$(git rev-parse HEAD)"
printf 'source_commit=%s\n' "${commit}" | tee -a "${out}/metadata.txt"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: worktree is not clean after source commit" >&2
    exit 2
fi

echo "[6/6] Publishing compiled checkpoint"
git push origin "HEAD:${expected_branch}" 2>&1 | tee "${out}/push.txt"

printf '\nPASS: prediction-chain source compiled, committed, and pushed.\n'
printf 'commit=%s\n' "${commit}"
printf 'server=%s\n' "${server}"
printf 'evidence=%s\n' "${out}"
printf 'STATUS: built server only; not installed and not runtime-tested.\n'
trap - EXIT
