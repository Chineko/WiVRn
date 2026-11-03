# SGSR1 comparison client

Base: f87cbf84acea3e52370a7c15d4ed63a2d870ce87. Frozen server/runtime/APK untouched.
User-requested graphics comparison; separate from recovery roadmap.

Settings → Post-processing → SGSR1 enables reconstruction of opaque streams.
SGSR1 sharpening slider0–100 maps to upstream EdgeSharpness1.0–2.0; default75
maps to1.75. These percentages are not calibrated against Virtual Desktop.
0% still reconstructs with SGSR1; disable the toggle for the original path.
SGSR1 suppresses compositor supersampling/sharpening on opaque streams, retaining
their saved values for comparison when toggled off. Transparent streams retain
the previous alpha-safe reconstruction and compositor settings.

Qualcomm shader pinned to d926f074bcb9d714e179f1ce0fcb9ee2eeb5074e:
sgsr/v1/include/glsl/sgsr1_shader_mobile.frag. BSD3 license retained and shipped.
Uses RGBA/green-guide mode, VR edge threshold4/255. Runs in existing defoveation
pass before sRGB conversion and dimming. No extra framebuffer/pass or host render
resolution/encoder change. This reconstructs the packed foveated input grid;
it is not a second uniform-grid upscaling pass after defoveation.

Adaptations: manual four centered texture samples emulate GLSL gather because
Vulkan YCbCr conversion forbids OpImageGather; clamp to each eye texture bounds;
guard degenerate weight sums; supply bounded runtime edge sharpness. This may
cost more than upstream gather on ordinary RGB textures. Alpha is not sharpened.
New push constants total80bytes, within Vulkan's required128byte minimum.

Definition of done: shader compilation/SPIR-V validation, Android client build,
full Audit A/B, then device check of mode/slider persistence and live switching.
No visual superiority, latency improvement, VD equivalence or pixel cleanliness
claim without measurement. Existing frozen launcher intentionally rejects this
different APK: use a separately sealed comparison capture setup after validation.
