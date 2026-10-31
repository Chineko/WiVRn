#!/usr/bin/env bash
set -euo pipefail

SOURCE_COMMIT="392bb662ed20c6866af0942d219359518a885193"
BASE_RUNNER_COMMIT="0df0d1fead1189e01293cc61e2a4dff56f0490c0"
RUNNER_TOOLING_COMMIT="0bfb4c6092498cae7be8e32d2199490589f75f35"
RUNNER_PATH="tools/helix-run-hevc10-decoder-recovery-v1-fixed.sh"
OUT_ROOT="$HOME/helix-hevc10-decoder-recovery-v1-runtime"
META="$OUT_ROOT/runtime-v1-metadata.txt"
SEAL="$OUT_ROOT/runtime-v1-seal.txt"
SERVER="$OUT_ROOT/wivrn-server-hevc10-recovery-v1"
APK="$OUT_ROOT/helix-hevc10-recovery-392bb662ed20.apk"
SERVER_SHA256="98d0b826f265fd971ec7bbff12549df5d25bb084541d4658e34a32a3440a144d"
APK_SHA256="cc25eb612e7a81004d6c59979707b3f70b8dedbf23794f4135c91f80d5a6e087"
META_SHA256="88c1358ee2b27a3fbff9c0f7893cb625af1730a81db6aa05c552bf51b48d3fa1"
STIM_ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
STIM_SRC="$STIM_ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
STIM_BIN="$STIM_ROOT/helix-vulkan-stimulus-sustained-v1"
STIM_META="$STIM_ROOT/vulkan-stimulus-sustained-v1-metadata.txt"
STIM_SEAL="$STIM_ROOT/vulkan-stimulus-sustained-v1-seal.txt"
STIM_SRC_SHA256="619ef17b9799c235cc51f03ac09dbf6c2c72ace645f0346ecea9fa72c8e63082"
STIM_BIN_SHA256="dc5394643e99a8e4b9ad574c9b1fac0b05df43fa474a9e8ace15c0c534a85d9a"
STIM_META_SHA256="9e4d43149e35fea58b8762933a90a04e5ff22e34a6f7bf3e657e0686fb69bdef"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git bash python3 grep awk sha256sum mktemp cp find; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run inside WiVRn checkout"
cd "$repo_root"
for commit in "$SOURCE_COMMIT" "$BASE_RUNNER_COMMIT" "$RUNNER_TOOLING_COMMIT"; do
  git cat-file -e "${commit}^{commit}" 2>/dev/null || git fetch origin "$commit"
  git cat-file -e "${commit}^{commit}" 2>/dev/null || fail "required commit unavailable: $commit"
done

wrapper="$(mktemp)"
final="$(mktemp)"
config_cpp="$(mktemp)"
settings_cpp="$(mktemp)"
video_cpp="$(mktemp)"
nvenc_cpp="$(mktemp)"
acc_cpp="$(mktemp)"
diag_h="$(mktemp)"
android_cpp="$(mktemp)"
trap 'rm -f "$wrapper" "$final" "$config_cpp" "$settings_cpp" "$video_cpp" "$nvenc_cpp" "$acc_cpp" "$diag_h" "$android_cpp"' EXIT INT TERM

git show "$RUNNER_TOOLING_COMMIT:$RUNNER_PATH" >"$wrapper"
bash -n "$wrapper"
grep -Fqx 'BASE_RUNNER_COMMIT="0df0d1fead1189e01293cc61e2a4dff56f0490c0"' "$wrapper" || fail "wrapper base runner binding mismatch"
grep -Fq 'stale seal marker anchor count=' "$wrapper" || fail "wrapper does not require unique seal-marker substitution"
grep -Fq 'RUNTIME_RUNNER_EMIT=PASS corrected-seal-marker-final-script-not-executed' "$wrapper" || fail "emit-only contract missing"
bash "$wrapper" --emit-only "$final" >"$final.emit.txt"
grep -Fqx 'RUNTIME=NOT_RUN' "$final.emit.txt" || fail "emit-only path did not preserve NOT_RUN"
bash -n "$final"

