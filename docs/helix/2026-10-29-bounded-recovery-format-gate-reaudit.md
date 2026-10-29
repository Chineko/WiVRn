# Helix bounded recovery — Rule 42 re-audit after formatting gate failure

Date: 2026-10-29
Branch: `helix-bounded-time-diverse-recovery`

## Failure classification

The exact source transform completed successfully. The next gate failed during the explicit `clang-format --dry-run --Werror` check in `server/encoder/video_encoder.cpp`, around the pre-existing Helix `report_gap()` instrumentation block. The error class is source-format conformance, not runtime behavior and not a headset/device failure.

No headset validation occurred and no runtime evidence was consumed.

## Root cause

The branch already contained a non-clang-formatted `report_gap()` implementation from earlier Helix instrumentation. The first build helper incorrectly assumed that the complete touched compilation units were already format-clean and therefore treated a whole-file format audit as a simple prototype check.

The failure was valid: repository configuration enables strict warnings and formatting violations are a real compile/preflight blocker. The correct response is not to suppress the check or add warning exceptions.

## Failure-class audit

The entire touched source set is:

- `server/encoder/idr_handler.cpp`
- `server/encoder/video_encoder.h`
- `server/encoder/video_encoder.cpp`

The active prototype markers are required before resuming, so the recovery workflow cannot accidentally apply the formatting/build step to pristine or unrelated source.

The inherited `report_gap()` region is visibly unformatted and is inside `video_encoder.cpp`, the same compilation unit receiving the bounded recovery implementation. Rather than manually patching only the lines reported before clang-format reached its error limit, the replacement workflow audits the complete formatting delta for all three touched files.

## Corrective workflow

The revised helper:

1. verifies branch and ancestry;
2. verifies characteristic markers from the exact transformed prototype are present;
3. refuses unrelated tracked changes;
4. requires `clang-format`;
5. formats temporary copies of all three touched source files using the repository style;
6. counts the complete formatting delta before modifying the working tree;
7. aborts if formatting would change more than 320 source lines, preventing an uncontrolled whole-file reformat;
8. installs the formatted copies only when that bound passes;
9. runs full-file `clang-format --dry-run --Werror` on all three touched files;
10. runs `git diff --check`;
11. prints and bounds the total final source diff before build;
12. configures with the repository-defined `server` preset if necessary;
13. builds only `wivrn-server`;
14. stops on every failure and does not initiate headset validation.

## Audit A

- The source transform itself remains unchanged from the prior audited prototype.
- The resume helper does not reapply the transform and therefore cannot duplicate state or overwrite the current transformed source.
- Formatting is first performed on temporary copies, so an unexpectedly large formatting scope leaves the working source untouched.
- The full-file dry-run after installing formatted copies proves no remaining clang-format violation in the touched compilation units.
- A final diff-size guard prevents a broad accidental source rewrite from reaching compilation.
- No protocol, decoder retention policy, recovery budget, shard cap, replay timing, or IDR behavior is altered by this re-audit.

## Audit B

This failure provides no evidence for or against the time-diverse recovery mechanism itself. It is purely a local build/preflight blocker. Runtime validation remains gated behind a successful server compile and later matching desktop/Quest artifact validation.

The earlier failed command must not be retried unchanged. The revised helper at commit `d3f88a6c1be05b4dccd847afba03e45085d7a709` is the only approved resume path for the current transformed working tree.

## Gate status

- Prototype source transform: present locally on the user's branch checkout from the previous guarded run.
- Format failure: classified.
- Audit A after failure: complete.
- Audit B after failure: complete.
- Revised resume workflow: committed.
- Compile: not yet passed.
- Headset/runtime validation: not authorized yet.
