# SGSR1 checkpoint — 2026-11-03

Native client source:55e525713d11e134856f4cb217aa8337c156f2eb.
Frozen server/runtime source:f87cbf84acea3e52370a7c15d4ed63a2d870ce87.
Implementation6640137a; GPU testc6c15198; render-mode telemetry55e52571.
Official shaderd926f074bcb9d714e179f1ce0fcb9ee2eeb5074e, BSD3 license packaged.

Android build PASS. Vertex/fragment glslang and spirv-val PASS. GPU pixel checks
PASS onRTX3090 (actual SGSR1 include: flat colors/borders, slider effect, bounded
edges). Full Audit A/B PASS before Quest runs. A missing build-tools34 inspection
path was corrected to installed35.0.0, followed by full re-audit before runtime.

Separate packageorg.meumeu.wivrn.sgsr1; original.local remains installed.
APK: /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/sgsr1-comparison/client.apk
SHA256:19c7aa2bf95a4abb6eeda41a0837f9987f84ee2745203a8e1085d0f2555832fc

Outputs root:
/home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs

SGSR1 smokevrchat-capture-20261103T101458Z: capture_valid=true,60.95s, render log
enabled=true sharpening_percent75. Meta controlvrchat-capture-20261103T101655Z:
capture_valid=true,30.47s, SGSR1 enabled=false; private config requested Meta flag8.
Both eyes1536x1600Main10 in both runs, mappedVRChatPIDs52331/53741, settings
restoration and frozen artifact identityPASS. No searched fatal/VK errors. Both
original evidence seals independently verified. Not run with validation layer;
absence of logged errors does not establish all Vulkan validity conditions.

Rule40 direct evidence: candidate shader compiled, produced expected synthetic
pixels, executed chosen SGSR1 path onQuest and continued streaming. Supported
inference: comparison modes are available for user evaluation. Ambiguity: no
perceptual advantage, VD75% equivalence, Quest cost or latency improvement proven.
Pixel cleanliness in streaming remainsNOT_ESTABLISHED; this synthetic test is not
a full real-stream pixel-content oracle. Alpha streams fall back to old path.
Decision: let user compare in a fixed scene through Post-processing controls;
keep original pipeline/binaries intact. No recovery/network tuning from this work.

Run outputs/run-vrchat-sgsr1.py (absolute path recommended), default modeSGSR1,
strength75, capture untilCtrl+C. Options --sharpening0..100, --mode meta,
--mode bilinear, --secondsN. Controls also work in WiVRn Post-processing settings.
0% means upstream edge sharpness1.0, not bilinear; disableSGSR1 for original path.
Launcher copies pairing identity privately on first use; never logs key bytes.
It verifies original frozen seals then explicitly selects this independently sealed
client APK. It never patches the original seal or frozen launcher.

Launcher SHA256:b81e00fb806b284f7befab419641cbc425ad6ede4f7cf76dbc2cee71e6644f37.
Complete audit: outputs/sgsr1-comparison/audits.md. Final wrapper source included
in Meta run's sealed evidence; mode/strength recorded as requested because user
can change controls midcapture. Render logs are the evidence of active settings.
This checkpoint/source is committed locally; no push, PR, issue or comment.