# Audit A: exact local artifacts and all fixed cryptographic bindings.
for f in "$META" "$SEAL" "$SERVER" "$APK" "$STIM_SRC" "$STIM_BIN" "$STIM_META" "$STIM_SEAL"; do [[ -s "$f" ]] || fail "artifact missing: $f"; done
[[ "$(sha256sum "$SERVER" | awk '{print $1}')" == "$SERVER_SHA256" ]] || fail "server hash mismatch"
[[ "$(sha256sum "$APK" | awk '{print $1}')" == "$APK_SHA256" ]] || fail "APK hash mismatch"
[[ "$(sha256sum "$META" | awk '{print $1}')" == "$META_SHA256" ]] || fail "metadata hash mismatch"
[[ "$(sha256sum "$STIM_SRC" | awk '{print $1}')" == "$STIM_SRC_SHA256" ]] || fail "stimulus source hash mismatch"
[[ "$(sha256sum "$STIM_BIN" | awk '{print $1}')" == "$STIM_BIN_SHA256" ]] || fail "stimulus binary hash mismatch"
[[ "$(sha256sum "$STIM_META" | awk '{print $1}')" == "$STIM_META_SHA256" ]] || fail "stimulus metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' "$SEAL" || fail "runtime seal marker mismatch"
grep -Fqx "source_commit=$SOURCE_COMMIT" "$SEAL" || fail "runtime seal source mismatch"
grep -Fqx "server_sha256=$SERVER_SHA256" "$SEAL" || fail "runtime seal server mismatch"
grep -Fqx "apk_sha256=$APK_SHA256" "$SEAL" || fail "runtime seal APK mismatch"
grep -Fqx "metadata_sha256=$META_SHA256" "$SEAL" || fail "runtime seal metadata mismatch"
grep -Fqx 'runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts' "$SEAL" || fail "runtime seal oracle mismatch"
grep -Fqx 'probe_overflow_required=0' "$SEAL" || fail "runtime seal overflow contract mismatch"
grep -Fqx 'pixel_cleanliness=NOT_ESTABLISHED' "$SEAL" || fail "runtime seal claim boundary mismatch"
grep -Fqx "source_sha256=$STIM_SRC_SHA256" "$STIM_SEAL" || fail "stimulus seal source mismatch"
grep -Fqx "binary_sha256=$STIM_BIN_SHA256" "$STIM_SEAL" || fail "stimulus seal binary mismatch"
grep -Fqx "metadata_sha256=$STIM_META_SHA256" "$STIM_SEAL" || fail "stimulus seal metadata mismatch"
grep -Fqx 'artifact_seal=PASS sustained-v1-frozen-v5-single-deadline-delta-source-binary-metadata-deps' "$STIM_SEAL" || fail "stimulus seal marker mismatch"

# The final emitted runner must contain the corrected file marker, never the terminal-only label.
grep -Fq "grep -Fqx 'artifact_seal=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers' \"\$SEAL\"" "$final" || fail "final runner corrected seal check missing"
! grep -Fq "grep -Fqx 'SEAL_GATE=PASS hevc10-decoder-recovery-v1-exact-source-server-apk-final-binary-markers'" "$final" || fail "final runner stale seal check remains"
for binding in \
  "SOURCE_COMMIT=\"$SOURCE_COMMIT\"" \
  "SERVER_SHA256=\"$SERVER_SHA256\"" \
  "APK_SHA256=\"$APK_SHA256\"" \
  "META_SHA256=\"$META_SHA256\"" \
  "STIM_SRC_SHA256=\"$STIM_SRC_SHA256\"" \
  "STIM_BIN_SHA256=\"$STIM_BIN_SHA256\"" \
  "STIM_META_SHA256=\"$STIM_META_SHA256\""; do
  grep -Fq "$binding" "$final" || fail "final runner binding missing: $binding"
done

# Audit B: source-level config/codec/fault/decoder semantics at the exact source commit.
git show "$SOURCE_COMMIT:server/driver/configuration.cpp" >"$config_cpp"
git show "$SOURCE_COMMIT:server/encoder/encoder_settings.cpp" >"$settings_cpp"
git show "$SOURCE_COMMIT:server/encoder/video_encoder.cpp" >"$video_cpp"
git show "$SOURCE_COMMIT:server/encoder/video_encoder_nvenc.cpp" >"$nvenc_cpp"
git show "$SOURCE_COMMIT:client/decoder/shard_accumulator.cpp" >"$acc_cpp"
git show "$SOURCE_COMMIT:client/decoder/helix_diagnostics.h" >"$diag_h"
git show "$SOURCE_COMMIT:client/decoder/android/android_decoder.cpp" >"$android_cpp"

