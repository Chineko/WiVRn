#!/usr/bin/env bash
set -euo pipefail

BASE="1346a215fad30861651bfd054c8e5cd162bca06f"
repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo 'error: run from inside WiVRn checkout' >&2; exit 2; }
cd "$repo_root"
for c in git python3 grep bash; do command -v "$c" >/dev/null 2>&1 || { echo "error: missing command $c" >&2; exit 2; }; done
wrapper="$(mktemp)"; generated="$(mktemp)"
trap 'rm -f "$wrapper" "$generated"' EXIT INT TERM

git cat-file -e "${BASE}^{commit}" 2>/dev/null || git fetch origin "$BASE"
git show "${BASE}:tools/helix-build-encoded-vulkan-stimulus-strict-v3.sh" >"$wrapper"
python3 - "$wrapper" "$generated" <<'PY'
from pathlib import Path
import shlex,sys
p=Path(sys.argv[1]); out=sys.argv[2]
s=p.read_text()
needle='exec bash "$tmp"\n'
if s.count(needle)!=1: raise SystemExit('error: strict-v3 exec anchor not unique')
s=s.replace(needle, f'cp "$tmp" {shlex.quote(out)}\n', 1)
p.write_text(s)
PY
bash "$wrapper"
[[ -s "$generated" ]] || { echo 'error: strict-v3 did not emit generated build helper' >&2; exit 2; }

python3 - "$generated" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old='''    uint32_t produced = 0;\n    for (; produced < target_frames; ++produced) {\n        XrFrameWaitInfo fwi{}; xr_init(fwi, XR_TYPE_FRAME_WAIT_INFO);\n        XrFrameState fs{}; xr_init(fs, XR_TYPE_FRAME_STATE);\n        xr_ok(xrWaitFrame(session, &fwi, &fs), "xrWaitFrame");\n        XrFrameBeginInfo fbi{}; xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);\n        xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");\n\n        XrSwapchainImageAcquireInfo ai{}; xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);\n'''
new='''    uint32_t produced = 0;\n    uint32_t attempts = 0;\n    XrSessionState session_state = XR_SESSION_STATE_READY;\n    auto render_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(20);\n    while (produced < target_frames && std::chrono::steady_clock::now() < render_deadline) {\n        XrEventDataBuffer frame_event{}; xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);\n        while (xrPollEvent(instance, &frame_event) == XR_SUCCESS) {\n            if (frame_event.type == XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED) {\n                auto * changed = reinterpret_cast<XrEventDataSessionStateChanged *>(&frame_event);\n                session_state = changed->state;\n                std::fprintf(stderr, "HELIX_VULKAN_STATE state=%d\\n", int(session_state)); std::fflush(stderr);\n                if (session_state == XR_SESSION_STATE_STOPPING || session_state == XR_SESSION_STATE_EXITING || session_state == XR_SESSION_STATE_LOSS_PENDING)\n                    die("session_stopped_before_render_target");\n            }\n            xr_init(frame_event, XR_TYPE_EVENT_DATA_BUFFER);\n        }\n        ++attempts;\n        XrFrameWaitInfo fwi{}; xr_init(fwi, XR_TYPE_FRAME_WAIT_INFO);\n        XrFrameState fs{}; xr_init(fs, XR_TYPE_FRAME_STATE);\n        xr_ok(xrWaitFrame(session, &fwi, &fs), "xrWaitFrame");\n        XrFrameBeginInfo fbi{}; xr_init(fbi, XR_TYPE_FRAME_BEGIN_INFO);\n        xr_ok(xrBeginFrame(session, &fbi), "xrBeginFrame");\n        if (!fs.shouldRender) {\n            XrFrameEndInfo idle_end{}; xr_init(idle_end, XR_TYPE_FRAME_END_INFO);\n            idle_end.displayTime = fs.predictedDisplayTime;\n            idle_end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;\n            idle_end.layerCount = 0;\n            idle_end.layers = nullptr;\n            xr_ok(xrEndFrame(session, &idle_end), "xrEndFrame_idle");\n            if (attempts % 30 == 0) { std::fprintf(stderr, "HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d\\n", attempts, produced, int(session_state)); std::fflush(stderr); }\n            continue;\n        }\n\n        XrSwapchainImageAcquireInfo ai{}; xr_init(ai, XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO);\n'''
if s.count(old)!=1: raise SystemExit('error: frame-loop start anchor not unique')
s=s.replace(old,new,1)
old2='''        fei.layerCount = fs.shouldRender ? 1u : 0u;\n        fei.layers = fs.shouldRender ? layers : nullptr;\n        xr_ok(xrEndFrame(session, &fei), "xrEndFrame");\n        if ((produced + 1) % 30 == 0) { std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u shouldRender=%d\\n", produced + 1, fs.shouldRender); std::fflush(stderr); }\n    }\n\n    std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u\\n", produced); std::fflush(stderr);\n'''
new2='''        fei.layerCount = 1;\n        fei.layers = layers;\n        xr_ok(xrEndFrame(session, &fei), "xrEndFrame");\n        ++produced;\n        if (produced % 30 == 0) { std::fprintf(stderr, "HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d\\n", produced, attempts, int(session_state)); std::fflush(stderr); }\n    }\n    if (produced != target_frames) die("renderable_frame_target_not_reached");\n\n    std::fprintf(stderr, "HELIX_VULKAN_DONE frames=%u attempts=%u\\n", produced, attempts); std::fflush(stderr);\n'''
if s.count(old2)!=1: raise SystemExit('error: frame-loop end anchor not unique')
s=s.replace(old2,new2,1)
for required in ['HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d','HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d','renderable_frame_target_not_reached','xrEndFrame_idle','while (xrPollEvent(instance, &frame_event) == XR_SUCCESS)']:
    if required not in s: raise SystemExit('error: strict-v4 requirement missing: '+required)
