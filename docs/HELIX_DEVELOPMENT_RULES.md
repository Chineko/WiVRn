# WiVRn Helix Development Rules

This document exists to keep Helix development focused, measurable, and aligned with the project roadmap. It is specifically intended to prevent circular debugging, over-polishing small details, scope drift, and losing sight of the larger reliability architecture.

## 1. Always anchor work to the roadmap

Before changing code, identify which Helix milestone the change belongs to.

If a change does not clearly advance the current milestone, it should normally be deferred and written down for later rather than implemented immediately.

Current priority order:

1. Decoder reliability
2. Congestion prevention
3. Fast packet recovery
4. FEC
5. Recovery hardening
6. Integrated adaptation

Do not jump ahead simply because a later-stage idea is interesting.

## 2. Define the success condition before coding

Every task must have a concrete definition of done.

Examples:

- Decoder stall recovery: decoder output resumes automatically without restarting the stream.
- Packet pacing: high bitrate no longer produces pathological burst loss while latency stays bounded.
- Retransmission: missing shards are recovered only when they can still meet the decode deadline.

If the success condition cannot be stated clearly, the task is not ready to implement.

## 3. Prefer the smallest useful experiment

Implement the minimum change needed to test the hypothesis.

Do not build the final architecture before proving the mechanism.

Examples:

- Use existing feedback semantics before introducing a protocol revision.
- Test a simple pacer before designing a complete bandwidth estimator.
- Measure whether retransmission helps before adding complex scheduling logic.

A small working experiment is more valuable than a large elegant system that has not been validated.

## 4. Do not confuse an implementation detail with the project goal

A local bug may matter, but it must not consume the project indefinitely.

When a problem appears, classify it:

- blocker: prevents the current milestone from working
- correctness issue: produces wrong behavior in realistic use
- robustness issue: worth fixing, but not blocking progress
- cleanup: readability, style, naming, or refactoring
- future optimization: performance work not required for the current milestone

Only blockers and meaningful correctness issues automatically stop forward progress.

## 5. Use a debugging budget

Do not repeatedly investigate the same small issue without changing the experiment.

After roughly three failed attempts at the same problem:

1. restate the hypothesis
2. list what has been proven
3. identify what remains unknown
4. change the method of investigation
5. consider temporarily bypassing the issue if it is not a blocker

Do not keep making small variations of the same fix indefinitely.

## 6. Separate evidence from assumptions

Maintain a clear distinction between:

- observed behavior
- source-code-confirmed behavior
- measured behavior
- hypothesis
- inference from another streaming system

Never treat a Virtual Desktop, Moonlight, ALVR, WebRTC, or Steam behavior as automatically correct for WiVRn.

Borrow mechanisms, not assumptions.

## 7. Measure before optimizing

Any performance or reliability change should have a measurable signal.

Useful signals include:

- packet loss
- packet reordering
- frame completion rate
- decoder submit-to-output latency
- recovery latency
- IDR frequency
- send queue delay
- bitrate changes
- retransmission success
- FEC repair success

If a change cannot be observed in telemetry, add enough telemetry to evaluate it before tuning it heavily.

## 8. Do not solve every failure with an IDR

Helix must use the cheapest recovery mechanism that can still meet the latency budget.

Preferred order:

1. tolerate harmless reordering
2. repair locally with FEC when available
3. retransmit if the packet can still arrive before deadline
4. drop the frame if necessary
5. request IDR when prediction continuity is broken
6. flush the decoder if the decoder is unhealthy
7. recreate the decoder only when lower-cost recovery fails

IDRs are a recovery tool, not a universal error handler.

## 9. Keep latency bounded everywhere

No queue is allowed to grow indefinitely.

This applies to:

- encoded frames
- UDP packets
- reorder buffers
- retransmission queues
- decoder input
- decoded image queues

When latency and completeness conflict, Helix generally prefers fresh data over stale data.

## 10. Do not let recovery create a worse failure

Every recovery mechanism must be checked for feedback loops.

Examples:

- IDR causes a larger burst, causing more loss, causing another IDR
- FEC adds enough bandwidth to worsen congestion
- retransmissions arrive too late and increase queue pressure
- decoder resets happen repeatedly and prevent stable recovery

Recovery mechanisms must have rate limits, deadlines, or escalation limits where appropriate.

