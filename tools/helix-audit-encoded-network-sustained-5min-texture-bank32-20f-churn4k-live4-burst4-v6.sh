#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
RUNNER="$ROOT/helix-run-encoded-network-sustained-5min-texture-bank32-20f-v1.sh"
CHURN_SRC="$ROOT/helix_vulkan_texture_churn_4k_live4_burst4_v1.cpp"
CHURN_BIN="$ROOT/helix-vulkan-texture-churn-4k-live4-burst4-v1"
CHURN_META="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-metadata.txt"
CHURN_SEAL="$ROOT/vulkan-texture-churn-4k-live4-burst4-v1-seal.txt"
EXPECTED_BUILD_TOOLING="2719db94169ca714cb4d2de1356843f025956ef7"
EXPECTED_SEAL_MARKER="artifact_seal=PASS texture-churn-4k-live4-burst4-v1-ring4-256MiB-burst4-dwell8s-persistent-staging-upload-readback-source-binary-metadata-deps"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk grep sha256sum; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$RUNNER" "$CHURN_SRC" "$CHURN_BIN" "$CHURN_META" "$CHURN_SEAL"; do [[ -s "$f" ]] || fail "missing artifact: $f"; done
[[ -x "$RUNNER" && -x "$CHURN_BIN" ]] || fail "required executable missing"

meta_get(){ awk -F= -v key="$1" '$1==key {print substr($0,index($0,"=")+1)}' "$CHURN_META" | tail -1; }
SRC_SHA="$(meta_get source_sha256)"
BIN_SHA="$(meta_get binary_sha256)"
META_SHA="$(sha256sum "$CHURN_META" | awk '{print $1}')"
for h in "$SRC_SHA" "$BIN_SHA" "$META_SHA"; do [[ "$h" =~ ^[0-9a-f]{64}$ ]] || fail "invalid churn hash: $h"; done
[[ "$(sha256sum "$CHURN_SRC" | awk '{print $1}')" == "$SRC_SHA" ]] || fail "churn source hash mismatch"
[[ "$(sha256sum "$CHURN_BIN" | awk '{print $1}')" == "$BIN_SHA" ]] || fail "churn binary hash mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$CHURN_SEAL" || fail "seal source hash mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$CHURN_SEAL" || fail "seal binary hash mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$CHURN_SEAL" || fail "seal metadata hash mismatch"
grep -Fqx "build_tooling_commit=$EXPECTED_BUILD_TOOLING" "$CHURN_SEAL" || fail "seal tooling mismatch"
grep -Fqx "$EXPECTED_SEAL_MARKER" "$CHURN_SEAL" || fail "seal marker mismatch"

for kv in \
  'live_images=4' \
  'live_texture_bytes=268435456' \
  'burst_size=4' \
  'burst_dwell_ms=8000' \
  'nominal_average_interval_ms=2000' \
  'max_cycles=180' \
  'staging_lifecycle=persistent' \
  'readback_verification=one-pixel-every-cycle' \
  'source_delta=PASS frozen-live4-only-temporal-upload-shape-smooth2s-to-burst4-dwell8s'; do
  grep -Fqx "$kv" "$CHURN_META" || fail "metadata mismatch: $kv"
done

grep -Fq 'constexpr uint32_t BURST_SIZE=4;' "$CHURN_SRC" || fail "source burst size mismatch"
grep -Fq 'constexpr uint32_t BURST_DWELL_MS=8000;' "$CHURN_SRC" || fail "source burst dwell mismatch"
grep -Fq 'constexpr uint32_t LIVE_SLOTS=4;' "$CHURN_SRC" || fail "source live slots mismatch"
! grep -Fq 'auto next=' "$CHURN_SRC" || fail "dead next variable remains"
! grep -Fq 'const auto start=' "$CHURN_SRC" || fail "dead start variable remains"

# Frozen bank32 20f schedule/runtime contract.
grep -Fq 'HELIX_SUSTAINED_FRAMES:-27000' "$RUNNER" || fail "runner frames mismatch"
grep -Fq 'HELIX_ENCODED_TORTURE_CYCLES:-449' "$RUNNER" || fail "runner cycles mismatch"
grep -Fq 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20' "$RUNNER" || fail "runner spacing mismatch"
grep -Fq 'frame-keyed-1347-event-reducer-and-bounded-frame-budget' "$RUNNER" || fail "runner expected count mismatch"
grep -Fq 'ENCODED_NVENC_SUSTAINED_5MIN_TEXTURE_BANK32_20F_PASS' "$RUNNER" || fail "runner verdict marker mismatch"

printf 'AUDIT_A=PASS exact-sealed-churn4k-live4-burst4-256MiB-4x64MiB-back-to-back-dwell8s\n'
printf 'churn_source_sha256=%s\nchurn_binary_sha256=%s\nchurn_metadata_sha256=%s\n' "$SRC_SHA" "$BIN_SHA" "$META_SHA"
printf 'AUDIT_B=PASS bank32-contract-27000-449-20-1347\n'
printf 'RUNTIME=NOT_RUN\n'
printf '\nRun order after this audit passes:\n  1) start bank32 runner\n  2) wait for UNPLUG USB NOW, unplug\n  3) immediately start %s | tee %s\n' "$CHURN_BIN" "$ROOT/churn4k-live4-burst4-runtime.log"
