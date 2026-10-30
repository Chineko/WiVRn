#!/usr/bin/env bash
set -euo pipefail

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus_v5.cpp"
BASE_BIN="$ROOT/helix-vulkan-stimulus-v5"
BASE_META="$ROOT/vulkan-stimulus-v5-metadata.txt"
BASE_SEAL="$ROOT/vulkan-stimulus-v5-seal.txt"
SRC="$ROOT/helix_vulkan_stimulus_sustained_v1.cpp"
BIN="$ROOT/helix-vulkan-stimulus-sustained-v1"
META="$ROOT/vulkan-stimulus-sustained-v1-metadata.txt"

FROZEN_V5_SOURCE_SHA="b10067c6127af12c5d83e7b79f5020830d8722c4c80dc27a4c54635a3adfa901"
FROZEN_V5_BINARY_SHA="5d55b5b522f8408843d9ac83bda7fe6a6fd3a37d135464dd8bd63b115a5409c4"
FROZEN_V5_METADATA_SHA="75a7bcc0570c650680e953fe88f7c8f4d6cece891d585b337c210d38be524a91"
RENDER_DEADLINE_SECONDS=360

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in awk cp grep python3 sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
for f in "$BASE_SRC" "$BASE_BIN" "$BASE_META" "$BASE_SEAL"; do [[ -s "$f" ]] || fail "missing frozen v5 artifact: $f"; done
[[ -x "$BASE_BIN" ]] || fail "frozen v5 binary is not executable"

base_src_sha="$(sha256sum "$BASE_SRC" | awk '{print $1}')"
base_bin_sha="$(sha256sum "$BASE_BIN" | awk '{print $1}')"
base_meta_sha="$(sha256sum "$BASE_META" | awk '{print $1}')"
[[ "$base_src_sha" == "$FROZEN_V5_SOURCE_SHA" ]] || fail "frozen v5 source hash mismatch"
[[ "$base_bin_sha" == "$FROZEN_V5_BINARY_SHA" ]] || fail "frozen v5 binary hash mismatch"
[[ "$base_meta_sha" == "$FROZEN_V5_METADATA_SHA" ]] || fail "frozen v5 metadata hash mismatch"
grep -Fqx "source_sha256=$FROZEN_V5_SOURCE_SHA" "$BASE_SEAL" || fail "frozen v5 seal source hash mismatch"
grep -Fqx "binary_sha256=$FROZEN_V5_BINARY_SHA" "$BASE_SEAL" || fail "frozen v5 seal binary hash mismatch"
grep -Fqx "metadata_sha256=$FROZEN_V5_METADATA_SHA" "$BASE_SEAL" || fail "frozen v5 seal metadata hash mismatch"
grep -Fqx 'artifact_seal=PASS strict-v5-source-binary-metadata-deps' "$BASE_SEAL" || fail "frozen v5 seal marker missing"
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8' "$BASE_META" || fail "frozen v5 contract marker missing"

cp "$BASE_SRC" "$SRC"
python3 - "$SRC" "$RENDER_DEADLINE_SECONDS" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
seconds = sys.argv[2]
s = p.read_text()
old = 'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);'
new = f'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds({seconds});'
count = s.count(old)
if count != 1:
    raise SystemExit(f'FAIL: sustained deadline anchor count={count}')
s = s.replace(old, new, 1)
p.write_text(s)
PY

# Prove the sustained source is otherwise identical to frozen V5.
python3 - "$BASE_SRC" "$SRC" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]).read_text()
sustained = Path(sys.argv[2]).read_text()
expected = base.replace(
    'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);',
    'auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(360);',
    1,
)
if sustained != expected:
    raise SystemExit('FAIL: sustained source differs from frozen V5 beyond deadline change')
PY

grep -Fq 'std::chrono::seconds(360)' "$SRC" || fail "sustained deadline missing"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC" || fail "entropy8 source marker missing"
grep -Fq 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)' "$SRC" || fail "event pump source marker missing"
grep -Fq 'renderable_frame_target_not_reached' "$SRC" || fail "render target guard missing"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC" || fail "render progress marker missing"

OPENXR_LIB="$(awk -F= '$1=="openxr_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
VULKAN_LIB="$(awk -F= '$1=="vulkan_loader" {print substr($0,index($0,"=")+1)}' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from frozen v5 metadata"

echo '[1/2] Compiling sustained-v1 Vulkan stimulus'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "sustained-v1 compile failed"

echo '[2/2] Recording sustained-v1 metadata'
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
cat >"$META" <<EOF
base_v5_source=$BASE_SRC
base_v5_binary=$BASE_BIN
base_v5_metadata=$BASE_META
base_v5_seal=$BASE_SEAL
base_v5_source_sha256=$FROZEN_V5_SOURCE_SHA
base_v5_binary_sha256=$FROZEN_V5_BINARY_SHA
base_v5_metadata_sha256=$FROZEN_V5_METADATA_SHA
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
render_deadline_seconds=$RENDER_DEADLINE_SECONDS
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8-sustained360
source_delta=PASS frozen-v5-only-render-deadline-20-to-360
runtime_status=NOT_RUN
EOF

printf '\nPASS: sustained-v1 Vulkan stimulus built from frozen V5.\nbase_v5_source_sha256=%s\nbase_v5_binary_sha256=%s\nbase_v5_metadata_sha256=%s\nrender_deadline_seconds=%s\nstimulus_source=%s\nsource_sha256=%s\nvulkan_stimulus=%s\nbinary_sha256=%s\nmetadata=%s\nSTATUS: built only; runtime not executed.\n' \
  "$FROZEN_V5_SOURCE_SHA" "$FROZEN_V5_BINARY_SHA" "$FROZEN_V5_METADATA_SHA" "$RENDER_DEADLINE_SECONDS" "$SRC" "$SRC_SHA" "$BIN" "$BIN_SHA" "$META"