## 11. Keep mechanisms separate until measurement proves they should be coupled

Treat these as distinct systems:

- packet loss recovery
- congestion control
- decoder health
- bitrate control
- FEC
- retransmission

Do not create one large controller too early.

Helix 0.x should favor understandable modules and explicit signals. Integration comes later.

## 12. Preserve a clean upstream relationship

Helix is based on clean upstream WiVRn, not unrelated modifications from other development branches.

Rules:

- feature branches start from the Helix integration branch
- unrelated personal modifications do not enter Helix accidentally
- upstream changes are synchronized deliberately
- avoid large unrelated refactors that make upstream merging difficult

A clean diff is a feature.

## 13. Keep commits and PRs narrow

A commit should answer one understandable question.

A PR should represent one meaningful Helix step.

Avoid mixing:

- functional changes
- unrelated cleanup
- formatting rewrites
- broad refactors
- multiple roadmap phases

Small reviewable changes make regressions easier to find and revert.

## 14. Do not polish prototypes prematurely

A prototype should first prove that the mechanism works.

Do not spend excessive time on:

- perfect naming
- ideal abstractions
- micro-optimizations
- extensive refactoring
- UI polish

until the underlying behavior has been validated.

Once the experiment succeeds, clean it up before integration.

## 15. Stop when the milestone is good enough to test

Do not keep adding features to a milestone before testing it.

For each milestone:

1. implement the minimum viable mechanism
2. build it
3. test it under controlled failure
4. record results
5. fix blockers
6. merge the checkpoint
7. move to the next planned improvement

Avoid turning every milestone into a complete redesign.

## 16. Revisit the big picture regularly

At each meaningful checkpoint, answer:

- What failure class are we currently solving?
- What has been proven?
- What remains the largest reliability problem?
- Is the current task still the highest-value next step?
- Did new evidence invalidate any roadmap assumption?

If the answer shows that current work is no longer the best next step, update the roadmap instead of continuing out of inertia.

## 17. Track deferred ideas instead of implementing them immediately

Interesting ideas should not disappear, but they also should not derail the current phase.

When something useful appears outside the current scope:

- write it down
- attach it to the appropriate roadmap phase
- include enough context to revisit it
- return to the current milestone

The backlog exists so the active task can stay small.

## 18. Prefer reversible decisions early

During early Helix development, choose designs that can be changed cheaply.

Examples:

- reuse existing protocol semantics before requiring a protocol bump
- keep controllers modular
- expose tuning parameters while collecting data
- avoid hard-wiring assumptions about one headset or one network

Irreversible complexity should require evidence.

## 19. Never claim validation that has not happened

Use precise status language:

- implemented
- reviewed
- builds successfully
- tested on device
- tested under injected loss
- measured improvement
- ready for merge

These are different states.

Code existing in a branch does not mean it works.

## 20. Use escalation, not endless retries

When a recovery mechanism fails repeatedly, move to the next defined level.

Example decoder path:

IDR request

→ output still stalled

→ decoder flush

→ output still stalled

→ decoder recreation

→ still broken

→ report hard failure with enough telemetry to diagnose it

Do not remain forever in one recovery state.

## 21. Protect the project from scope creep

Helix is primarily about wireless PCVR streaming resilience, latency, and recovery.

Features unrelated to those goals should not be added merely because they are convenient while working in the codebase.

A useful question is:

> If this change disappeared, would Helix become meaningfully worse at reliable low-latency PCVR streaming?

If not, it probably belongs elsewhere.

## 22. Default decision rule

When uncertain between two paths, prefer the one that:

1. gives measurable information sooner
2. changes less code
3. preserves compatibility
4. is easy to revert
5. directly advances the current milestone

This rule should be used whenever there is no strong reason to choose otherwise.

## 23. End-of-session checkpoint

At the end of each substantial development session, record:

- current branch and commit
- what changed
- what was actually validated
- known failures
- next highest-priority action
- anything deliberately deferred

This prevents future work from repeating old investigations or losing context.

## 24. The governing principle

The purpose of Helix is not to build the most complicated streaming stack.

The purpose is to build a streaming stack that fails gracefully, recovers quickly, keeps latency bounded, and remains understandable enough to maintain.

When complexity does not produce a measurable reliability or latency benefit, do not add it.
