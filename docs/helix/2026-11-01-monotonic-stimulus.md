# Stimulus ladder correction

The v1 visual input used level*255/31 as a bit mask, independently reseeded the
noise per level, and toggled tile geometry with level parity. These are three
source-confirmed discontinuities, not a monotonic amplitude/entropy ladder. At
levels15/16 the masks123/131 randomize six/three bits, with the high bit newly
enabled. This invalidates the old mapping assumption; it does not uniquely explain
every prior encoded peak. Old source, artifacts, thresholds and captures stay frozen.

The repair uses the same deterministic noise sample at each pixel for all32
levels, fixed tile geometry, and rounded linear interpolation from the base to
that sample. Per-channel distance from base is nondecreasing, endpoints are exact,
and adjacent levels differ by at most9 channel units. There is no clipping/wrapping
or new dependency. Integer intermediates are bounded by7920. Alpha stays255.
The existing level selection formula, plan, seed, bitrate and bank bounds stay
unchanged; this is deliberately a new visual stimulus version.

Validation uses the exact production pixel helper. Exhaustive all256x256 channel
endpoint pairs over32 levels pass distance/step/endpoints/alpha tests. Stimulus
compiles with warnings as errors; existing seven reducer tests pass. Pinned lint
and format checks pass. No test claims that encoded size must mathematically
increase for every adjacent level.

Offline controlled HEVC tests use256x160 RGB, two identical frames per level,
GOP2/no B frames, fixed QP, same encoder settings for old/new, and verify actual
Main10 profile. Both libx265 CPU and real local hevc_nvenc GPU were measured.
NVENC QP32: old level15/16 I-size19677→25903 bytes (+31.6%); repaired19074→19813
(+3.9%), no decreasing I-size steps. QP40: old jump+56.3%, six decreasing steps;
repaired jump+7.2%, one decrease at level0→1 (444→414 bytes). The repaired
amplitude mapping is monotonic, while codec output remains an empirical signal.
The initial all-intra CPU probe reported Rext and was retained as a rejected
Main10-profile experiment; a full local failure audit preceded the GOP2 probe.
The corrected CPU GOP2 probe reported Main10 and a small level0→1 decrease.

Raw sweeps, exact commands, profiles, packet sizes and original failure audit are
retained under outputs/stimulus-v2-local-validation. GPU fixed-QP results support
the mapping repair but do not establish production CBR traffic calibration,
compositor behavior, recovery or pixel cleanliness. No acceptance threshold changed.

Full Audit A scope: source/helper/actual bank generation, deterministic eye traversal,
bounded staging allocation, pixel arithmetic, format compatibility, existing GPU
ownership, exact private builds/seals, final executable paths, all timeout/abort/
cleanup behavior and complete runner/transport/decoder observers must pass again.
Full Audit B scope: distinguish repaired input control from codec monotonicity;
retain exact canary chain and independent source/peak/calibration gates, clocks,
provenance, resource costs, competing encoder/compositor causes and frozen limits.
One end-to-end characterization is justified only after both final artifact audits.
Any failure closes the gate. Pixel cleanliness remains NOT_ESTABLISHED.
