# Vibrance validation checkpoint

Client81debe382c4ec0b96bf500f205c41a801c54c17e. Server/runtime remain
f87cbf84acea3e52370a7c15d4ed63a2d870ce87. Branchhelix-sgsr1-comparison.

APK: /home/chineko/Documents/Codex/2026-10-31/work-locally-in-home-chineko-wivrn/outputs/sgsr1-vibrance/client.apk
SHA256:e419f94812a9ee5c4f090f1caa16e34e54c4e5aa90c732994c820807807b671c
Separate packageorg.meumeu.wivrn.sgsr1; original app and frozen bundles unchanged.
Previous SGSR1-only APK/seal also preserved at outputs/sgsr1-comparison.

Android build, GPU synthetic pixel tests, glslang/spirv-val and full Audit A/B
PASS. Actual Quest capturevrchat-capture-20261103T102339Z passed30.47s, PID56074,
both eyes1536x1600Main10, artifact identity and settings restorationPASS. Quest
render log confirms vibrance_percent50, SGSR175. Evidence seal independently
verified. No searched fatal/VK errors (validation layer not enabled).
After test candidate app stopped; vibrance reset0 and byte readback verified.

Rule40 direct: actual shader preserves neutral/DC colors and0%, boosts muted
color in GPU fixture, builds and executes onQuest with continued HEVC10 stream.
Supported inference: slider usable for user preference. Ambiguity: no subjective
quality, HDR calibration, real-stream pixel cleanliness or performance benefit
established. Decision: leave neutral default, let user choose intensity in
Post-processing → Vibrance; no network/recovery changes justified.

Local standalone entry: outputs/run-vrchat-vibrance.py, capture untilCtrl+C.
--vibrance0..100 selects value; omitted preserves saved setting. This entry uses
the new independent seal, while old run-vrchat-sgsr1.py retains its original APK.
Reusable tracked launcher: tools/helix-run-client-comparison.py --capture-dir
/absolute/path/to/outputs [--vibrance50]. External frozen bundle/harness and sealed
comparison APK are required; Git does not contain these binaries. The tracked
entry adds only a required explicit capture directory to the runtime-tested
local wrapper. Help/syntax checked. Full audit record: outputs/sgsr1-vibrance/audits.md.

Next: user visual comparison at fixed scene, adjust vibrance to preference.
No additional tuning or runtime tests needed to select a subjective setting.
