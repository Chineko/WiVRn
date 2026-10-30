#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

base_commit="e0267e16daaa0aeaef3e08e39e4bde4fc431e6a0"
source_branch="helix-quest-transport-result-capture-fix"
source_path="server/helix_synthetic_transport.cpp"
version_prefix="helix"

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum rsvg-convert; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git cat-file -e "${base_commit}^{commit}" 2>/dev/null || git fetch origin "${base_commit}"
git cat-file -e "${base_commit}^{commit}" 2>/dev/null || { echo "error: base commit ${base_commit} unavailable" >&2; exit 2; }

if git ls-remote --exit-code --heads origin "${source_branch}" >/dev/null 2>&1; then
    echo "error: origin/${source_branch} already exists; classify existing state before rebuilding" >&2
    exit 2
fi

out="${HOME}/helix-quest-result-capture-fix-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'base_commit=%s\nsource_branch=%s\ncaller_head=%s\n' \
    "${base_commit}" "${source_branch}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${base_commit}" >/dev/null
cd "${worktree}"
[[ "$(git rev-parse HEAD)" == "${base_commit}" ]] || { echo "error: wrong isolated base commit" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated worktree dirty at creation" >&2; exit 2; }

cat >"${out}/apply_fix.py" <<'PY'
from pathlib import Path

path = Path("server/helix_synthetic_transport.cpp")
text = path.read_text()

if '#include <cstdio>\n' not in text:
    anchor = '#include <cstdint>\n'
    if text.count(anchor) != 1:
        raise SystemExit('error: cstdint include anchor not unique')
    text = text.replace(anchor, anchor + '#include <cstdio>\n')

old_fail = '''\t\tU_LOG_W("Helix synthetic transport case failed stream=%u base=%llu missing=%u start=%u damaged_ok=%d exposing_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu",\n\t\t        stream,\n\t\t        static_cast<unsigned long long>(base),\n\t\t        missing,\n\t\t        start,\n\t\t        damaged_ok,\n\t\t        exposing_ok,\n\t\t        gap_ok,\n\t\t        obs.feedback.size(),\n\t\t        obs.gaps.size(),\n\t\t        obs.rtx.size());\n'''
new_fail = old_fail + '''\t\tstd::fprintf(stderr,\n\t\t             "HELIX_SYNTHETIC_TRANSPORT_CASE_FAILED stream=%u base=%llu missing=%u start=%u damaged_ok=%d exposing_ok=%d gap_ok=%d feedback=%zu gaps=%zu rtx=%zu\\n",\n\t\t             stream,\n\t\t             static_cast<unsigned long long>(base),\n\t\t             missing,\n\t\t             start,\n\t\t             damaged_ok,\n\t\t             exposing_ok,\n\t\t             gap_ok,\n\t\t             obs.feedback.size(),\n\t\t             obs.gaps.size(),\n\t\t             obs.rtx.size());\n\t\tstd::fflush(stderr);\n'''
if text.count(old_fail) != 1:
    raise SystemExit(f'error: expected one primary failure telemetry site, found {text.count(old_fail)}')
text = text.replace(old_fail, new_fail)

needle = '''\tU_LOG_I("HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f envelope_total=%llu envelope_good=%llu envelope_ratio=%.6f ordering_total=%llu ordering_good=%llu ordering_ratio=%.6f rtx_total=%llu rtx_good=%llu rtx_ratio=%.6f catastrophic=%llu",\n'''
if text.count(needle) != 1:
    raise SystemExit(f'error: expected one final result logger, found {text.count(needle)}')

marker = '''\t        static_cast<unsigned long long>(s.catastrophic));\n\n\treturn pass ? 0 : 1;\n'''
replacement = '''\t        static_cast<unsigned long long>(s.catastrophic));\n\n\tstd::fprintf(stderr,\n\t             "HELIX_SYNTHETIC_TRANSPORT_RESULT pass=%d total=%llu good=%llu good_ratio=%.6f fallback_total=%llu fallback_good=%llu fallback_ratio=%.6f recorded_total=%llu recorded_good=%llu recorded_ratio=%.6f envelope_total=%llu envelope_good=%llu envelope_ratio=%.6f ordering_total=%llu ordering_good=%llu ordering_ratio=%.6f rtx_total=%llu rtx_good=%llu rtx_ratio=%.6f catastrophic=%llu\\n",\n\t             pass,\n\t             static_cast<unsigned long long>(s.total),\n\t             static_cast<unsigned long long>(s.good),\n\t             good_ratio,\n\t             static_cast<unsigned long long>(s.fallback_total),\n\t             static_cast<unsigned long long>(s.fallback_good),\n\t             fallback_ratio,\n\t             static_cast<unsigned long long>(s.recorded_total),\n\t             static_cast<unsigned long long>(s.recorded_good),\n\t             recorded_ratio,\n\t             static_cast<unsigned long long>(s.envelope_total),\n\t             static_cast<unsigned long long>(s.envelope_good),\n\t             envelope_ratio,\n\t             static_cast<unsigned long long>(s.ordering_total),\n\t             static_cast<unsigned long long>(s.ordering_good),\n\t             ordering_ratio,\n\t             static_cast<unsigned long long>(s.rtx_total),\n\t             static_cast<unsigned long long>(s.rtx_good),\n\t             rtx_ratio,\n\t             static_cast<unsigned long long>(s.catastrophic));\n\tstd::fflush(stderr);\n\n\treturn pass ? 0 : 1;\n'''
if text.count(marker) != 1:
    raise SystemExit(f'error: final result tail anchor not unique: {text.count(marker)}')
text = text.replace(marker, replacement)
path.write_text(text)
PY

echo "[1/8] Applying deterministic scorer-capture fix"
python3 "${out}/apply_fix.py"

echo "[2/8] Formatting and exact-scope audit"
clang-format -i -style=file "${source_path}"
clang-format --dry-run --Werror "${source_path}"
git diff --check -- "${source_path}"
mapfile -t changed < <(git diff --name-only)
[[ "${#changed[@]}" -eq 1 && "${changed[0]}" == "${source_path}" ]] || {
    echo "error: unexpected changed paths" >&2
    printf '%s\n' "${changed[@]}" >&2
    exit 2
}
grep -Fq '#include <cstdio>' "${source_path}" || { echo "error: cstdio include missing" >&2; exit 2; }
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_CASE_FAILED' "${source_path}" || { echo "error: deterministic case-failure telemetry missing" >&2; exit 2; }
[[ "$(grep -Fc 'HELIX_SYNTHETIC_TRANSPORT_RESULT pass=' "${source_path}")" -eq 2 ]] || { echo "error: expected framework + direct final result telemetry" >&2; exit 2; }
grep -Fq 'std::fflush(stderr);' "${source_path}" || { echo "error: direct telemetry flush missing" >&2; exit 2; }
grep -Fq 'foveation.x = {width};' "${source_path}" || { echo "error: prior swapchain fix missing" >&2; exit 2; }
grep -Fq 'foveation.y = {height};' "${source_path}" || { echo "error: prior swapchain fix missing" >&2; exit 2; }
grep -Fq 'run_rtx_rescue_case' "${source_path}" || { echo "error: torture battery drifted" >&2; exit 2; }
grep -Fq -- 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
git diff --stat | tee "${out}/source-stat.txt"
git diff >"${out}/source.diff"

echo "[3/8] Committing exact source before compilation"
git add -- "${source_path}"
git commit -m "Helix: make transport promotion telemetry capture deterministic" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${version_prefix}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "${source_commit}" "${version_name}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree dirty after commit" >&2; exit 2; }

