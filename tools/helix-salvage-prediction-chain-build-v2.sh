#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

for command in git find sed grep nm ar ninja realpath sha256sum; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "error: required command not found: ${command}" >&2
        exit 2
    fi
done

tooling_branch="helix-cross-frame-matrix-prototype"
built_branch="helix-prediction-chain-built"
git fetch origin "${tooling_branch}"
tooling_head="$(git rev-parse "refs/remotes/origin/${tooling_branch}")"

candidate=""
while IFS= read -r dir; do
    [[ -f "${dir}/metadata.txt" ]] || continue
    [[ -e "${dir}/worktree/.git" ]] || continue
    grep -q '^source_commit=' "${dir}/metadata.txt" || continue
    [[ -s "${dir}/worktree/build-server/server/wivrn-server" ]] || continue
    candidate="${dir}"
    break
done < <(find "${HOME}" -maxdepth 1 -type d -name 'helix-prediction-chain-build-*' -printf '%T@ %p\n' | sort -nr | cut -d' ' -f2-)

if [[ -z "${candidate}" ]]; then
    echo "error: no preserved completed prediction-chain build bundle found" >&2
    exit 2
fi

worktree="${candidate}/worktree"
source_commit="$(sed -n 's/^source_commit=//p' "${candidate}/metadata.txt" | tail -n1)"
if [[ -z "${source_commit}" ]]; then
    echo "error: source_commit missing from ${candidate}/metadata.txt" >&2
    exit 2
fi
if ! git cat-file -e "${source_commit}^{commit}" 2>/dev/null; then
    echo "error: source commit object ${source_commit} unavailable" >&2
    exit 2
fi
if [[ "$(git -C "${worktree}" rev-parse HEAD)" != "${source_commit}" ]]; then
    echo "error: preserved worktree HEAD does not match source_commit" >&2
    exit 2
fi
parent="$(git rev-parse "${source_commit}^")"
if ! git merge-base --is-ancestor "${parent}" "${tooling_head}"; then
    echo "error: source commit parent is not an ancestor of current tooling branch" >&2
    exit 2
fi

mapfile -t changed < <(git diff-tree --no-commit-id --name-only -r "${source_commit}" | sort)
expected=(
    server/encoder/video_encoder.cpp
    server/encoder/video_encoder.h
    server/encoder/video_encoder_nvenc.cpp
    server/encoder/video_encoder_nvenc.h
)
mapfile -t expected_sorted < <(printf '%s\n' "${expected[@]}" | sort)
if [[ "${#changed[@]}" -ne "${#expected_sorted[@]}" ]]; then
    echo "error: source commit changed unexpected number of files" >&2
    printf 'changed: %s\n' "${changed[@]}" >&2
    exit 2
fi
for i in "${!expected_sorted[@]}"; do
    if [[ "${changed[$i]}" != "${expected_sorted[$i]}" ]]; then
        echo "error: source commit path mismatch" >&2
        printf 'expected=%s actual=%s\n' "${expected_sorted[$i]}" "${changed[$i]}" >&2
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
        echo "error: required final-source marker missing: ${marker}" >&2
        exit 2
    fi
done

version_cpp="${worktree}/build-server/version.cpp"
if [[ ! -s "${version_cpp}" ]]; then
    echo "error: generated version.cpp missing" >&2
    exit 2
fi
if ! grep -Fq "const char git_commit[] = \"${source_commit}\";" "${version_cpp}"; then
    echo "error: generated version.cpp does not contain exact source commit" >&2
    exit 2
fi

mapfile -t archives < <(find "${worktree}/build-server" -type f -name 'libwivrn-common-base.a' -print)
if [[ "${#archives[@]}" -ne 1 ]]; then
    echo "error: expected exactly one libwivrn-common-base.a, found ${#archives[@]}" >&2
    exit 2
fi
archive="$(realpath "${archives[0]}")"
if ! ar t "${archive}" | grep -Fq 'version.cpp.o'; then
    echo "error: common-base archive does not contain version.cpp.o" >&2
    exit 2