grep -Fq 'json.find("bit-depth")' "$config_cpp" || fail "bit-depth JSON parser binding missing"
grep -Fq 'bit_depth = *it;' "$config_cpp" || fail "bit-depth assignment missing"
grep -Fq '{h265, "h265"}' "$config_cpp" || fail "h265 JSON codec spelling missing"
grep -Fq 'item.contains("encoder")' "$config_cpp" || fail "encoder-name parser missing"
grep -Fq 'auto bit_depth = config.bit_depth ? config.bit_depth : info.bit_depth;' "$settings_cpp" || fail "requested bit-depth resolution missing"
grep -Fq 'invalid bit-depth setting. supported values: 8, 10' "$settings_cpp" || fail "bit-depth validation missing"
grep -Fq 'Using 8-bit encoding due to mixed encoder support.' "$settings_cpp" || fail "10-bit fallback path missing from source audit"
grep -Fq 'encoder.bit_depth << "-bit)"' "$settings_cpp" || fail "resolved encoder bit-depth log missing"

grep -Fq 'HELIX_HEVC10_RECOVERY requires NVENC H.265 Main10 on both eye streams' "$video_cpp" || fail "HEVC10 hard gate missing"
grep -Fq 'helix_hevc10_fault_target_ordinal = stream_idx == 0 ? 600 : 900;' "$video_cpp" || fail "per-eye fault ordinals mismatch"
grep -Fq 'HELIX_HEVC10_DROP stream=%u ordinal=%llu frame=%llu shard=0 packet_sequence=%llu cached=1' "$video_cpp" || fail "cached shard0 drop marker missing"
grep -Fq 'HELIX_HEVC10_RTX_SENT stream=%u frame=%llu packet_sequence=%llu exact_canary=1' "$video_cpp" || fail "exact RTX marker missing"
grep -Fq 'NV_ENC_HEVC_PROFILE_MAIN10_GUID' "$nvenc_cpp" || fail "NVENC Main10 profile GUID missing"
grep -Fq 'HELIX_HEVC10_MAIN10_PROFILE stream=%u profile=main10 input_bit_depth=10 output_bit_depth=10' "$nvenc_cpp" || fail "Main10 runtime proof marker missing"
grep -Fq 'HELIX_HEVC10_RTX_ASSEMBLED stream={} frame={}' "$acc_cpp" || fail "Quest RTX assembled marker missing"
grep -Fq 'hevc10_probe_slots = 8' "$diag_h" || fail "bounded probe size mismatch"
grep -Fq 'state.overflow++' "$diag_h" || fail "bounded probe overflow accounting missing"
grep -Fq 'HELIX_HEVC10_RTX_MEDIA_OUTPUT stream={} frame={} exact_recovered_frame=1' "$android_cpp" || fail "exact MediaCodec output marker missing"
grep -Fq 'HELIX_HEVC10_IMAGE_AFTER_RTX stream={} recovered_frame={} image_frame={} exact={}' "$android_cpp" || fail "AImage-after-RTX marker missing"
grep -Fq 'HELIX_HEVC10_PROBE_SUMMARY stream={} rtx_assembled={} media_exact={} image_after={} overflow={} pending_media={} pending_image={}' "$android_cpp" || fail "probe summary marker missing"

python3 - "$video_cpp" "$acc_cpp" <<'PY'
from pathlib import Path
import sys
v=Path(sys.argv[1]).read_text(); a=Path(sys.argv[2]).read_text()
# The withheld packet must already be cached before it is intentionally skipped.
cache=v.index('helix_rtx_cache.push_back(helix_rtx_cache_entry{')
drop=v.index('const bool helix_hevc10_drop =')
if cache >= drop: raise SystemExit('FAIL: canary drop occurs before RTX cache insertion')
# Quest must register retransmission completion before handing the frame to decoder.
note=a.index('helix_diag::hevc10_note_rtx_assembled')
submit=a.index('decoder_->frame_completed', note)
if note >= submit: raise SystemExit('FAIL: RTX assembly probe occurs after decoder submit')
PY

# Runtime script must request the proven config, cross both ordinals, and prove the resolved path.
grep -Fq 'FRAMES=1200' "$final" || fail "runtime frame count is not frozen at 1200"
grep -Fq '"encoder": {"encoder": "nvenc", "codec": "h265"}' "$final" || fail "runtime NVENC/H265 config missing"
grep -Fq '"bit-depth": 10' "$final" || fail "runtime 10-bit config missing"
grep -Fq 'export HELIX_HEVC10_RECOVERY=1' "$final" || fail "HEVC10 runtime env missing"
for marker in \
  'HELIX_HEVC10_ENCODER_GATE stream=0 encoder=nvenc codec=h265 bit_depth=10' \
  'HELIX_HEVC10_ENCODER_GATE stream=1 encoder=nvenc codec=h265 bit_depth=10' \
  'HELIX_HEVC10_MAIN10_PROFILE stream=0 profile=main10 input_bit_depth=10 output_bit_depth=10' \
  'HELIX_HEVC10_MAIN10_PROFILE stream=1 profile=main10 input_bit_depth=10 output_bit_depth=10' \
  'HELIX_HEVC10_FAULT_PLAN stream=0 target_ordinal=600 shard=0' \
  'HELIX_HEVC10_FAULT_PLAN stream=1 target_ordinal=900 shard=0'; do
  grep -Fq "$marker" "$final" || fail "runtime resolved-path check missing: $marker"
