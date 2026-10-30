#!/usr/bin/env bash
set -euo pipefail

RUNNER_COMMIT="705885628d940950c1234fe4cc8faa8b77f37311"
RUNNER_PATH="tools/helix-run-encoded-network-sustained-v1.sh"
SOURCE="716e5280c327c43fc95d555c42e0dea9c48c89a9"
BRANCH="helix-encoded-sustained-torture-v1-built"
BUILD="$HOME/helix-encoded-sustained-torture-v1-build-20261030-214240"
META="$BUILD/metadata.txt"
SERVER="$BUILD/worktree/build-everything/server/wivrn-server"
MANIFEST="$BUILD/worktree/build-everything/openxr_wivrn-dev.json"
APK="$BUILD/helix-encoded-sustained-torture-v1-716e5280c327.apk"
WORKTREE="$BUILD/worktree"
V5="$HOME/helix-encoded-nvenc-build-20261030-160211"
SEAL="$V5/vulkan-stimulus-v5-seal.txt"
V5_SRC="$V5/helix_vulkan_stimulus_v5.cpp"
V5_BIN="$V5/helix-vulkan-stimulus-v5"
V5_META="$V5/vulkan-stimulus-v5-metadata.txt"

fail(){ echo "AUDIT_FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk sed grep mktemp; do command -v "$c" >/dev/null 2>&1 || fail "missing command: $c"; done

runner="$(mktemp)"
trap 'rm -f "$runner"' EXIT INT TERM
git cat-file -e "${RUNNER_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$RUNNER_COMMIT"
git show "${RUNNER_COMMIT}:${RUNNER_PATH}" >"$runner"
[[ -s "$runner" ]] || fail "pinned runner unavailable"

printf 'AUDIT_SECTION=files\n'
for f in "$META" "$SERVER" "$MANIFEST" "$APK" "$SEAL" "$V5_SRC" "$V5_BIN" "$V5_META"; do
  [[ -s "$f" ]] || fail "missing_or_empty=$f"
  printf 'PASS file=%s\n' "$f"
done

printf 'AUDIT_SECTION=source\n'
worktree_head="$(git -C "$WORKTREE" rev-parse HEAD 2>/dev/null || true)"
remote_head="$(git ls-remote origin "refs/heads/$BRANCH" | awk '{print $1}')"
printf 'source_expected=%s\nworktree_head=%s\nremote_head=%s\n' "$SOURCE" "$worktree_head" "$remote_head"
[[ "$worktree_head" == "$SOURCE" ]] || fail "worktree_head_mismatch"
[[ "$remote_head" == "$SOURCE" ]] || fail "remote_head_mismatch"
tracked_dirty="$(git -C "$WORKTREE" status --porcelain --untracked-files=no)"
[[ -z "$tracked_dirty" ]] || { printf '%s\n' "$tracked_dirty"; fail "tracked_worktree_dirty"; }
printf 'PASS tracked_worktree_clean\n'
untracked="$(git -C "$WORKTREE" ls-files --others --exclude-standard)"
if [[ -n "$untracked" ]]; then
  printf 'INFO untracked_begin\n%s\nINFO untracked_end\n' "$untracked"
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    case "$p" in
      build-everything/*|server/encoder/video_encoder.cpp|server/helix_synthetic_transport.cpp)
        fail "untracked_overlaps_runtime_input=$p"
        ;;
    esac
  done <<<"$untracked"
fi

printf 'AUDIT_SECTION=metadata\n'
grep -E '^(source_base|transform_commit|source_commit|version_name|remote_head|server|openxr_manifest|apk|server_sha256|apk_sha256|server_provenance|artifact_gate)=' "$META" || true

printf 'AUDIT_SECTION=server_hash\n'
server_actual="$(sha256sum "$SERVER" | awk '{print $1}')"
server_meta="$(sed -n 's/^server_sha256=//p' "$META" | tail -1)"
server_runner="$(sed -n 's/^SERVER_SHA256="\([^"]*\)"/\1/p' "$runner")"
printf 'server_actual=%s\nserver_metadata=%s\nserver_runner=%s\n' "$server_actual" "$server_meta" "$server_runner"
[[ "$server_actual" == "$server_meta" ]] || fail "server_actual_vs_metadata_mismatch"
[[ "$server_actual" == "$server_runner" ]] || fail "server_actual_vs_runner_mismatch"
[[ "$server_meta" == "$server_runner" ]] || fail "server_metadata_vs_runner_mismatch"

printf 'AUDIT_SECTION=apk_hash\n'
apk_actual="$(sha256sum "$APK" | awk '{print $1}')"
apk_meta="$(sed -n 's/^apk_sha256=//p' "$META" | tail -1)"
apk_runner="$(sed -n 's/^APK_SHA256="\([^"]*\)"/\1/p' "$runner")"
printf 'apk_actual=%s\napk_metadata=%s\napk_runner=%s\n' "$apk_actual" "$apk_meta" "$apk_runner"
[[ "$apk_actual" == "$apk_meta" ]] || fail "apk_actual_vs_metadata_mismatch"
[[ "$apk_actual" == "$apk_runner" ]] || fail "apk_actual_vs_runner_mismatch"
[[ "$apk_meta" == "$apk_runner" ]] || fail "apk_metadata_vs_runner_mismatch"

printf 'AUDIT_SECTION=paths\n'
[[ "$(sed -n 's/^server=//p' "$META" | tail -1)" == "$SERVER" ]] || fail "server_path_mismatch"
[[ "$(sed -n 's/^openxr_manifest=//p' "$META" | tail -1)" == "$MANIFEST" ]] || fail "manifest_path_mismatch"
[[ "$(sed -n 's/^apk=//p' "$META" | tail -1)" == "$APK" ]] || fail "apk_path_mismatch"
printf 'PASS server_path\nPASS manifest_path\nPASS apk_path\n'

printf 'AUDIT_SECTION=source_semantics\n'
grep -Fq "const char git_commit[] = \"$SOURCE\";" "$WORKTREE/build-everything/version.cpp" || fail "version_cpp_source_mismatch"
git show "$SOURCE:server/encoder/video_encoder.cpp" | grep -Fq 'HELIX_ENCODED_TORTURE_CYCLES' || fail "cycles_source_missing"
git show "$SOURCE:server/encoder/video_encoder.cpp" | grep -Fq 'HELIX_ENCODED_TORTURE_SPACING_FRAMES' || fail "spacing_source_missing"
git show "$SOURCE:server/encoder/video_encoder.cpp" | grep -Fq 'switch (helix_encoded_torture.next_case % 3u)' || fail "cycling_source_missing"
printf 'PASS source_semantics\n'

printf 'AUDIT_SECTION=vulkan_v5\n'
v5_src_actual="$(sha256sum "$V5_SRC" | awk '{print $1}')"
v5_bin_actual="$(sha256sum "$V5_BIN" | awk '{print $1}')"
v5_meta_actual="$(sha256sum "$V5_META" | awk '{print $1}')"
v5_src_want="$(sed -n 's/^source_sha256=//p' "$SEAL" | tail -1)"
v5_bin_want="$(sed -n 's/^binary_sha256=//p' "$SEAL" | tail -1)"
v5_meta_want="$(sed -n 's/^metadata_sha256=//p' "$SEAL" | tail -1)"
printf 'v5_source_actual=%s\nv5_source_seal=%s\nv5_binary_actual=%s\nv5_binary_seal=%s\nv5_metadata_actual=%s\nv5_metadata_seal=%s\n' "$v5_src_actual" "$v5_src_want" "$v5_bin_actual" "$v5_bin_want" "$v5_meta_actual" "$v5_meta_want"
[[ "$v5_src_actual" == "$v5_src_want" ]] || fail "v5_source_hash_mismatch"
[[ "$v5_bin_actual" == "$v5_bin_want" ]] || fail "v5_binary_hash_mismatch"
[[ "$v5_meta_actual" == "$v5_meta_want" ]] || fail "v5_metadata_hash_mismatch"
grep -Fq 'artifact_seal=PASS strict-v5-source-binary-metadata-deps' "$SEAL" || fail "v5_artifact_seal_missing"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$V5_META" || fail "v5_stimulus_contract_missing"
printf 'PASS vulkan_v5\n'

printf 'AUDIT_SECTION=runner_identity\n'
grep -E '^(SOURCE_COMMIT|SOURCE_BRANCH|BUILD_ROOT|META|SERVER|MANIFEST|APK|SERVER_SHA256|APK_SHA256|VERSION_NAME|V5_ROOT|SEAL|VULKAN_META|DRIVER)=' "$runner"

printf 'SUSTAINED_ARTIFACT_AUDIT=PASS exact-source-server-apk-vulkan-bindings\n'