fi
if ! nm -C "${archive}" | grep -Fq 'wivrn::display_version()'; then
    echo "error: common-base archive lacks wivrn::display_version()" >&2
    exit 2
fi

mapfile -t version_objects < <(find "${worktree}/build-server" -type f -path '*/wivrn-common-base.dir/*version.cpp.o' -print)
if [[ "${#version_objects[@]}" -ne 1 ]]; then
    echo "error: expected exactly one compiled version.cpp.o, found ${#version_objects[@]}" >&2
    exit 2
fi
version_object="$(realpath "${version_objects[0]}")"
if ! nm -C "${version_object}" | grep -Fq 'wivrn::display_version()'; then
    echo "error: compiled version.cpp.o lacks wivrn::display_version()" >&2
    exit 2
fi

server="$(realpath "${worktree}/build-server/server/wivrn-server")"
if [[ ! -s "${server}" ]]; then
    echo "error: preserved linked wivrn-server is empty" >&2
    exit 2
fi

link_commands="${candidate}/link-commands.txt"
ninja -C "${worktree}/build-server" -t commands server/wivrn-server >"${link_commands}"
if ! grep -Fq 'libwivrn-common-base.a' "${link_commands}"; then
    echo "error: wivrn-server build graph does not link libwivrn-common-base.a" >&2
    exit 2
fi
if ! grep -Fq 'server/wivrn-server' "${link_commands}"; then
    echo "error: build graph does not contain final wivrn-server link command" >&2
    exit 2
fi

if [[ ! -f "${candidate}/build.txt" ]] || ! grep -Fq 'Linking CXX executable server/wivrn-server' "${candidate}/build.txt"; then
    echo "error: preserved build log does not show final server link completion" >&2
    exit 2
fi

server_symbol="absent"
if nm -C "${server}" 2>/dev/null | grep -Fq 'wivrn::display_version()'; then
    server_symbol="present"
fi

server_sha256="$(sha256sum "${server}" | awk '{print $1}')"
archive_sha256="$(sha256sum "${archive}" | awk '{print $1}')"
object_sha256="$(sha256sum "${version_object}" | awk '{print $1}')"

result="${candidate}/provenance-salvaged-v2.txt"
{
    printf 'bundle=%s\n' "${candidate}"
    printf 'source_commit=%s\n' "${source_commit}"
    printf 'source_parent=%s\n' "${parent}"
    printf 'generated_version_cpp=PASS\n'
    printf 'version_object=%s\n' "${version_object}"
    printf 'version_object_sha256=%s\n' "${object_sha256}"
    printf 'common_base_archive=%s\n' "${archive}"
    printf 'common_base_archive_sha256=%s\n' "${archive_sha256}"
    printf 'archive_contains_version_object=PASS\n'
    printf 'archive_display_version_symbol=PASS\n'
    printf 'server=%s\n' "${server}"
    printf 'server_sha256=%s\n' "${server_sha256}"
    printf 'server_display_version_symbol=%s\n' "${server_symbol}"
    printf 'server_link_graph_common_base=PASS\n'
    printf 'server_link_completion=PASS\n'
    printf 'provenance=PASS build-graph-and-generated-version\n'
} | tee "${result}"

existing="$(git ls-remote --heads origin "refs/heads/${built_branch}" | awk '{print $1}')"
if [[ -n "${existing}" && "${existing}" != "${source_commit}" ]]; then
    echo "error: ${built_branch} already exists at different commit ${existing}" >&2
    exit 2
fi
if [[ -z "${existing}" ]]; then
    git push origin "${source_commit}:refs/heads/${built_branch}"
fi

echo "PASS: existing prediction-chain build salvaged without rebuild"
echo "published_branch=${built_branch}"
echo "published_commit=${source_commit}"
echo "evidence=${result}"
echo "STATUS: existing server build only; not installed and not runtime-tested"
