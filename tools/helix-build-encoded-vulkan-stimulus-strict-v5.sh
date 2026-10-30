#!/usr/bin/env bash
set -euo pipefail

BASE_V3="1346a215fad30861651bfd054c8e5cd162bca06f"
SOURCE_COMMIT="5568963b538eaae708b9f957a9a3c162ddaf5de4"
ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
BASE_SRC="$ROOT/helix_vulkan_stimulus.cpp"
BASE_META="$ROOT/vulkan-stimulus-metadata.txt"
SRC="$ROOT/helix_vulkan_stimulus_v5.cpp"
BIN="$ROOT/helix-vulkan-stimulus-v5"
META="$ROOT/vulkan-stimulus-v5-metadata.txt"

fail(){ echo "error: $*" >&2; exit 2; }
for c in git python3 grep cp sed sha256sum timeout c++; do command -v "$c" >/dev/null 2>&1 || fail "missing command $c"; done
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || fail "run from inside WiVRn checkout"
cd "$repo_root"

# Recreate the already-passing v3 generated artifact first.
v3="$(mktemp)"
trap 'rm -f "$v3"' EXIT INT TERM
git cat-file -e "${BASE_V3}^{commit}" 2>/dev/null || git fetch origin "$BASE_V3"
git show "${BASE_V3}:tools/helix-build-encoded-vulkan-stimulus-strict-v3.sh" >"$v3"
echo '[1/4] Rebuilding proven strict-v3 stimulus as source baseline'
bash "$v3"
[[ -s "$BASE_SRC" && -s "$BASE_META" ]] || fail "strict-v3 baseline artifact missing"
grep -Fq "source_commit=$SOURCE_COMMIT" "$BASE_META" || fail "strict-v3 source identity mismatch"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$BASE_SRC" || fail "strict-v3 entropy contract missing"
grep -Fq 'vkCmdCopyBufferToImage' "$BASE_SRC" || fail "strict-v3 transfer contract missing"
! grep -Fq 'XR_MND_headless' "$BASE_SRC" || fail "headless path leaked into strict-v3 source"

cp "$BASE_SRC" "$SRC"

echo '[2/4] Patching actual generated C++ session-state/frame-count logic'
python3 - "$SRC" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()

def once(old,new,label):
    global s
    n=s.count(old)
    if n != 1:
        raise SystemExit(f'error: v5 actual-source anchor count={n}: {label}')
    s=s.replace(old,new,1)

once(
'''    uint32_t produced = 0;\n    for (; produced < target_frames; ++produced) {\n''',
'''    uint32_t produced = 0;\n    uint32_t attempts = 0;\n    XrSessionState session_state = XR_SESSION_STATE_READY;\n    auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);\n    while (produced < target_frames && std::chrono::steady_clock::now() < render_deadline) {\n        XrEventDataBuffer frame_event{}; xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);\n        while (xrPollEvent(instance, &frame_event) == XR_SUCCESS) {\n            if (frame_event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {\n                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&frame_event);\n                session_state = changed->state;\n                std::fprintf(stderr, "HELIX_VULKAN_STATE state=%d\\n", int(session_state)); std::fflush(stderr);\n                if (session_state == XR_SESSION_STATE_STOPPING || session_state == XR_SESSION_STATE_EXITING || session_state == XR_SESSION_STATE_LOSS_PENDING)\n                    die("session_stopped_before_render_target");\n            }\n            xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);\n        }\n        ++attempts;\n''',
'frame-loop start')

once(
'''        XrFrameBeginInfo fbi{}; xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);\n        xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");\n\n        XrSwapchainImageAcquireInfo ai{}; xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);\n''',
'''        XrFrameBeginInfo fbi{}; xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);\n        xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");\n        if (!fs.shouldRender) {\n            XrFrameEndInfo idle_end{}; xr_init(idle_end, XR_TYPE_FRAME_END_INFO);\n            idle_end.displayTime = fs.predictedDisplayTime;\n            idle_end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;\n            idle_end.layerCount = 0;\n            idle_end.layers = nullptr;\n            xr_ok(xrEndFrame(session, &idle_end), "xrEndFrame_idle");\n            if (attempts % 30 == 0) {\n                std::fprintf(stderr, "HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d\\n", attempts, produced, int(session_state));\n                std::fflush(stderr);\n            }\n            continue;\n        }\n\n        XrSwapchainImageAcquireInfo ai{}; xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);\n''',
'idle render path')

