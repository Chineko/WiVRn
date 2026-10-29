# Helix Development Rule 42 — Require two audits before runtime validation

A Helix change that is going to consume a build, device, headset, injected-loss, or other meaningful runtime-validation cycle must pass **two different audits** first.

Neither audit substitutes for the other.

## Audit A — local/function audit

Inspect the changed implementation at the level where defects are introduced.

Check, as applicable:

- each changed function, helper, script stage, callback, or state transition;
- inputs, outputs, ownership, lifetime, cleanup, error handling, and bounds;
- shell/tool syntax and platform compatibility;
- concurrency, blocking, queue growth, resource use, and failure cleanup;
- whether the concrete implementation actually matches the stated design;
- whether one fixed defect has siblings elsewhere in the same failure class.

The goal is to answer: **is each changed part internally correct enough to test?**

## Audit B — whole-system audit

Then ignore the implementation details temporarily and review the experiment or feature end to end.

Check, as applicable:

- the actual engineering question and success condition;
- every relevant boundary from producer to consumer;
- whether the instrumentation observes the boundary it claims to observe;
- missing competing hypotheses and unmeasured external load;
- instrumentation side effects or observer-induced behavior;
- runtime/build identity and environment assumptions;
- clocks, correlation, sampling, capture integrity, and data provenance;
- storage, CPU, network, scheduler, radio, and other shared-resource pressure;
- what conclusions the resulting evidence can and cannot support;
- whether a successful run can still be non-decisive because the experiment asks the wrong question.

The goal is to answer: **can the system-level test actually justify the decision we plan to make from it?**

## Gate rules

1. Complete the local/function audit first, then the whole-system audit.
2. If either audit finds a blocker that can invalidate or materially weaken the run, fix or explicitly narrow the experiment before runtime validation.
3. A syntax check, code review, successful build, or clean diff does not count as the whole-system audit.
4. A good architecture diagram or experiment plan does not count as the local/function audit.
5. After a material fix discovered by either audit, re-audit the affected level before declaring the validation gate ready.
6. Record important audit findings and remaining limitations so later work cannot silently turn an assumption into established fact.
7. Do not call a run "final", "decisive", or equivalent merely because the tooling starts successfully. Decision capability must follow from both audits and the evidence gates in the run itself.

This rule exists to prevent tunnel vision in both directions: locally correct code attached to a flawed experiment, and a sound system plan implemented by fragile or incorrect functions.
