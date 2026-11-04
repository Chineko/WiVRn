# RC2 correction and publication gate

RC1 was published before required CI completed. That was a release-process error.
Its release is now marked validation-pending; its published tag is not rewritten.

Failures: clang-format22 rejected include ordering/wrapping/indentation in three
client files. Ruff0.16.0 rejected imports, executable modes on three new tools,
subprocess capture spelling and implicit check=False in the comparison launcher.
The whole class is fixed; no lint/format rules were weakened or paths excluded.

Local verification covers363 tracked C/C++/Protobuf/CUDA files with the action's
actual extension regex and all28 configured Python tools. Checked file discovery
explicitly to reject a false zero-files pass under an ignored worktree parent.
Ruff check and format--check PASS; clang-format22 dry-run/Werror PASS. GPU shader
pixel fixture including SGSR1 and vibrance PASS. RC launcher AST is identical to
RC1 after excluding harmless import ordering. Native C++ changes are formatting/
include ordering only. Packaged native server/runtime/APK hashes unchanged.

Formatting expands previously compact Python code; reviewed diff and AST instead
of treating line-count growth as a functional rewrite. No new headset run needed
for formatting-only changes; prior native and normal-launch validation retained.
RC2 wrapper byte hash/seal updated; no frozen RC1 artifacts overwritten.

Full Audit A: exact final scripts/modes, formatter versions/scope/nonzero discovery,
safe subprocess equivalence, unchanged buffer/ownership/cleanup and artifact checks
reviewed. Full Audit B: local tests do not replace CI; candidate publication stays
blocked until Build, Format and Locales all succeeded for its exact full source SHA.
tools/helix-release-gate.py checks that condition and rejects missing/pending/failed
runs. Tested against the actual failed RC1 commit: blocked as expected.

At source-commit time remote CI remains pending. Publication may happen only after
that gate passes. No speculative ready/CI-approved claim or tag movement.