once(
'''        fei.layerCount = fs.shouldRender ? 1u : 0u;\n        fei.layers = fs.shouldRender ? layers : nullptr;\n        xr_ok(xrEndFrame(session, &fei), "xrEndFrame");\n        if ((produced + 1) % 30 == 0) { std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u shouldRender=%d\\n", produced + 1, fs.shouldRender); std::fflush(stderr); }\n    }\n\n    std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u\\n", produced); std::fflush(stderr);\n''',
'''        fei.layerCount = 1;\n        fei.layers = layers;\n        xr_ok(xrEndFrame(session, &fei), "xrEndFrame");\n        ++produced;\n        if (produced % 30 == 0) {\n            std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d\\n", produced, attempts, int(session_state));\n            std::fflush(stderr);\n        }\n    }\n    if (produced != target_frames) die("renderable_frame_target_not_reached");\n\n    std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u attempts=%u\\n", produced, attempts); std::fflush(stderr);\n''',
'frame-loop completion')

required=[
 'HELIX_VULKAN_ENTROPY patterns=8',
 'vkCmdCopyBufferToImage',
 'while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)',
 'HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d',
 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d',
 'renderable_frame_target_not_reached',
 'xrEndFrame_idle',
]
for x in required:
    if x not in s: raise SystemExit('error: v5 requirement missing: '+x)
for x in [
 'for (; produced < target_frames; ++produced)',
 'fei.layerCount = fs.shouldRender ? 1u : 0u',
 'HELIX_VULKAN_PROGRESS frames=%u shouldRender=%d',
 'XR_MND_headless',
]:
    if x in s: raise SystemExit('error: stale v5 pattern remains: '+x)
p.write_text(s)
PY

OPENXR_LIB="$(sed -n 's/^openxr_loader=//p' "$BASE_META" | tail -1)"
VULKAN_LIB="$(sed -n 's/^vulkan_loader=//p' "$BASE_META" | tail -1)"
[[ -f "$OPENXR_LIB" && -f "$VULKAN_LIB" ]] || fail "loader path missing from strict-v3 metadata"
[[ -f /usr/include/openxr/openxr_platform.h ]] || fail "system OpenXR headers missing"

echo '[3/4] Compiling separate v5 stimulus artifact'
timeout --signal=TERM --kill-after=5s 45s c++ -std=c++20 -O2 -Wall -Wextra -Werror -I/usr/include "$SRC" "$OPENXR_LIB" "$VULKAN_LIB" -pthread -o "$BIN"
[[ -x "$BIN" ]] || fail "v5 stimulus compile failed"

echo '[4/4] Auditing and recording v5 artifact metadata'
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC"
grep -Fq 'HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d' "$SRC"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC"
grep -Fq 'renderable_frame_target_not_reached' "$SRC"
grep -Fq 'xrEndFrame_idle' "$SRC"
! grep -Fq 'XR_MND_headless' "$SRC"
! grep -Fq 'for (; produced < target_frames; ++produced)' "$SRC"
SRC_SHA="$(sha256sum "$SRC" | awk '{print $1}')"
BIN_SHA="$(sha256sum "$BIN" | awk '{print $1}')"
cat >"$META" <<EOF
source_commit=$SOURCE_COMMIT
base_generator_commit=$BASE_V3
vulkan_stimulus=$BIN
stimulus_source=$SRC
openxr_loader=$OPENXR_LIB
vulkan_loader=$VULKAN_LIB
source_sha256=$SRC_SHA
binary_sha256=$BIN_SHA
stimulus_contract=PASS graphics-bound-vulkan-event-pumped-render-counted-entropy8
runtime_status=NOT_RUN
EOF
printf '\nPASS: strict-v5 actual-source Vulkan stimulus artifact gate.\nsource_commit=%s\nvulkan_stimulus=%s\nstimulus_source=%s\nsource_sha256=%s\nbinary_sha256=%s\nmetadata=%s\nSTATUS: built only; runtime not executed.\n' "$SOURCE_COMMIT" "$BIN" "$SRC" "$SRC_SHA" "$BIN_SHA" "$META"
