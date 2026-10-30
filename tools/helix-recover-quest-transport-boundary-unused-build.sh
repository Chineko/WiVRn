#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "${repo_root}" ]] || { echo "error: run from inside WiVRn checkout" >&2; exit 2; }
cd "${repo_root}"

failed_commit="3b52e32e6b6529ea00b9c407d18d5d26be6352a9"
source_branch="helix-quest-transport-boundary-map"
source_path="server/helix_synthetic_transport.cpp"
version_prefix="helix-boundary"

for cmd in git python3 clang-format cmake ninja ar nm realpath grep find java sha256sum rsvg-convert; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

git fetch origin "${source_branch}"
remote_head="$(git rev-parse "refs/remotes/origin/${source_branch}")"
[[ "${remote_head}" == "${failed_commit}" ]] || {
    echo "error: boundary branch moved; expected failed checkpoint ${failed_commit}, got ${remote_head}" >&2
    exit 2
}

out="${HOME}/helix-quest-boundary-recovery-build-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
printf 'failed_commit=%s\nremote_head_before=%s\ncaller_head=%s\n' \
    "${failed_commit}" "${remote_head}" "$(git rev-parse HEAD)" >"${out}/metadata.txt"
printf 'caller_status_begin\n' >>"${out}/metadata.txt"
git status --short >>"${out}/metadata.txt" || true
printf 'caller_status_end\n' >>"${out}/metadata.txt"

worktree="${out}/worktree"
git worktree add --detach "${worktree}" "${failed_commit}" >/dev/null
cd "${worktree}"
[[ "$(git rev-parse HEAD)" == "${failed_commit}" ]] || { echo "error: wrong failed checkpoint" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: recovery worktree dirty" >&2; exit 2; }

cat >"${out}/apply_recovery.py" <<'PY'
from pathlib import Path

path = Path("server/helix_synthetic_transport.cpp")
text = path.read_text()

names = [
    "uint64_t mix64(",
    "bool run_case(",
    "bool run_duplicate_case(",
    "bool run_reorder_case(",
    "bool run_late_old_case(",
    "bool run_frame_jump_case(",
    "bool run_rtx_rescue_case(",
]

for needle in names:
    count = text.count(needle)
    if count != 1:
        raise SystemExit(f"error: expected exactly one {needle!r}, found {count}")
    text = text.replace(needle, "[[maybe_unused]] " + needle, 1)

path.write_text(text)
PY

echo "[1/8] Applying complete unused-helper compile recovery"
python3 "${out}/apply_recovery.py"

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
for marker in \
    '[[maybe_unused]] uint64_t mix64(' \
    '[[maybe_unused]] bool run_case(' \
    '[[maybe_unused]] bool run_duplicate_case(' \
    '[[maybe_unused]] bool run_reorder_case(' \
    '[[maybe_unused]] bool run_late_old_case(' \
    '[[maybe_unused]] bool run_frame_jump_case(' \
    '[[maybe_unused]] bool run_rtx_rescue_case(' \
    'HELIX_BOUNDARY axis=' \
    'HELIX_BOUNDARY_RESULT' \
    '"loss_depth"' \
    '"full_frame_run"' \
    '"reorder_distance"' \
    '"lateness_ms"' \
    '"frame_jump"' \
    '"rtx_pressure"' \
    '"duplicate_density"' \
    'foveation.x = {width};' \
    'foveation.y = {height};'; do
    grep -Fq -- "${marker}" "${source_path}" || { echo "error: required source marker missing: ${marker}" >&2; exit 2; }
done
grep -Fq -- 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
git diff --stat | tee "${out}/source-stat.txt"
git diff >"${out}/source.diff"

echo "[3/8] Committing exact corrective source before compilation"
git add -- "${source_path}"
git commit -m "Helix: fix boundary battery unused helper build failure" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${version_prefix}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "${source_commit}" "${version_name}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: corrective source tree dirty after commit" >&2; exit 2; }

