#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
OUT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
VERSION_NAME="helix-hevc10-decoder-recovery-v1-${SOURCE_COMMIT}"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git cmake ninja ar nm realpath grep find java sha256sum awk strings unzip; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "caller source mismatch"
[[ -z "$(git status --short)" ]] || fail "caller source tree dirty"
git cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null || fail "source commit unavailable locally"
[[ ! -e "$OUT" ]] || fail "runtime build root already exists: $OUT"

mkdir -p "$OUT"
WORKTREE="$OUT/worktree"
git worktree add --detach "$WORKTREE" "$SOURCE_COMMIT" >/dev/null
cd "$WORKTREE"
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "isolated source mismatch"
[[ -z "$(git status --porcelain)" ]] || fail "isolated source dirty"

# Source-semantic gate: refuse to build unless the exact committed source still
# carries the audited HEVC10 canary and Quest decoder evidence contracts.
grep -Fq 'HELIX_HEVC10_RECOVERY requires NVENC H.265 Main10 on both eye streams' server/encoder/video_encoder.cpp || fail "HEVC10 encoder gate missing"
grep -Fq 'HELIX_HEVC10_DROP' server/encoder/video_encoder.cpp || fail "HEVC10 drop marker missing"
grep -Fq 'HELIX_HEVC10_RTX_SENT' server/encoder/video_encoder.cpp || fail "HEVC10 exact RTX marker missing"
grep -Fq 'NV_ENC_HEVC_PROFILE_MAIN10_GUID' server/encoder/video_encoder_nvenc.cpp || fail "NVENC Main10 profile selection missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE' server/encoder/video_encoder_nvenc.cpp || fail "Main10 runtime marker missing"
grep -Fq 'HELIX_HEVC10_RTX_ASSEMBLED' client/decoder/shard_accumulator.cpp || fail "Quest RTX assembly marker missing"
grep -Fq 'HELIX_HEVC10_RTX_MEDIA_OUTPUT' client/decoder/android/android_decoder.cpp || fail "Quest MediaCodec marker missing"
grep -Fq 'HELIX_HEVC10_IMAGE_AFTER_RTX' client/decoder/android/android_decoder.cpp || fail "Quest image marker missing"
grep -Fq 'hevc10_probe_slots = 8' client/decoder/helix_diagnostics.h || fail "bounded Quest probe missing"
grep -Fq 'overflow' client/decoder/helix_diagnostics.h || fail "probe overflow accounting missing"

