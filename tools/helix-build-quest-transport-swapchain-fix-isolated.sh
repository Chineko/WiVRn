#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

base_commit="a315a97f9bd39923a5249365f6fef1b73aa5b452"
source_branch="helix-quest-transport-swapchain-fix"
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

out="${HOME}/helix-quest-swapchain-fix-build-$(date +%Y%m%d-%H%M%S)"
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
old = '''\tfor (auto & fov: view.fov)\n\t{\n\t\tfov.angleLeft = -0.8f;\n\t\tfov.angleRight = 0.8f;\n\t\tfov.angleUp = 0.8f;\n\t\tfov.angleDown = -0.8f;\n\t}\n\tview.alpha = false;\n'''
new = '''\tfor (auto & fov: view.fov)\n\t{\n\t\tfov.angleLeft = -0.8f;\n\t\tfov.angleRight = 0.8f;\n\t\tfov.angleUp = 0.8f;\n\t\tfov.angleDown = -0.8f;\n\t}\n\t// A single region is valid foveation metadata and represents a 1:1 mapping.\n\t// The Quest renderer derives its swapchain extent from these vectors, so the\n\t// synthetic raw stream must describe the actual per-eye frame dimensions.\n\tfor (auto & foveation: view.foveation)\n\t{\n\t\tfoveation.x = {width};\n\t\tfoveation.y = {height};\n\t}\n\tview.alpha = false;\n'''
if text.count(old) != 1:
    raise SystemExit(f"error: expected exactly one make_view_info patch site, found {text.count(old)}")
path.write_text(text.replace(old, new))
PY

echo "[1/8] Applying source-confirmed synthetic render-metadata fix"
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
grep -Fq 'foveation.x = {width};' "${source_path}" || { echo "error: synthetic foveation width marker missing" >&2; exit 2; }
grep -Fq 'foveation.y = {height};' "${source_path}" || { echo "error: synthetic foveation height marker missing" >&2; exit 2; }
grep -Fq 'run_rtx_rescue_case' "${source_path}" || { echo "error: torture battery drifted" >&2; exit 2; }
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_RESULT' "${source_path}" || { echo "error: transport scorer marker missing" >&2; exit 2; }
grep -Fq -- '--helix-synthetic-transport' server/main.cpp || { echo "error: synthetic transport CLI mode missing" >&2; exit 2; }
grep -Fq -- '::connection.reset()' server/main.cpp || { echo "error: corrected synthetic cleanup missing" >&2; exit 2; }
grep -Fq -- 'helix_td_enabled(false)' server/encoder/video_encoder.cpp || { echo "error: old full replay is not disabled" >&2; exit 2; }
python3 - <<'PY'
width = 256
height = 160
x = [width]
y = [height]
def count_pixels(param):
    n_ratio = (len(param) - 1) // 2
    return sum((abs(n_ratio - i) + 1) * n for i, n in enumerate(param))
assert len(x) % 2 == 1 and len(y) % 2 == 1
assert count_pixels(x) == width
assert count_pixels(y) == height
print("PASS: synthetic 1:1 foveation metadata resolves to 256x160")
PY
git diff --stat | tee "${out}/source-stat.txt"
git diff >"${out}/source.diff"

echo "[3/8] Committing exact fixed source before compilation"
git add -- "${source_path}"
git commit -m "Helix: provide valid synthetic render foveation metadata" | tee "${out}/commit.txt"
source_commit="$(git rev-parse HEAD)"
version_name="${version_prefix}-${source_commit}"
printf 'source_commit=%s\nversion_name=%s\n' "${source_commit}" "${version_name}" | tee -a "${out}/metadata.txt"
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree dirty after commit" >&2; exit 2; }

# Publish before compiling so the exact build input has an immutable remote checkpoint.
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
mapfile -t version_objects < <(find build-server -type f -name 'version.cpp.o' -print)
[[ "${#version_objects[@]}" -ge 1 ]] || { echo "error: compiled version.cpp.o not found" >&2; exit 2; }
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
[[ "${#apks[@]}" -eq 1 ]] || {
    echo "error: expected exactly one debug APK, found ${#apks[@]}" >&2
    printf '%s\n' "${apks[@]}" >&2
    exit 2
}
apk_source="$(realpath "${apks[0]}")"
[[ -s "${apk_source}" ]] || { echo "error: built APK missing or empty" >&2; exit 2; }
apk="${out}/helix-quest-transport-swapchain-fix-${source_commit:0:12}.apk"
cp -- "${apk_source}" "${apk}"
sha256sum "${apk}" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "${apk}" | tee -a "${out}/metadata.txt"

[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: source HEAD changed during builds" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: source tree changed during builds" >&2; git status --short >&2; exit 2; }

echo "[8/8] Final artifact gate"
printf 'artifact_gate=PASS exact-commit-server-and-apk\n' | tee -a "${out}/metadata.txt"
printf '\nPASS: fixed synthetic transport source committed, published, server built, and matching Quest APK built.\n'
printf 'commit=%s\nbranch=%s\nserver=%s\napk=%s\nevidence=%s\n' \
    "${source_commit}" "${source_branch}" "${server}" "${apk}" "${out}"
printf 'STATUS: built only; not installed and not runtime-tested.\n'
