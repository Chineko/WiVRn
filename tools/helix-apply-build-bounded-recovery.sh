#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn git checkout" >&2
    exit 2
fi
cd "${repo_root}"

expected_branch="helix-bounded-time-diverse-recovery"
patch_file="tools/helix-bounded-time-diverse-recovery.patch"
base_commit="20616b623698e0d761450ad0e906fb35daf17877"

branch="$(git branch --show-current)"
if [[ "${branch}" != "${expected_branch}" ]]; then
    echo "error: expected branch ${expected_branch}, got ${branch:-DETACHED}" >&2
    exit 2
fi

if ! git merge-base --is-ancestor "${base_commit}" HEAD; then
    echo "error: branch is not descended from audited IDR-overlap base ${base_commit}" >&2
    exit 2
fi

if [[ ! -f "${patch_file}" ]]; then
    echo "error: missing ${patch_file}" >&2
    exit 2
fi

tracked_paths=(
    server/encoder/idr_handler.cpp
    server/encoder/video_encoder.h
    server/encoder/video_encoder.cpp
)

if ! git diff --quiet -- "${tracked_paths[@]}" || ! git diff --cached --quiet -- "${tracked_paths[@]}"; then
    echo "error: prototype source paths already contain local changes; refusing to overlap them" >&2
    git status --short -- "${tracked_paths[@]}" >&2
    exit 2
fi

# The dry run is mandatory. If it fails, do not partially apply or retry with offsets.
git apply --check "${patch_file}"
git apply "${patch_file}"

echo "Applied bounded time-diverse recovery patch."

git diff --check -- "${tracked_paths[@]}"

if command -v clang-format >/dev/null 2>&1; then
    clang-format --dry-run --Werror "${tracked_paths[@]}"
else
    echo "note: clang-format not found; compile gate will still run" >&2
fi

# CMakePresets.json defines the server preset and build-server binary directory.
if [[ ! -f build-server/build.ninja ]]; then
    cmake --preset server
fi

cmake --build build-server --target wivrn-server -j

echo
echo "PASS: bounded recovery source applied and wivrn-server compiled."
echo "No headset/runtime validation has been performed."
echo "Working tree intentionally contains the audited prototype source diff for inspection/commit."
git status --short -- "${tracked_paths[@]}"
