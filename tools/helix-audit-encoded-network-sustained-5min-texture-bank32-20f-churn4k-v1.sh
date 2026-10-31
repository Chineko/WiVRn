#!/usr/bin/env bash
set -euo pipefail
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BANK_RUNNER="$ROOT/helix-run-encoded-network-sustained-5min-texture-bank32-20f-v1.sh"
CHURN_BIN="$ROOT/helix-vulkan-texture-churn-4k-v1"
CHURN_META="$ROOT/vulkan-texture-churn-4k-v1-metadata.txt"
CHURN_SEAL="$ROOT/vulkan-texture-churn-4k-v1-seal.txt"
SRC_SHA="3161d5772aef9cb6c175866aded7f35389d5733fef8c777205664107b6059f18"
BIN_SHA="1cd8ef4584968b20d7bff4ee72c7129c095d9977a417246ab2f83c5ce6ff38e2"
META_SHA="a9514dc5b830e6652b2efe92b003c65b39f5770a437c39b37d85e530fa2b11b1"
TOOLING="397dcd68306978e39bd8960977633ef9776f873a"
fail(){ echo "FAIL: $*" >&2; exit 2; }
for f in "$BANK_RUNNER" "$CHURN_BIN" "$CHURN_META" "$CHURN_SEAL"; do [[ -s "$f" ]] || fail "missing $f"; done
[[ -x "$BANK_RUNNER" && -x "$CHURN_BIN" ]] || fail "required executable missing"
[[ "$(sha256sum "$CHURN_BIN"|awk '{print $1}')" == "$BIN_SHA" ]] || fail "churn binary hash mismatch"
[[ "$(sha256sum "$CHURN_META"|awk '{print $1}')" == "$META_SHA" ]] || fail "churn metadata hash mismatch"
grep -Fqx "source_sha256=$SRC_SHA" "$CHURN_SEAL" || fail "churn source seal mismatch"
grep -Fqx "binary_sha256=$BIN_SHA" "$CHURN_SEAL" || fail "churn binary seal mismatch"
grep -Fqx "metadata_sha256=$META_SHA" "$CHURN_SEAL" || fail "churn metadata seal mismatch"
grep -Fqx "build_tooling_commit=$TOOLING" "$CHURN_SEAL" || fail "churn tooling mismatch"
for x in 'texture_width=4096' 'texture_height=4096' 'texture_bytes=67108864' 'interval_ms=2000' 'max_cycles=180' 'live_images=1' 'artifact_seal=PASS texture-churn-4k-v1-single-live-image-persistent-staging-upload-readback-source-binary-metadata-deps'; do grep -Fqx "$x" "$CHURN_SEAL" || fail "churn seal marker missing: $x"; done
grep -Fqx 'churn_contract=PASS deterministic-single-4k-rgba-device-memory-lifecycle-upload-readback-v1' "$CHURN_META" || fail "churn contract missing"
for x in 'HELIX_SUSTAINED_FRAMES:-27000' 'HELIX_ENCODED_TORTURE_CYCLES:-449' 'HELIX_ENCODED_TORTURE_SPACING_FRAMES:-20' 'frame-keyed-1347-event-reducer-and-bounded-frame-budget' 'ENCODED_NVENC_SUSTAINED_5MIN_TEXTURE_BANK32_20F_PASS'; do grep -Fq "$x" "$BANK_RUNNER" || fail "bank32 marker missing: $x"; done
echo 'AUDIT_A=PASS exact-sealed-churn4k-64MiB-single-live-image-2s'
echo 'AUDIT_B=PASS frozen-bank32-27000-449-20-1347'
echo 'RUNTIME=NOT_RUN'