# Deliberately compile before moving the published boundary branch again.
echo "[4/8] Building exact corrective wivrn-server"
cmake --preset server 2>&1 | tee "${out}/configure-server.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "${out}/build-server.txt"
build_status=${PIPESTATUS[0]}
set -e
(( build_status == 0 )) || exit "${build_status}"

echo "[5/8] Verifying server build-graph provenance"
grep -Fq "const char git_commit[] = \"${source_commit}\";" build-server/version.cpp || { echo "error: generated version.cpp lacks exact corrective commit" >&2; exit 2; }
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "${common_archive}" && -s "${common_archive}" ]] || { echo "error: common-base archive missing" >&2; exit 2; }
ar t "${common_archive}" | grep -Fq 'version.cpp.o' || { echo "error: common-base archive lacks version.cpp.o" >&2; exit 2; }
nm -C "${common_archive}" | grep -Fq 'wivrn::display_version()' || { echo "error: common-base archive lacks display_version symbol" >&2; exit 2; }
ninja -C build-server -t query server/wivrn-server >"${out}/ninja-query.txt"
grep -Fq 'helix_synthetic_transport.cpp.o' "${out}/ninja-query.txt" || { echo "error: final server graph lacks boundary transport object" >&2; exit 2; }
grep -Fq 'Linking CXX executable server/wivrn-server' "${out}/build-server.txt" || { echo "error: build log lacks final server link" >&2; exit 2; }
server="$(realpath build-server/server/wivrn-server)"
[[ -s "${server}" ]] || { echo "error: built server missing or empty" >&2; exit 2; }
printf 'server=%s\nserver_provenance=PASS generated-version-build-graph\n' "${server}" | tee -a "${out}/metadata.txt"

echo "[6/8] Building exact matching Quest APK"
./gradlew --no-daemon assembleDebug \
    -Pwivrn_version="${version_name}" \
    -Pwivrn_app_name="Helix Transport Boundary Map" \
    2>&1 | tee "${out}/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || { echo "error: expected exactly one debug APK, found ${#apks[@]}" >&2; exit 2; }
apk_source="$(realpath "${apks[0]}")"
[[ -s "${apk_source}" ]] || { echo "error: built APK missing or empty" >&2; exit 2; }
apk="${out}/helix-quest-transport-boundary-${source_commit:0:12}.apk"
cp -- "${apk_source}" "${apk}"
sha256sum "${apk}" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "${apk}" | tee -a "${out}/metadata.txt"
[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: source HEAD changed during builds" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree changed during builds" >&2; exit 2; }

echo "[7/8] Publishing only the exact compiled corrective checkpoint"
git fetch origin "${source_branch}"
[[ "$(git rev-parse "refs/remotes/origin/${source_branch}")" == "${failed_commit}" ]] || { echo "error: remote boundary branch moved during build" >&2; exit 2; }
git push origin "HEAD:refs/heads/${source_branch}" 2>&1 | tee "${out}/push.txt"

remote_after="$(git ls-remote origin "refs/heads/${source_branch}" | awk '{print $1}')"
[[ "${remote_after}" == "${source_commit}" ]] || { echo "error: published branch does not point at compiled corrective commit" >&2; exit 2; }
printf 'remote_head_after=%s\n' "${remote_after}" | tee -a "${out}/metadata.txt"

echo "[8/8] Final corrective artifact gate"
printf 'artifact_gate=PASS exact-commit-server-and-apk\ncompile_recovery=PASS unused-helper-class-closed\n' | tee -a "${out}/metadata.txt"
printf '\nPASS: boundary compile failure class closed; corrective server/APK built and exact compiled commit published.\n'
printf 'commit=%s\nbranch=%s\nserver=%s\napk=%s\nevidence=%s\n' \
    "${source_commit}" "${source_branch}" "${server}" "${apk}" "${out}"
printf 'STATUS: built only; not installed and boundary runtime not executed.\n'
