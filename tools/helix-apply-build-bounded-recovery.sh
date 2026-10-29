#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn git checkout" >&2
    exit 2
fi
cd "${repo_root}"

expected_branch="helix-bounded-time-diverse-recovery"
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

tracked_paths=(
    server/encoder/idr_handler.cpp
    server/encoder/video_encoder.h
    server/encoder/video_encoder.cpp
)

# This helper is deliberately a resume path after the first exact transform.
# Refuse to proceed unless all characteristic transform markers are present.
python3 <<'PY'
from pathlib import Path

checks = {
    "server/encoder/idr_handler.cpp": [
        "const bool is_non_ref =",
        "std::unique_lock lock(mutex);\n\treturn non_ref_frames[frame_index % non_ref_frames.size()] == frame_index;",
    ],
    "server/encoder/video_encoder.h": [
        "helix_td_max_shards = 48",
        "helix_td_budget_divisor = 5",
        "helix_send_time_diverse_replay",
    ],
    "server/encoder/video_encoder.cpp": [
        "helix_td_enabled(settings.encoder_name == encoder_nvenc)",
        "Helix time-diverse summary",
        "void video_encoder::helix_send_time_diverse_replay",
        "helix_finish_time_diverse_frame(control);",
    ],
}
for path, markers in checks.items():
    text = Path(path).read_text()
    for marker in markers:
        if marker not in text:
            raise SystemExit(f"error: transformed-source marker missing in {path}: {marker}")
PY

# Only the three audited source files may be dirty. This preserves unrelated work.
unexpected="$(git status --porcelain --untracked-files=no | awk '{print $2}' | grep -v -E '^(server/encoder/idr_handler\.cpp|server/encoder/video_encoder\.h|server/encoder/video_encoder\.cpp)$' || true)"
if [[ -n "${unexpected}" ]]; then
    echo "error: unrelated tracked changes are present; refusing to mix them with the prototype" >&2
    printf '%s\n' "${unexpected}" >&2
    exit 2
fi

if ! command -v clang-format >/dev/null 2>&1; then
    echo "error: clang-format is required because this tree enforces formatting" >&2
    exit 2
fi

# Audit the complete formatting failure class non-destructively first. Format copies
# using the repository style, measure the resulting delta, and only then install them.
tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
for path in "${tracked_paths[@]}"; do
    mkdir -p "${tmpdir}/$(dirname "${path}")"
    clang-format -style=file "${path}" > "${tmpdir}/${path}"
done

format_changed_lines=0
for path in "${tracked_paths[@]}"; do
    changed="$(diff -U0 "${path}" "${tmpdir}/${path}" 2>/dev/null | grep -E '^[+-][^+-]' | wc -l || true)"
    format_changed_lines=$((format_changed_lines + changed))
done

echo "Formatting audit would change ${format_changed_lines} source lines."
# The inherited report_gap block is ~140 lines; the new prototype spans another
# bounded set of lines. Anything substantially larger is an unexpected-scope stop.
if (( format_changed_lines > 320 )); then
    echo "error: clang-format delta is unexpectedly large (${format_changed_lines} lines); refusing broad reformat" >&2
    exit 2
fi

for path in "${tracked_paths[@]}"; do
    cp "${tmpdir}/${path}" "${path}"
done

# Full-file check now proves there are no remaining format violations in the
# exact compilation units touched by this prototype.
clang-format --dry-run --Werror "${tracked_paths[@]}"
git diff --check -- "${tracked_paths[@]}"

# Show the exact source scope before compilation. Do not silently accept a huge diff.
diff_stat="$(git diff --stat -- "${tracked_paths[@]}")"
printf '%s\n' "${diff_stat}"
changed_total="$(git diff --numstat -- "${tracked_paths[@]}" | awk '{a+=$1; d+=$2} END {print a+d+0}')"
if (( changed_total > 500 )); then
    echo "error: final source diff is unexpectedly large (${changed_total} changed lines); stopping before build" >&2
    exit 2
fi

# CMakePresets.json defines the server preset and build-server binary directory.
if [[ ! -f build-server/build.ninja ]]; then
    cmake --preset server
fi
cmake --build build-server --target wivrn-server -j

echo
echo "PASS: transformed source is formatted and wivrn-server compiled."
echo "No headset/runtime validation has been performed."
echo "Working tree intentionally contains the audited prototype source diff for inspection/commit."
git status --short -- "${tracked_paths[@]}"