for forbidden in ['for (; produced < target_frames; ++produced)','fei.layerCount = fs.shouldRender ? 1u : 0u','HELIX_VULKAN_PROGRESS frames=%u shouldRender=%d']:
    if forbidden in s: raise SystemExit('error: stale strict-v4 pattern remains: '+forbidden)
p.write_text(s)
PY

grep -Fq 'renderable_frame_target_not_reached' "$generated"
grep -Fq 'HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d' "$generated"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$generated"
grep -Fq 'xrEndFrame_idle' "$generated"
! grep -Fq 'for (; produced < target_frames; ++produced)' "$generated"

echo '[STRICT BUILD v4 1/1] Building event-pumped render-counted Vulkan stimulus only'
bash "$generated"

ROOT="$HOME/helix-encoded-nvenc-build-20261030-160211"
SRC="$ROOT/helix_vulkan_stimulus.cpp"
BIN="$ROOT/helix-vulkan-stimulus"
META="$ROOT/vulkan-stimulus-metadata.txt"
[[ -s "$SRC" && -x "$BIN" && -s "$META" ]] || { echo 'error: strict-v4 artifact set incomplete' >&2; exit 2; }
grep -Fq 'renderable_frame_target_not_reached' "$SRC"
grep -Fq 'HELIX_VULKAN_WAIT attempts=%u rendered=%u shouldRender=0 state=%d' "$SRC"
grep -Fq 'HELIX_VULKAN_PROGRESS frames=%u attempts=%u shouldRender=1 state=%d' "$SRC"
grep -Fq 'HELIX_VULKAN_ENTROPY patterns=8' "$SRC"
! grep -Fq 'XR_MND_headless' "$SRC"

printf '\nPASS: strict-v4 event-pumped Vulkan stimulus artifact gate.\nsource_commit=%s\nvulkan_stimulus=%s\nstimulus_source=%s\nmetadata=%s\nSTATUS: built only; runtime not executed.\n' "5568963b538eaae708b9f957a9a3c162ddaf5de4" "$BIN" "$SRC" "$META"
