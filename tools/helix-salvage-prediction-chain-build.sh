#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

tooling_branch="helix-cross-frame-matrix-prototype"
built_branch="helix-prediction-chain-built"
expected_parent="443377197772444c3062c03bfa5b4a33220ab4b8"
git fetch origin "${tooling_branch}"
remote_tooling_head="$(git rev-parse "refs/remotes/origin/${tooling_branch}")"
if ! git merge-base --is-ancestor "${expected_parent}" "${remote_tooling_head}"; then
    echo "error: tooling branch no longer descends from audited build base ${expected_parent}" >&2
    exit 2
fi

candidate=""
while IFS= read -r dir; do
    if [[ -f "${dir}/metadata.txt" && -f "${dir}/worktree/.git" ]]; then
        if grep -q '^source_commit=' "${dir}/metadata.txt"; then
            candidate="${dir}"
            break
        fi
    fi
done < <(find "${HOME}" -maxdepth 1 -type d -name 'helix-prediction-chain-build-*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)
if [[ -z "${candidate}" ]]; then
    echo "error: no completed prediction-chain build bundle with source_commit found" >&2
    exit 2
fi

worktree="${candidate}/worktree"
source_commit="$(sed -n 's/^source_commit=//p' "${candidate}/metadata.txt" | tail -n1)"
if [[ -z "${source_commit}" ]]; then
    echo "error: source_commit missing from ${candidate}/metadata.txt" >&2
    exit 2
fi
if ! git cat-file -e "${source_commit}^{commit}" 2>/dev/null; then
    echo "error: source commit object ${source_commit} is unavailable" >&2
    exit 2
fi
if [[ "$(git -C "${worktree}" rev-parse HEAD)" != "${source_commit}" ]]; then
    echo "error: preserved worktree HEAD does not match source_commit" >&2
    exit 2
fi
parent="$(git rev-parse "${source_commit}^")"
if [[ "${parent}" != "${expected_parent}" ]]; then
    echo "error: source commit parent does not match the exact audited build base" >&2
    echo "expected_parent=${expected_parent}" >&2
    echo "source_parent=${parent}" >&2
    exit 2
fi

mapfile -t changed < <(git diff-tree --no-commit-id --name-only -r "${source_commit}")
expected=(
    server/encoder/video_encoder.cpp
    server/encoder/video_encoder.h
    server/encoder/video_encoder_nvenc.cpp
    server/encoder/video_encoder_nvenc.h
)
if [[ "${#changed[@]}" -ne "${#expected[@]}" ]]; then
    echo "error: unexpected changed-file count in source commit" >&2
    printf 'changed: %s\n' "${changed[@]}" >&2
    exit 2
fi
for path in "${expected[@]}"; do
    if ! printf '%s\n' "${changed[@]}" | grep -Fxq "${path}"; then
        echo "error: expected source path missing from commit: ${path}" >&2
        exit 2
    fi
done

for marker in \
    'helix_td_enabled(false)' \
    'inputTimeStamp = frame_index' \
    'NV_ENC_CAPS_SUPPORT_REF_PIC_INVALIDATION' \
    'nvEncInvalidateRefFrames' \
    'Helix NVENC invalidation summary'; do
    if ! grep -R -Fq "${marker}" \
        "${worktree}/server/encoder/video_encoder.cpp" \
        "${worktree}/server/encoder/video_encoder_nvenc.cpp" \
        "${worktree}/server/encoder/video_encoder_nvenc.h"; then
        echo "error: required source marker missing: ${marker}" >&2
        exit 2
    fi
done

version_cpp="${worktree}/build-server/version.cpp"
if [[ ! -s "${version_cpp}" ]]; then
    echo "error: generated version.cpp missing from preserved build" >&2
    exit 2
fi
if ! grep -Fq "const char git_commit[] = \"${source_commit}\";" "${version_cpp}"; then
    echo "error: generated version.cpp does not contain exact source commit" >&2
    exit 2
fi

git_desc="$(git -C "${worktree}" describe --tags --always)"
if [[ -z "${git_desc}" ]]; then
    echo "error: could not derive git describe identity" >&2
    exit 2
fi
if ! grep -Fq "static const char git_desc[] = \"${git_desc}\";" "${version_cpp}"; then
    echo "error: generated version.cpp git_desc does not match source commit" >&2
    exit 2
fi

mapfile -t servers < <(find "${worktree}/build-server" -type f -name wivrn-server -perm -111 -print)
if [[ "${#servers[@]}" -ne 1 ]]; then
    echo "error: expected exactly one preserved wivrn-server, found ${#servers[@]}" >&2
    exit 2
fi
server="$(realpath "${servers[0]}")"
if [[ ! -s "${server}" ]]; then
    echo "error: preserved wivrn-server is empty" >&2
    exit 2
fi
if ! strings "${server}" | grep -Fq "${git_desc}"; then
    echo "error: linked server does not contain generated git_desc ${git_desc}" >&2
    exit 2
fi

if [[ -f "${candidate}/build.txt" ]]; then
    if ! grep -Fq 'Linking CXX executable server/wivrn-server' "${candidate}/build.txt"; then
        echo "error: preserved build log does not show wivrn-server link completion" >&2
        exit 2
    fi
fi

printf 'salvaged_bundle=%s\n' "${candidate}"
printf 'source_commit=%s\n' "${source_commit}"
printf 'source_parent=%s\n' "${parent}"
printf 'git_desc=%s\n' "${git_desc}"
printf 'server=%s\n' "${server}"
printf 'provenance=PASS generated-version-and-linked-display-version\n'

echo "Publishing exact already-built source commit to ${built_branch}"
if git show-ref --verify --quiet "refs/remotes/origin/${built_branch}"; then
    existing="$(git rev-parse "refs/remotes/origin/${built_branch}")"
    if [[ "${existing}" != "${source_commit}" ]]; then
        echo "error: ${built_branch} already exists at a different commit ${existing}" >&2
        exit 2
    fi
else
    git push origin "${source_commit}:refs/heads/${built_branch}"
fi

echo "PASS: preserved prediction-chain build provenance validated"
echo "built_branch=${built_branch}"
echo "STATUS: existing server build salvaged; no rebuild, install, or runtime test performed"