# Freeze hashes of every modified source file into build metadata.
SRC_VIDEO_H="$(sha256sum server/encoder/video_encoder.h | awk '{print $1}')"
SRC_VIDEO_CPP="$(sha256sum server/encoder/video_encoder.cpp | awk '{print $1}')"
SRC_NVENC_CPP="$(sha256sum server/encoder/video_encoder_nvenc.cpp | awk '{print $1}')"
SRC_DIAG_H="$(sha256sum client/decoder/helix_diagnostics.h | awk '{print $1}')"
SRC_ACC_CPP="$(sha256sum client/decoder/shard_accumulator.cpp | awk '{print $1}')"
SRC_ANDROID_CPP="$(sha256sum client/decoder/android/android_decoder.cpp | awk '{print $1}')"
for h in "$SRC_VIDEO_H" "$SRC_VIDEO_CPP" "$SRC_NVENC_CPP" "$SRC_DIAG_H" "$SRC_ACC_CPP" "$SRC_ANDROID_CPP"; do
  [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid source hash $h"
done

cat > "$OUT/runtime-v1-metadata.txt" <<EOF
source_commit=$SOURCE_COMMIT
version_name=$VERSION_NAME
source_video_encoder_h_sha256=$SRC_VIDEO_H
source_video_encoder_cpp_sha256=$SRC_VIDEO_CPP
source_video_encoder_nvenc_cpp_sha256=$SRC_NVENC_CPP
source_helix_diagnostics_h_sha256=$SRC_DIAG_H
source_shard_accumulator_cpp_sha256=$SRC_ACC_CPP
source_android_decoder_cpp_sha256=$SRC_ANDROID_CPP
encoder_contract=nvenc-h265-main10-both-eye-streams-runtime-hard-gate
fault_contract=one-cached-shard0-withheld-per-eye-ordinals-600-900-exact-packet-rtx-bound
decoder_contract=rtx-assembled-before-submit-exact-mediacodec-output-aimage-at-or-after-recovered-frame
runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts
probe_slots=8
probe_overflow_required=0
pixel_cleanliness=NOT_ESTABLISHED
runtime_status=NOT_RUN
EOF

printf '[1/4] Building exact committed wivrn-server\n'
cmake --preset server 2>&1 | tee "$OUT/configure-server.txt"
set +e
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "$OUT/build-server.txt"
status=${PIPESTATUS[0]}
set -e
(( status == 0 )) || exit "$status"

grep -Fq "const char git_commit[] = \"${SOURCE_COMMIT}\";" build-server/version.cpp || fail "generated version provenance mismatch"
common_archive="$(find build-server -type f -name 'libwivrn-common-base.a' -print -quit)"
[[ -n "$common_archive" && -s "$common_archive" ]] || fail "common-base archive missing"
ar t "$common_archive" | grep -Fq 'version.cpp.o' || fail "common-base lacks version object"
nm -C "$common_archive" | grep -Fq 'wivrn::display_version()' || fail "display_version symbol missing"
server_src="$(realpath build-server/server/wivrn-server)"
[[ -s "$server_src" && -x "$server_src" ]] || fail "built server missing"
SERVER="$OUT/wivrn-server-hevc10-recovery-v1"
cp -- "$server_src" "$SERVER"
chmod +x "$SERVER"
strings "$SERVER" > "$OUT/server-strings.txt"
for marker in HELIX_HEVC10_ENCODER_GATE HELIX_HEVC10_FAULT_PLAN HELIX_HEVC10_DROP HELIX_HEVC10_RTX_SENT HELIX_HEVC10_MAIN10_PROFILE; do
  grep -Fq "$marker" "$OUT/server-strings.txt" || fail "final server missing marker $marker"
done

printf '[2/4] Building exact matching Quest APK\n'
./gradlew --no-daemon assembleDebug \
  -Pwivrn_version="$VERSION_NAME" \
  -Pwivrn_app_name="Helix HEVC10 Recovery" \
  2>&1 | tee "$OUT/gradle-build.txt"
mapfile -t apks < <(find build/outputs/apk/debug -type f -name '*.apk' -print)
[[ "${#apks[@]}" -eq 1 ]] || fail "expected exactly one debug APK, found ${#apks[@]}"
APK="$OUT/helix-hevc10-recovery-${SOURCE_COMMIT:0:12}.apk"
cp -- "$(realpath "${apks[0]}")" "$APK"
[[ -s "$APK" ]] || fail "APK missing"

APK_INSPECT="$OUT/apk-inspect"
mkdir -p "$APK_INSPECT"
unzip -qq "$APK" -d "$APK_INSPECT"
mapfile -t quest_libs < <(find "$APK_INSPECT/lib/arm64-v8a" -type f -name '*.so' -print 2>/dev/null)
[[ "${#quest_libs[@]}" -gt 0 ]] || fail "APK arm64 native libraries missing"
: > "$OUT/apk-native-strings.txt"
for lib in "${quest_libs[@]}"; do strings "$lib" >> "$OUT/apk-native-strings.txt"; done
for marker in HELIX_HEVC10_RTX_ASSEMBLED HELIX_HEVC10_RTX_MEDIA_OUTPUT HELIX_HEVC10_IMAGE_AFTER_RTX HELIX_HEVC10_PROBE_SUMMARY; do
  grep -Fq "$marker" "$OUT/apk-native-strings.txt" || fail "final APK native libraries missing marker $marker"
done
rm -rf "$APK_INSPECT"

printf '[3/4] Hashing artifacts and rechecking source provenance\n'
SERVER_SHA="$(sha256sum "$SERVER" | awk '{print $1}')"
APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
for h in "$SERVER_SHA" "$APK_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid artifact hash $h"; done
[[ "$(git rev-parse HEAD)" == "$SOURCE_COMMIT" ]] || fail "source HEAD changed during build"
[[ -z "$(git status --porcelain)" ]] || { git status --short >&2; fail "source tree changed during build"; }

cat >> "$OUT/runtime-v1-metadata.txt" <<EOF
server=$SERVER
server_sha256=$SERVER_SHA
apk=$APK
apk_sha256=$APK_SHA
server_marker_gate=PASS final-elf-hevc10-encoder-drop-exact-rtx-main10
apk_marker_gate=PASS final-arm64-native-rtx-assembly-mediacodec-aimage-probe
artifact_gate=PASS hevc10-decoder-recovery-v1-exact-source-server-apk
EOF

printf '[4/4] Build gate complete\n'
printf 'BUILD_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk\nsource_commit=%s\nserver_sha256=%s\napk_sha256=%s\nserver=%s\napk=%s\nevidence=%s\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$SERVER_SHA" "$APK_SHA" "$SERVER" "$APK" "$OUT"
