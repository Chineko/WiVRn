# Helix OpenXR build-tree runtime re-audit

Date: 2026-10-30

Frozen recovery implementation: `fa68cb3af0e0dfcb5e683abd951dfe0d2a126336`

Failure observed from v2 preflight:

- matching server logged `WiVRn 26.9-181-g1e1ba47f starting`
- dashboard reported `Server finished before registering on dbus`
- server then exited with `filesystem error: directory iterator cannot open directory: No such file or directory [/usr/local/share/openxr/1]`
- the runtime gate stopped before `RUNTIME TEST ARMED`

## Failure-class inspection

`server/active_runtime.cpp` selects the OpenXR runtime manifest in this order:

1. Flatpak manifest when running inside Flatpak;
2. `openxr_wivrn-dev.json` one directory above the local server executable when that development manifest exists;
3. otherwise the installed-prefix `share/openxr/1` directory.

The failed local build-tree launch reached path 3, proving that the expected development manifest was not available to `active_runtime::manifest_path()`.

WiVRn configures Monado with `XRT_OXR_RUNTIME_SUFFIX=wivrn`. Monado names its OpenXR runtime target `openxr_${XRT_OXR_RUNTIME_SUFFIX}`, therefore `openxr_wivrn`, and generates `${CMAKE_BINARY_DIR}/openxr_wivrn-dev.json` for build-tree use. WiVRn also enables/builds the `monado` library when `WIVRN_BUILD_SERVER_LIBRARY` is enabled.

The previous harness built only explicit `wivrn-server` and `wivrn-dashboard` targets. The revised preflight builds the exact required set:

- `wivrn-server`
- `wivrn-dashboard`
- `openxr_wivrn`
- `monado`

It does not install into `/usr/local` and does not create a fake installed-prefix directory.

## Audit A — local/function/final-artifact

Final executable path is `tools/helix-runtime-validate-bounded-recovery-v3.sh` followed by `tools/helix-runtime-validate-bounded-recovery-v2.sh`.

- v3 requires the expected branch and frozen implementation ancestry/source equivalence.
- v3 refuses tracked working-tree changes.
- v3 byte-verifies itself and v2 against the versions committed at checked-out HEAD.
- dependencies used directly by v3 are checked before use.
- configuration uses the repository `everything` preset only when the existing build tree is absent.
- v3 builds only the server, dashboard, OpenXR runtime, and libmonado targets needed for the normal desktop runtime chain.
- the expected development manifest path is exactly `build-everything/openxr_wivrn-dev.json`, matching `active_runtime::manifest_path()` for `build-everything/server/wivrn-server`.
- the manifest must exist and be non-empty.
- the manifest must parse as JSON with OpenXR file format `1.0.0` and a non-empty `runtime.library_path`.
- the referenced runtime library must resolve inside the exact `build-everything` tree, must exist as a regular file, and must be non-empty.
- no `/usr/local`, system OpenXR manifest, or installed runtime directory is created or modified by v3.
- after v3 passes, v2 independently rebuilds/checks server and dashboard and performs its existing Quest/runtime gates.
- v2 removes pre-existing WiVRn dashboard/server processes and requires the D-Bus server name to be unowned before launch.
- v2 requires a newly reported authoritative dashboard server log before arming.
- v2 requires exactly one `wivrn-server` and verifies `/proc/<pid>/exe` is the exact freshly built server.
- v2 verifies the runtime commit in that server log before `RUNTIME TEST ARMED`.
- the Quest APK is rebuilt, installed, read back, and its native libraries are checked for the same runtime commit.
- the wireless workload remains bounded; USB reconnection is explicitly required before Quest evidence collection.
- reduction treats zero replay as nondiagnostic, missing/mismatched time-diverse summaries as nondiagnostic, budget violation or recovery/send timeout/error as failure, and otherwise only grants a provisional result.

No material Audit A blocker remains in the final v3 -> v2 path.

## Audit B — whole-system/experiment

Decision question: does the frozen bounded one-frame-delayed recovery mechanism execute under representative VR use without creating a hard recovery failure or exceeding its frozen 20% replay-byte budget?

Success condition remains intentionally narrow:

- matching desktop and Quest runtime identity is proven before the workload;
- the actual server executable is proven before the workload;
- at least one time-diverse replay occurs for a diagnostic mechanism run;
- shutdown summary/event counts reconcile;
- replay payload remains within the frozen long-run 20% byte budget;
- no inconsistent-IDR, IDR timeout, encoder timeout, or time-diverse send error occurs.

A run with replay plus gap events and no hard failure may receive only `PROVISIONAL_PASS`. It does **not** prove that the replay caused a visible stall to disappear or that incomplete-frame/IDR fallout improved versus baseline. That effectiveness decision requires event-level and baseline comparison after the functional gate.

Observation boundaries:

- server log directly observes scheduling/replay, gap reports, IDR state, encoder errors, and time-diverse byte counters;
- Quest log directly observes incomplete frames and old-shard drops at the client accumulator;
- these signals do not by themselves identify AP/RF/root-cause loss location or prove subjective smoothness;
- the prior lower-path attribution result remains separate and is not reopened by this test.

Provenance:

- executable recovery source after the frozen implementation is unchanged; later branch commits are docs/tools validation work;
- v3 verifies build-tree OpenXR runtime provenance before v2 can launch the dashboard;
- v2 verifies server and Quest identities again at runtime/artifact level.

Observer/resource effects:

- no packet capture, tracefs, router capture, or extra high-rate observer is added;
- the recovery mechanism itself is the measured intervention and its byte budget is part of the verdict.

Nondiagnostic paths are explicit, so a nominally successful script completion cannot silently become evidence when replay or shutdown integrity is absent.

Under Rules 24, 31, and 32, this remains the highest-value next step because the recovery prototype is already compiled and frozen; the remaining blocker is proving its normal matching runtime path before considering cross-frame coding or tuning.

## Rule 40 classification of the OpenXR startup failure

### Direct evidence

- the matching build-tree `wivrn-server` started and printed runtime commit `1e1ba47f`;
- it exited before D-Bus registration;
- its final error was a filesystem directory-iterator failure on `/usr/local/share/openxr/1`;
- source code reaches that installed-prefix directory only when Flatpak handling does not apply and the expected build-tree development manifest does not exist.

### Supported inference

The previous target-limited build did not provide the complete build-tree OpenXR runtime artifact set required by the local server path. Building `openxr_wivrn` and `monado`, then proving the resulting manifest/library, is consistent with Monado/WiVRn's intended development-runtime path.

### Remaining ambiguity

Until v3 executes locally, static source inspection cannot prove whether another unrelated local build issue will appear after the OpenXR manifest blocker is removed. The pre-arm provenance gate is therefore retained and any such failure will stop before headset workload.

### Decision justified by the evidence

Do not create `/usr/local/share/openxr/1`, do not install the prototype system-wide, and do not change recovery or `active_runtime.cpp` for this experiment. Build and verify the expected build-tree OpenXR runtime artifacts first, then permit the existing strict pre-arm runtime provenance checks to decide whether headset validation may start.

## Gate status / checkpoint

Audit A: PASS.

Audit B: PASS for the narrow functional runtime question above.

Runtime gate: open only through `tools/helix-runtime-validate-bounded-recovery-v3.sh`. The script must not arm unless both its new OpenXR build-tree preflight and all v2 pre-arm provenance gates pass. Any subsequent preflight/build/install/launch/capture/reduction failure resets Rule 42 again.
