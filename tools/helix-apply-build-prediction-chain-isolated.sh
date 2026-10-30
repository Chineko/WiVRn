#!/usr/bin/env bash
set -euo pipefail

caller_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${caller_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${caller_root}"

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

for command in python3 clang-format cmake git strings realpath; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 2
    fi
done

git fetch origin "${expected_branch}"
remote_ref="refs/remotes/origin/${expected_branch}"
remote_head="$(git rev-parse "${remote_ref}")"

out="${HOME}/helix-prediction-chain-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'caller_root=%s\ncaller_head=%s\nremote_branch=%s\nremote_head=%s\n' \
    "${caller_root}" "$(git rev-parse HEAD)" "${expected_branch}" "${remote_head}" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${remote_head}" >/dev/null
cd "${worktree}"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: isolated worktree unexpectedly dirty after creation" >&2
    exit 2
fi
if [[ "$(git rev-parse HEAD)" != "${remote_head}" ]]; then
    echo "error: isolated worktree HEAD mismatch" >&2
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

echo "[1/6] Deterministic recovery-model gate"
python3 "${simulator}" --self-test-cases 1000 | tee "${out}/simulator.txt"

echo "[2/6] Applying exact prediction-chain source transformation in isolated worktree"
python3 "${transformer}" | tee "${out}/transform.txt"

echo "[3/6] Formatting and source-scope audit"
tmpdir="${out}/formatted"
mkdir -p "${tmpdir}"
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
    exit 2
fi
for path in "${tracked_paths[@]}"; do
    cp "${tmpdir}/${path}" "${path}"
done
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

echo "[4/6] Committing exact isolated source before compilation"
git add -- "${tracked_paths[@]}"
git commit -m "Helix: prototype bounded prediction-chain invalidation" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
source_short="${source_commit:0:12}"
printf 'source_commit=%s\n' "${source_commit}" | tee -a "${out}/metadata.txt"
if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: isolated worktree is not clean after source commit" >&2
    exit 2
fi

echo "[5/6] Building exact committed wivrn-server in isolated worktree"
cmake --preset server 2>&1 | tee "${out}/cmake-configure.txt"
set +e
cmake --build build-server --target wivrn-server -j 2>&1 | tee "${out}/build.txt"
build_status=${PIPESTATUS[0]}
set -e
if (( build_status != 0 )); then
    git show --format= --binary "${source_commit}" >"${out}/failed-source.diff" || true
    exit "${build_status}"
fi
mapfile -t servers < <(find build-server -type f -name wivrn-server -perm -111 -print)
if [[ "${#servers[@]}" -ne 1 ]]; then
    echo "error: expected exactly one built wivrn-server, found ${#servers[@]}" >&2
    exit 2
fi
server="$(realpath "${servers[0]}")"
if [[ ! -s "${server}" ]]; then
    echo "error: built wivrn-server artifact is empty" >&2
    exit 2
fi
if ! strings "${server}" | grep -Fq "${source_short}"; then
    echo "error: compiled server does not contain source commit ${source_short}" >&2
    exit 2
fi
printf 'server=%s\nserver_commit_marker=%s\n' "${server}" "${source_short}" | tee -a "${out}/metadata.txt"

echo "[6/6] Publishing compiled checkpoint"
# Normal fast-forward push only. If the remote moved since fetch, this fails safely.
git push origin "HEAD:${expected_branch}" 2>&1 | tee "${out}/push.txt"

printf '\nPASS: isolated prediction-chain source committed, compiled with matching identity, and pushed.\n'
printf 'commit=%s\n' "${source_commit}"
printf 'server=%s\n' "${server}"
printf 'evidence=%s\n' "${out}"
printf 'caller_checkout=untouched\n'
printf 'STATUS: built server only; not installed and not runtime-tested.\n'
