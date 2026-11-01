# Input-correlation checkpoint — 2026-11-01

Tested source: 52d92c6aa6d55c14cf4613206dd93113523f3f75.
Run 07 completed five minutes. Full Audit A/B passed before execution; build, exact source/artifact identities, independent postrun hashes, Main10 recovery, traffic calibration, peak identity and input correlation PASS. No threshold/plan/bitrate/content change. Pixel cleanliness remains NOT_ESTABLISHED.

Left peak: P-frame 13520, 60,312 bytes, source index13492, own-eye level16; previous encoded source index13491 also level16.
Right peak: P-frame24679, 68,084 bytes, source index24617, own-eye level16; previous encoded source index24616 also level16. Other-eye level changed15→16 at the right peak, which does not establish a cause.

Rule40 direct evidence: exact host-monotonic projection timestamp joins succeeded on both eyes; sender and NVENC maxima agree. These two observed peaks were not immediate same-eye stimulus-level changes. This does not identify the old run06 oversize frame input, nor prove identical encoded pixels or stable peak distribution. Full exact canary chains reached MediaCodec/AImage; zero probe overflow remains required.

Source-confirmed additional candidate: NVENC enables intra refresh when supported, period100/count50. A P-picture classification does not rule out intra-coded regions. CBR history, intra refresh, GPU/compositor transforms and reference behavior remain competing explanations. No causal attribution or encoder repair is established. Do not repeatedly rerun looking for a favorable maximum.

Next bounded diagnostic: record actual NVENC intra/inter CTB counts for peak and previous output using the existing SDK getRCStats field, plus resolved intra-refresh configuration. This can distinguish all-inter versus intra-heavy output without assuming P implies no refresh. Audit API/runtime support and observer overhead before enabling it. Keep exact source correlation. A controlled intervention must follow evidence; no blind bitrate/content change.

Earlier run06 calibration failure remains retained. Run07 is a passing characterization, not evidence of two repeatably calibrated runs. No further device reservation is implied. Existing artifacts remain tied to tested source above; documentation successors must not bypass exact source or audit gates.

See result.json, artifact-seal.json and audits.md for exact per-eye events, paths, SHA-256 values and complete audits. Raw captures/binaries remain in the local outputs directories.
