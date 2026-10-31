#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BUILD_TOOLING_COMMIT="b8c9cac4ecc63ca92984c0f02238a2d0263fad0e"
SEAL_TOOLING_COMMIT="f18d7eded6dc4cf69a4a80190330798f73d53184"
OUT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
META="$OUT/runtime-v1-metadata.txt"
SEAL="$OUT/runtime-v1-seal.txt"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git sha256sum awk grep strings unzip find mktemp python3; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
git cat-file -e "${SOURCE_COMMIT}^{commit}" 2>/dev/null || fail "source commit unavailable locally"
[[ -s "$META" && -s "$SEAL" ]] || fail "metadata or seal missing"

getm(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$META" | tail -1; }
gets(){ awk -F= -v k="$1" '$1==k{print substr($0,index($0,"=")+1)}' "$SEAL" | tail -1; }

[[ "$(gets artifact_seal)" == 'PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' ]] || fail "seal marker mismatch"
[[ "$(gets source_commit)" == "$SOURCE_COMMIT" ]] || fail "seal source mismatch"
[[ "$(gets build_tooling_commit)" == "$BUILD_TOOLING_COMMIT" ]] || fail "seal build tooling mismatch"
[[ "$(gets runtime_status)" == 'NOT_RUN' ]] || fail "seal runtime status mismatch"
[[ "$(gets runtime_oracle)" == 'exact-frame-correlation-per-eye-not-aggregate-counts' ]] || fail "seal runtime oracle mismatch"
[[ "$(gets probe_overflow_required)" == '0' ]] || fail "seal overflow contract mismatch"
[[ "$(gets pixel_cleanliness)" == 'NOT_ESTABLISHED' ]] || fail "seal claim boundary mismatch"

[[ "$(getm source_commit)" == "$SOURCE_COMMIT" ]] || fail "metadata source mismatch"
[[ "$(getm runtime_status)" == 'NOT_RUN' ]] || fail "metadata runtime status mismatch"
[[ "$(getm runtime_oracle)" == 'exact-frame-correlation-per-eye-not-aggregate-counts' ]] || fail "metadata runtime oracle mismatch"
[[ "$(getm probe_overflow_required)" == '0' ]] || fail "metadata overflow contract mismatch"
[[ "$(getm pixel_cleanliness)" == 'NOT_ESTABLISHED' ]] || fail "metadata claim boundary mismatch"

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

# Independently inspect exact committed source semantics and ordering.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
for path in \
  server/encoder/video_encoder.cpp \
  server/encoder/video_encoder_nvenc.cpp \
  client/decoder/helix_diagnostics.h \
  client/decoder/shard_accumulator.cpp \
  client/decoder/android/android_decoder.cpp; do
  mkdir -p "$TMP/$(dirname "$path")"
  git show "$SOURCE_COMMIT:$path" > "$TMP/$path"
done
python3 - "$TMP" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
server = (root/'server/encoder/video_encoder.cpp').read_text()
nvenc = (root/'server/encoder/video_encoder_nvenc.cpp').read_text()
diag = (root/'client/decoder/helix_diagnostics.h').read_text()
acc = (root/'client/decoder/shard_accumulator.cpp').read_text()
android = (root/'client/decoder/android/android_decoder.cpp').read_text()

def need(text, marker, label):
    if marker not in text:
        raise SystemExit(f'FAIL: missing {label}: {marker}')

for marker in ['HELIX_HEVC10_ENCODER_GATE','HELIX_HEVC10_FAULT_PLAN','HELIX_HEVC10_DROP','HELIX_HEVC10_RTX_SENT']:
    need(server, marker, 'server marker')
need(server, 'shard.shard_idx == 0', 'shard0 drop condition')
need(server, 'helix_hevc10_fault_target_ordinal = stream_idx == 0 ? 600 : 900', 'per-eye ordinals')
need(server, 'helix_hevc10_fault_packet_sequence = shard.packet_sequence', 'exact packet binding')
need(nvenc, 'NV_ENC_HEVC_PROFILE_MAIN10_GUID', 'Main10 profile')
need(nvenc, 'inputBitDepth = bitDepth', 'input bit depth assignment')
need(nvenc, 'outputBitDepth = bitDepth', 'output bit depth assignment')
need(nvenc, 'HELIX_HEVC10_MAIN10_PROFILE', 'Main10 marker')
need(diag, 'hevc10_probe_slots = 8', 'bounded ledger')
need(diag, 'overflow++', 'overflow accounting')
need(acc, 'HELIX_HEVC10_RTX_ASSEMBLED', 'RTX assembled marker')
need(android, 'HELIX_HEVC10_RTX_MEDIA_OUTPUT', 'MediaCodec output marker')
need(android, 'HELIX_HEVC10_IMAGE_AFTER_RTX', 'AImage marker')
need(android, 'hevc10_note_media_output(self->stream_index, frame_index)', 'stream-index exact media correlation')
if server.find('helix_rtx_cache.push_back') < 0 or server.find('const bool helix_hevc10_drop') < 0:
    raise SystemExit('FAIL: cache/drop anchors missing')
if server.find('helix_rtx_cache.push_back') > server.find('const bool helix_hevc10_drop'):
    raise SystemExit('FAIL: canary drop precedes ordinary RTX cache insertion')
if acc.find('hevc10_note_rtx_assembled') > acc.find('decoder_->frame_completed'):
    raise SystemExit('FAIL: RTX probe is armed after decoder submission')
for forbidden in ['HELIX_HEVC10_RTX_DECODED','sent_to_decoder == recovery','pixel_cleanliness=PASS']:
    if forbidden in server+nvenc+diag+acc+android:
        raise SystemExit(f'FAIL: forbidden stale/overclaim marker present: {forbidden}')
print('SOURCE_SEMANTICS=PASS cache-before-drop exact-packet-bound pre-submit-probe exact-mediacodec-output bounded-ledger')
PY

SERVER="$(getm server)"
APK="$(getm apk)"
[[ -s "$SERVER" && -x "$SERVER" ]] || fail "server artifact missing"
[[ -s "$APK" ]] || fail "APK artifact missing"
SERVER_SHA="$(sha256sum "$SERVER" | awk '{print $1}')"
APK_SHA="$(sha256sum "$APK" | awk '{print $1}')"
META_SHA="$(sha256sum "$META" | awk '{print $1}')"
for h in "$SERVER_SHA" "$APK_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid hash $h"; done
[[ "$SERVER_SHA" == "$(getm server_sha256)" && "$SERVER_SHA" == "$(gets server_sha256)" ]] || fail "server hash binding mismatch"
[[ "$APK_SHA" == "$(getm apk_sha256)" && "$APK_SHA" == "$(gets apk_sha256)" ]] || fail "APK hash binding mismatch"
[[ "$META_SHA" == "$(gets metadata_sha256)" ]] || fail "metadata hash binding mismatch"

SERVER_STRINGS="$TMP/server-strings.txt"
APK_STRINGS="$TMP/apk-strings.txt"
strings "$SERVER" > "$SERVER_STRINGS"
for marker in HELIX_HEVC10_ENCODER_GATE HELIX_HEVC10_FAULT_PLAN HELIX_HEVC10_DROP HELIX_HEVC10_RTX_SENT HELIX_HEVC10_MAIN10_PROFILE; do
  grep -Fq "$marker" "$SERVER_STRINGS" || fail "final server missing marker $marker"
done
APK_DIR="$TMP/apk"
mkdir -p "$APK_DIR"
unzip -qq "$APK" -d "$APK_DIR"
mapfile -t quest_libs < <(find "$APK_DIR/lib/arm64-v8a" -type f -name '*.so' -print 2>/dev/null)
[[ "${#quest_libs[@]}" -gt 0 ]] || fail "APK arm64 native libraries missing"
: > "$APK_STRINGS"
for lib in "${quest_libs[@]}"; do strings "$lib" >> "$APK_STRINGS"; done
for marker in HELIX_HEVC10_RTX_ASSEMBLED HELIX_HEVC10_RTX_MEDIA_OUTPUT HELIX_HEVC10_IMAGE_AFTER_RTX HELIX_HEVC10_PROBE_SUMMARY; do
  grep -Fq "$marker" "$APK_STRINGS" || fail "final APK missing marker $marker"
done

printf 'AUDIT_A=PASS hevc10-decoder-recovery-v1-exact-source-all-source-hashes-final-binary-markers\n'
printf 'AUDIT_B=PASS cache-before-drop-exact-packet-rtx-pre-submit-mediacodec-aimage-bounded-ledger\n'
printf 'source_commit=%s\nbuild_tooling_commit=%s\nseal_tooling_commit=%s\nserver_sha256=%s\napk_sha256=%s\nmetadata_sha256=%s\nruntime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts\nprobe_overflow_required=0\npixel_cleanliness=NOT_ESTABLISHED\nRUNTIME=NOT_RUN\n' \
  "$SOURCE_COMMIT" "$BUILD_TOOLING_COMMIT" "$SEAL_TOOLING_COMMIT" "$SERVER_SHA" "$APK_SHA" "$META_SHA"
