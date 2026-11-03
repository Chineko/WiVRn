# Vibrance

Post-processing → Vibrance,0–100%, default0 (unchanged). Independent of SGSR1 or
Meta mode. Boosts muted chroma around Rec709-weighted luma, attenuates the boost
for saturated colors and limits gain before leaving RGB gamut. It is an artistic
adjustment, not a color-calibration or HDR tone-mapping operation. Applied before
existing sRGB conversion/dimming. For alpha, unpremultiply only above the existing
0.02 opacity threshold and premultiply again; alpha values remain unchanged.
0% skips the shader operation entirely. Existing80byte push block uses spare z;
no added descriptors, buffers, passes or synchronization. Setting persists and is
clamped at load, UI and shader input; render log records changes once.

GPU fixture covers black/white/grays, exact disabled behavior, muted-color boost,
luma stability and saturated/near-boundary inputs; SGSR1 tests still pass. Vulkan
fragment compilation/spirv-val passed. Quest runtime gate remains full Audit A/B,
Android build and mode/telemetry/stream identity checks. No quality or performance
improvement claim follows from a synthetic shader test alone.