echo "[4/8] Publishing exact source checkpoint"
git push origin "HEAD:refs/heads/${source_branch}" 2>&1 | tee "${out}/push.txt"

echo "[5/8] Building exact committed wivrn-server"
cmake --preset server 2>&1 | tee "${out}/configure-server.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "${out}/build-server.txt"
server_build_status=${PIPESTATUS[0]}
set -e
(( server_build_status == 0 )) || exit "${server_build_status}"

echo "[6/8] Verifying server build-graph provenance"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-server/version.cpp || { echo "error: generated version.cpp lacks exact source commit" >&2; exit 2; }
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "${common_archive}" && -s "${common_archive}" ]] || { echo "error: common-base archive not found" >&2; exit 2; }
ar t "${common_archive}" | grep -Fq 'version.cpp.o' || { echo "error: common-base archive lacks version.cpp.o" >&2; exit 2; }
nm -C "${common_archive}" | grep -Fq 'wivrn::display_version()' || { echo "error: common-base archive lacks display_version symbol" >&2; exit 2; }
ninja -C build-server -t query server/wivrn-server >"${out}/ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "${out}/ninja-query.txt" || { echo "error: final server graph lacks synthetic transport object" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build-server.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nserver_provenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[7/8] Building exact matching Quest APK"
./gradlew --no-daemon assembleDebug \
    -Pwivrn_version="${version_name}" \
    -Pwivrn_app_name="Helix Transport Torture" \
    2>&1 | tee "${out}/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || { echo "error: expected exactly one debug APK, found ${#apks[@]}" >&2; exit 2; }
apk_source="$(realpath "${apks[0]}")"
apk="${out}/helix-quest-transport-result-capture-fix-${source_commit:0:12}.apk"
cp -- "${apk_source}" "${apk}"
sha256sum "${apk}" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "${apk}" | tee -a "${out}/metadata.txt"
[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: source HEAD changed during builds" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree changed during builds" >&2; exit 2; }

echo "[8/8] Final artifact gate"
printf 'artifact_gate=PASS exact-commit-server-and-apk\n' | tee -a "${out}/metadata.txt"
printf '\nPASS: deterministic transport result capture source committed, published, server built, and matching Quest APK built.\n'
printf 'commit=%s\nbranch=%s\nserver=%s\napk=%s\nevidence=%s\n' \
    "${source_commit}" "${source_branch}" "${server}" "${apk}" "${out}"
printf 'STATUS: built only; not installed and not runtime-tested.\n'
