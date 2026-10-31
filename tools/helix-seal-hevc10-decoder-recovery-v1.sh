#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="b8c9cac4ecc63ca92984c0f02238a2d0263fad0e"
OUT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
META="$OUT/runtime-v1-metadata.txt"
SEAL="$OUT/runtime-v1-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep strings unzip find mktemp; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
git cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null || fail "source commit unavailable locally"
[[ -s "$META" ]] || fail "metadata missing"
[[ ! -e "$SEAL" ]] || fail "seal already exists"

getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
[[ "$(getm source_commit)" == "$SOURCE_COMMIT" ]] || fail "metadata source mismatch"
[[ "$(getm artifact_gate)" == 'PASS hevc10-decoder-recovery-v1-exact-source-server-apk' ]] || fail "metadata artifact gate mismatch"
[[ "$(getm server_marker_gate)" == 'PASS final-elf-hevc10-encoder-drop-exact-rtx-main10' ]] || fail "server marker gate mismatch"
[[ "$(getm apk_marker_gate)" == 'PASS final-arm64-native-rtx-assembly-mediacodec-aimage-probe' ]] || fail "APK marker gate mismatch"
[[ "$(getm runtime_status)" == 'NOT_RUN' ]] || fail "metadata runtime status is not NOT_RUN"
[[ "$(getm pixel_cleanliness)" == 'NOT_ESTABLISHED' ]] || fail "claim boundary mismatch"
[[ "$(getm runtime_oracle)" == 'exact-frame-correlation-per-eye-not-aggregate-counts' ]] || fail "runtime oracle mismatch"
[[ "$(getm probe_overflow_required)" == '0' ]] || fail "probe overflow contract mismatch"

hash_git_file(){ git show "$SOURCE_COMMIT:$1" | sha256sum | awk '{print $1}'; }
check_source_hash(){
  local key="$1" path="$2" actual expected
  expected="$(getm "$key")"
  actual="$(hash_git_file "$path")"
  [[ "$actual" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash for $path"
  [[ "$actual" == "$expected" ]] || fail "source hash mismatch for $path"
}
check_source_hash source_video_encoder_h_sha256 server/encoder/video_encoder.h
check_source_hash source_video_encoder_cpp_sha256 server/encoder/video_encoder.cpp
check_source_hash source_video_encoder_nvenc_cpp_sha256 server/encoder/video_encoder_nvenc.cpp
check_source_hash source_helix_diagnostics_h_sha256 client/decoder/helix_diagnostics.h
check_source_hash source_shard_accumulator_cpp_sha256 client/decoder/shard_accumulator.cpp
check_source_hash source_android_decoder_cpp_sha256 client/decoder/android/android_decoder.cpp

SERVER="$(getm server)"
APK="$(getm apk)"
[[ -s "$SERVER" && -x "$SERVER" ]] || fail "server artifact missing"
[[ -s "$APK" ]] || fail "APK artifact missing"
SERVER_SHA="$(sha256sum "$SERVER" | awk '{print $1}')"
APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
[[ "$SERVER_SHA" =~ ^[0-9a-f]{64}$ && "$APK_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid artifact hash"
[[ "$SERVER_SHA" == "$(getm server_sha256)" ]] || fail "server hash differs from metadata"
[[ "$APK_SHA" == "$(getm apk_sha256)" ]] || fail "APK hash differs from metadata"

SERVER_STRINGS="$(mktemp)"
APK_STRINGS="$(mktemp)"
APK_DIR="$(mktemp -d)"
trap 'rm -f "$SERVER_STRINGS" "$APK_STRINGS"; rm -rf "$APK_DIR"' EXIT
strings "$SERVER" > "$SERVER_STRINGS"
for marker in HELIX_HEVC10_ENCODER_GATE HELIX_HEVC10_FAULT_PLAN HELIX_HEVC10_DROP HELIX_HEVC10_RTX_SENT HELIX_HEVC10_MAIN10_PROFILE; do
  grep -Fq "$marker" "$SERVER_STRINGS" || fail "sealed server missing marker $marker"
done
unzip -qq "$APK" -d "$APK_DIR"
mapfile -t quest_libs < <(find "$APK_DIR/lib/arm64-v8a" -type f -name '*.so' -print 2>/dev/null)
[[ "${#quest_libs[@]}" -gt 0 ]] || fail "sealed APK arm64 native libraries missing"
for lib in "${quest_libs[@]}"; do strings "$lib" >> "$APK_STRINGS"; done
for marker in HELIX_HEVC10_RTX_ASSEMBLED HELIX_HEVC10_RTX_MEDIA_OUTPUT HELIX_HEVC10_IMAGE_AFTER_RTX HELIX_HEVC10_PROBE_SUMMARY; do
  grep -Fq "$marker" "$APK_STRINGS" || fail "sealed APK missing marker $marker"
done

META_SHA="$(sha256sum "$META" | awk '{print $1}')"
[[ "$META_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "invalid metadata hash"

cat > "$SEAL" <<EOF
artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers
source_commit=$SOURCE_COMMIT
build_tooling_commit=$BUILD_TOOLING_COMMIT
server_sha256=$SERVER_SHA
apk_sha256=$APK_SHA
metadata_sha256=$META_SHA
runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts
probe_overflow_required=0
pixel_cleanliness=NOT_ESTABLISHED
runtime_status=NOT_RUN
EOF

printf 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers\nsource_commit=%s\nbuild_tooling_commit=%s\nserver_sha256=%s\napk_sha256=%s\nmetadata_sha256=%s\nseal=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$SERVER_SHA" "$APK_SHA" "$META_SHA" "$SEAL"
