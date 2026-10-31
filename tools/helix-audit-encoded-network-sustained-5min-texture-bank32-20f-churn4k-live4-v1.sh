#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
RUNNER="$ROOT/helix-run-encoded-network-sustained-5min-texture-bank32-20f-v1.sh"
RUNNER_SHA="$(sha256sum "$RUNNER" | awk '{print $1}')"
CHURN_SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_v1.cpp"
CHURN_BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-v1"
CHURN_META="$ROOT/vulkan-texture-churn-4k-live4-v1-metadata.txt"
CHURN_SEAL="$ROOT/vulkan-texture-churn-4k-live4-v1-seal.txt"
EXPECTED_BUILD_TOOLING="90842e13d58bcec6c788f4eb0bb345a632833ed1"
EXPECTED_SEAL_MARKER="artifact_seal=PASS texture-churn-4k-live4-v1-ring4-256MiB-persistent-staging-upload-readback-source-binary-metadata-deps"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk grep sha256sum bash; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$RUNNER" "$CHURN_SRC" "$CHURN_BIN" "$CHURN_META" "$CHURN_SEAL"; do [[ -s "$f" ]] || fail "missing artifact: $f"; done
[[ -x "$RUNNER" && -x "$CHURN_BIN" ]] || fail "required executable missing"

read_meta(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$CHURN_META" | tail -1; }
SRC_SHA="$(read_meta source_sha256)"
BIN_SHA="$(read_meta binary_sha256)"
META_SHA="$(sha256sum "$CHURN_META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid churn hash format: $h"; done
[[ "$(sha256sum "$CHURN_SRC" | awk '{print $1}')" == "$SRC_SHA" ]] || fail "churn source hash mismatch"
[[ "$(sha256sum "$CHURN_BIN" | awk '{print $1}')" == "$BIN_SHA" ]] || fail "churn binary hash mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$CHURN_SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$CHURN_SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$CHURN_SEAL" || fail "seal metadata hash mismatch"
grep -Fqx "build_tooling_commit=$EXPECTED_BUILD_TOOLING" "$CHURN_SEAL" || fail "seal build tooling mismatch"
grep -Fqx "$EXPECTED_SEAL_MARKER" "$CHURN_SEAL" || fail "seal marker mismatch"
grep -Fqx 'texture_width=4096' "$CHURN_META" || fail "texture width mismatch"
grep -Fqx 'texture_height=4096' "$CHURN_META" || fail "texture height mismatch"
grep -Fqx 'texture_bytes=67108864' "$CHURN_META" || fail "texture bytes mismatch"
grep -Fqx 'interval_ms=2000' "$CHURN_META" || fail "interval mismatch"
grep -Fqx 'max_cycles=180' "$CHURN_META" || fail "cycle cap mismatch"
grep -Fqx 'live_images=4' "$CHURN_META" || fail "live image count mismatch"
grep -Fqx 'live_texture_bytes=268435456' "$CHURN_META" || fail "live bytes mismatch"
grep -Fqx 'staging_lifecycle=persistent' "$CHURN_META" || fail "staging lifecycle mismatch"
grep -Fqx 'readback_verification=one-pixel-every-cycle' "$CHURN_META" || fail "readback verification mismatch"
grep -Fqx 'churn_contract=PASS deterministic-four-live-4k-rgba-device-memory-lifecycle-upload-readback-v1' "$CHURN_META" || fail "churn contract mismatch"
grep -Fqx 'source_delta=PASS frozen-single-live-only-retention-ring-1-to-4' "$CHURN_META" || fail "source delta mismatch"

# Re-audit the already-proven bank32 runner contract. Its hash is reported for evidence,
# but this script does not falsely claim an independent exact-hash binding for it.
grep -Fq 'HELIX_SUSTAINED_FRAMES:-27000' "$RUNNER" || fail "runner frames mismatch"
grep -Fq 'HELIX_ENCODED_TORTURE_CYCLES:-449' "$RUNNER" || fail "runner cycles mismatch"
grep -Fq 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20' "$RUNNER" || fail "runner spacing mismatch"
grep -Fq 'frame-keyed-1347-event-reducer-and-bounded-frame-budget' "$RUNNER" || fail "runner expected count mismatch"
grep -Fq 'ENCODED_NVENC_SUSTAINED_5MIN_TEXTURE_BANK32_20F_PASS' "$RUNNER" || fail "runner verdict marker mismatch"

printf 'AUDIT_A=PASS exact-sealed-churn4k-live4-256MiB-4live-2s\n'
printf 'churn_source_sha256=%s\nchurn_binary_sha256=%s\nchurn_metadata_sha256=%s\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
printf 'AUDIT_B=PASS bank32-contract-27000-449-20-1347\n'
printf 'runner_sha256_evidence=%s\n' "$RUNNER_SHA"
printf 'RUNTIME=NOT_RUN\n'
printf '\nRun order after this audit passes:\n  1) start bank32 runner\n  2) wait for UNPLUG USB NOW, unplug\n  3) immediately start %s | tee %s\n' "$CHURN_BIN" "$ROOT/churn4k-live4-runtime.log"
