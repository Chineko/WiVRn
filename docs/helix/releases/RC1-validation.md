# RC1 audit gates — 2026-11-03

Scope: normal launcher/release assembly of exact tested native binaries, not a native
rebuild. Source RC starts at ec6a57b9, excludes3329a3a6 diagnostic commit. Diagnostic
evidence and original branches/bundles preserved. Runtime settings/graphics unchanged.

Prior NVENC+profile user run20261103T160647Z: complete, capture_valid=true, NVENC
confirmed, both eyes1472x1536Main10, frozen hashes/restorationPASS, independent
recursive seal verified. P0 in1537/1537 checked late samples; graphics mean1871MHz,
memory9751MHz. User reports clean. This is not unique proof of historical P2 cause.

Audit A PASS: entire final standalone launcher/assembly reviewed. Seal verifies all
packaged files and exact external xrizer; APK installation readbackhash required.
No inherited runner/source-worktree dependency. Manifest resolves into private temp
absolute paths; static template has no user build paths. ConfigNVENC/h265/10bit,
application[], /opt/xrizer, unchanged Steam launch, LAN/source/wake/Guardian/session
gates. Cleans HELIX_/PAIR_/WIVRN_DUMP and sidecar loader entries in server env only.
No GPU sampler, logcat logger, image FIFO, shader trace, probe library, canary or
capture files included in release workflow. Existing normal native console logs
remain; opt-in native recovery features are retained, not stripped or activated.

Console reader continuously drains with128x4096char bounded startup ring. Lifecycle
review caught server childsetsid(): cleanup now remembers same-exe descendants
with PID starttime, signals only owned processes, waits/kills boundedly, joins reader
and verifies runtime registration restoration. No unrelated game kill. Temp files
removed. Stdout thread daemon limits failure hang; failure reported if it fails to
join. Installation/config errors do not start server. Ctrl+C cleans started session.
NVIDIA profile installer explicit-only; preserves unrelated fields, backs up existing
file, guards concurrent writes, atomically replaces and readbackchecks. Existing
installed setting idempotence tested. No clock locks or driver modifications.
Syntax/help, complete file hashes, external identity and no missing shared libs
checked. Launcher/metadata committed before runtime smoke.

Audit B PASS for30s packaging smoke: test same known native components via new clean
entry, confirm actual client connection/VRChat session and normal teardown/restoration.
No quality/performance change claim from cleanup; no need to repeat subjective
comparison. Earlier known-good NVENC P0 run validates selected native stack, not
this wrapper's startup/cleanup; new smoke required before publish. Headset controls
and saved settings preserved. Package host-specific dependencies/IPs documented;
not advertised universal installer/store production build. Native debug/development
identities retained rather than relabeling/rebuilding tested binaries. RC designation
applies to sealed assembly and tagged source. Publication requires smoke PASS,
archive extraction/checksums PASS, then remote refs and uploaded asset checks.

## Packaging smoke failure class / renewed full gates

First wrapper smoke stopped/restored correctly and connected headset, but had no
VRChat application evidence. Classified as non-decisive startup/manifest packaging
failure, not a native encoder regression. Source active_runtime::manifest_path
discovers executable-parent/openxr_wivrn-dev.json, independently of server's
XR_RUNTIME_JSON. A temp manifest alone didn't satisfy discovery in relocated bundle.

Final launcher uses private same-filesystem hardlink staging: unchanged binary at
session/server/wivrn-server and generated absolute session/openxr_wivrn-dev.json.
Normal server runtime manager discovers it; no direct registration rewrite or
VR_OVERRIDE. Hardlink shares exact verified bytes; no191MB binary copy. Package
files stay immutable. Must extract into user-writable directory. Cleanup tracks
staged executable and starttime-owned setsid children, then deletes staging only
after server/reader stop and registration restoration check. Added90s VRChat app
log readiness plus actual mapped RC ELF/xrizer gate; a connection alone no longer
passes. Same Steam semantics and client preferences.

Full Audit A repeated on all final source, package manifest/seal, hardlink/path
ownership, profile JSON merge, command/dependency assumptions, file/install gates,
bounded reader/waits, all parent/setsid child cleanup/error/abort paths, runtime
restoration and temp lifetime. No source/native graphics change. No material
blocker remains; A PASS. Full Audit B repeated on entire workload→release claim:
prior native26min user test distinguished from new wrapper validation; actual
VRChat connection/mapping now required; no quality/performance inference from
startup alone. Source identities/host constraints and privacy of release assets
reviewed; no scene/config/key/log dumps in package. B PASS before next smoke.

Corrected smoke initially hit existing-session guard during the previous shutdown
tail; no new device launch occurred. Subsequent process inventory empty. Full
failure-class review added starttime-bound tracking/cleanup for VRChat launched
by this session (preflight requires none before launch), including startup aborts.
Full A repeated: final profile/artifact/APK checks, staging/manifest discovery,
reader/parent/setsid child/game ownership, timeouts and every cleanup path inspected.
Final B repeated: actual app log plus exact mapped runtime required,30s begins
after verified game readiness, previous native result not used to bypass wrapper
validation. No quality/performance threshold changed. A PASS / B PASS before retry.

Final smoke PASS: actual VRChat app log and mapped package ELF/xrizer gate passed;
three NVENC/h26510bit configuration entries,30s after readiness, exit0, session
stopped/runtime registrations restored and no leftover server/game processes.
Optional SolarXR socket and startup frame-gap/IDR warnings were observed in console;
not treated as proof of image corruption or native regression. No new visual
quality/performance claim from unattended smoke. Known clean native user run remains
the26min NVENC+profile test. Final archive extracted and all10 artifact hashes
matched. Archive contains only explicitly whitelisted static files, never private
session staging, installed APK pull, user keys/config, recordings or diagnostics.