done

# LAN transport is explicit and ADB tunnelling is forbidden rather than merely unused.
grep -Fq 'QUEST_IP_EXPECTED="192.168.0.54"' "$final" || fail "Quest LAN address not pinned"
grep -Fq 'HOST_IP_EXPECTED="192.168.0.44"' "$final" || fail "host LAN address not pinned"
grep -Fq 'HOST_DEV_EXPECTED="enp14s0"' "$final" || fail "host LAN device not pinned"
grep -Fq 'URI="wivrn+tcp://${HOST_IP_EXPECTED}"' "$final" || fail "explicit LAN URI missing"
grep -Fq 'adb forward --list' "$final" || fail "ADB forward exclusion check missing"
grep -Fq 'reverse --list' "$final" || fail "ADB reverse exclusion check missing"
! grep -Eq 'adb .*forward .*tcp:|adb .*reverse .*tcp:' "$final" || fail "ADB tunnel creation present"

# Exact per-eye frame/packet correlation is mandatory; aggregate counts alone cannot pass.
for oracle in \
  "d.get('ordinal')!=ordinal or d.get('shard')!='0' or d.get('cached')!='1'" \
  "x.get('frame')==frame and x.get('packet_sequence')==seq and x.get('exact_canary')=='1'" \
  "x.get('frame')==frame and x.get('exact_recovered_frame')=='1'" \
  "x.get('recovered_frame')!=frame" \
  "int(x.get('image_frame','-1')) >= int(frame)" \
  "p.get('overflow')!='0'"; do
  grep -Fq "$oracle" "$final" || fail "exact runtime oracle missing: $oracle"
done
grep -Fq 'decoder_recovery=ESTABLISHED exact-rtx-to-mediacodec-to-aimage-per-eye' "$final" || fail "decoder recovery PASS boundary missing"
grep -Fq 'PIXEL_CLEANLINESS=NOT_ESTABLISHED' "$final" || fail "pixel cleanliness boundary missing"
grep -Fq 'RUNTIME=PASS hevc10-both-eye-exact-rtx-mediacodec-aimage-recovery' "$final" || fail "final runtime PASS marker missing"

mapfile -t manifests < <(find "$OUT_ROOT/worktree/build-server" -type f -name 'openxr_wivrn-dev.json' -print 2>/dev/null)
mapfile -t prefixes < <(find "$OUT_ROOT/worktree/build-server" -type f -path '*/dashboard/prefix.sh' -print 2>/dev/null)
[[ ${#manifests[@]} -eq 1 ]] || fail "exact-source OpenXR manifest count=${#manifests[@]}"
[[ ${#prefixes[@]} -eq 1 ]] || fail "exact-source prefix.sh count=${#prefixes[@]}"

echo 'AUDIT_A=PASS hevc10-runtime-runner-exact-source-artifacts-hashes-seals-stimulus-final-emitted-script'
echo 'AUDIT_B=PASS bit-depth-parser-nvenc-main10-both-eye-cached-shard0-exact-rtx-mediacodec-aimage-lan-only-bounded-ledger'
echo "source_commit=$SOURCE_COMMIT"
echo "base_runner_commit=$BASE_RUNNER_COMMIT"
echo "runner_tooling_commit=$RUNNER_TOOLING_COMMIT"
echo "server_sha256=$SERVER_SHA256"
echo "apk_sha256=$APK_SHA256"
echo "metadata_sha256=$META_SHA256"
echo "stimulus_binary_sha256=$STIM_BIN_SHA256"
echo 'frames=1200 target_ordinals=600,900'
echo 'runtime_oracle=exact-frame-correlation-per-eye-not-aggregate-counts'
echo 'probe_overflow_required=0'
echo 'PIXEL_CLEANLINESS=NOT_ESTABLISHED'
echo 'RUNTIME=NOT_RUN'
