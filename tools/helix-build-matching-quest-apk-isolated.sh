#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "${repo_root}" ]]; then
    echo "error: run this from inside the WiVRn checkout" >&2
    exit 2
fi
cd "${repo_root}"

source_commit="a315a97f9bd39923a5249365f6fef1b73aa5b452"
branch="helix-quest-transport-torture"
version_name="helix-${source_commit}"

for cmd in git java sha256sum find realpath rsvg-convert; do
    command -v "${cmd}" >/dev/null 2>&1 || { echo "error: missing command ${cmd}" >&2; exit 2; }
done

# Make sure the published torture branch still contains the exact compiled source commit.
git fetch origin "${branch}"
git merge-base --is-ancestor "${source_commit}" "refs/remotes/origin/${branch}" || {
    echo "error: ${source_commit} is no longer an ancestor of origin/${branch}" >&2
    exit 2
}

out="${HOME}/helix-quest-apk-${source_commit:0:12}-$(date +%Y%m%d-%H%M%S)"
mkdir -p "${out}"
worktree="${out}/worktree"

git worktree add --detach "${worktree}" "${source_commit}" >/dev/null
cd "${worktree}"
[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: wrong detached source commit" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: isolated APK worktree dirty at creation" >&2; exit 2; }

printf 'source_commit=%s\nversion_name=%s\n' "${source_commit}" "${version_name}" >"${out}/metadata.txt"

echo "[1/4] Building exact matching Quest debug APK"
./gradlew --no-daemon assembleDebug \
    -Pwivrn_version="${version_name}" \
    -Pwivrn_app_name="Helix Transport Torture" \
    2>&1 | tee "${out}/gradle-build.txt"

echo "[2/4] Locating APK"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || {
    echo "error: expected exactly one debug APK, found ${#apks[@]}" >&2
    printf '%s\n' "${apks[@]}" >&2
    exit 2
}
apk="$(realpath "${apks[0]}")"
[[ -s "${apk}" ]] || { echo "error: APK missing or empty" >&2; exit 2; }

echo "[3/4] Preserving exact artifact and provenance"
artifact="${out}/helix-quest-transport-torture-${source_commit:0:12}.apk"
cp -- "${apk}" "${artifact}"
sha256sum "${artifact}" | tee "${out}/apk.sha256"
printf 'apk=%s\n' "${artifact}" | tee -a "${out}/metadata.txt"

# Confirm the Android native build really came from the exact detached source tree.
[[ "$(git rev-parse HEAD)" == "${source_commit}" ]] || { echo "error: source HEAD changed during APK build" >&2; exit 2; }
[[ -z "$(git status --porcelain)" ]] || { echo "error: source worktree changed during APK build" >&2; git status --short >&2; exit 2; }

echo "[4/4] APK gate complete"
printf '\nPASS: exact matching Quest APK built from torture source commit.\n'
printf 'source_commit=%s\nversion_name=%s\napk=%s\nevidence=%s\n' "${source_commit}" "${version_name}" "${artifact}" "${out}"
printf 'STATUS: APK built only; not installed and torture runtime not executed.\n'
