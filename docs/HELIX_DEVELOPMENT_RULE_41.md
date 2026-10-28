# Helix Development Rule 41 — Minimize manual user-side workflow

This rule is normative and supplements `docs/HELIX_DEVELOPMENT_RULES.md`.

Helix development must minimize manual terminal work, repetitive copy/paste steps, and user-side source editing when the same work can be performed safely and atomically by the assistant or repository tooling.

The user's terminal time should be reserved primarily for actions that genuinely require the local machine, headset, or runtime environment: building, installing, launching, pairing, reproducing behavior, and collecting runtime evidence.

Rules:

1. Prefer assistant-applied repository changes when the available repository tools can make the change safely and with a reviewable diff.
2. Do not ask the user to perform source edits manually when an atomic repository-side edit is available.
3. Avoid generated helper downloads, giant patch blobs, whole-file rewrites, and multi-step copy/paste scripts for small changes.
4. Prefer the smallest reliable edit mechanism. If one method becomes fragile or overloaded, switch methods immediately rather than producing larger workarounds.
5. Group validation commands into the fewest practical terminal blocks. Do not require repeated `git status`, `git diff`, or source-inspection loops unless a concrete risk or failure makes them decision-relevant.
6. A small code change should not require a long sequence of user-mediated editing checkpoints. Keep implementation work on the implementation side and runtime validation on the user's machine.
7. When a tool limitation prevents a safe repository-side edit, explain the limitation briefly and choose the least burdensome fallback. Do not make the user reconstruct large files or patches by hand.
8. Treat repeated copy/paste friction, broken generated attachments, malformed patches, or guard-script failures as process failures. Apply Rule 7's strategy-switch requirement immediately.
9. Before asking for another local build or headset run, consolidate all known required source fixes so the user is not forced through avoidable rebuild cycles.
10. Preserve auditability: reducing user interaction must not mean skipping diff review, build gates, commit-before-validation discipline, or evidence requirements. The goal is fewer manual steps, not weaker validation.

Default workflow:

`assistant applies narrow repo change -> assistant audits repository diff/state -> user builds once -> user runs once -> user provides complete logs -> assistant analyzes and documents result`

Manual terminal editing is a fallback, not the normal Helix development workflow.
