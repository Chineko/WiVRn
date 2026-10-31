# Frozen checkpoint: live8 / burst8 4K texture churn

Date: 2026-10-31

This checkpoint is frozen before starting the VRChat-like representative workload lane.

## WiVRn recovery workload

- frozen runner contract: 27000 frames / 449 cycles / spacing 20 / expected 1347
- runtime verdict: PASS
- injections=1347
- feedback=1347
- recoveries=1347
- invalidations=1347
- errors=none

## Vulkan churn workload

- texture: 4096x4096 RGBA8
- bytes per texture: 67108864 (64 MiB)
- live_images=8
- retained live texture bytes=536870912 (512 MiB)
- burst_size=8
- burst_dwell_ms=16000
- max_cycles=180
- allocations=180
- uploads=180
- frees=180
- verify_failures=0
- errors=0
- terminated=complete

## Frozen sealed artifact hashes

- source_sha256=94228dbab8a63290d3b66671fb3aa1b3845096652e93d719a565e1335a6c4971
- binary_sha256=06ef8b3bc28bad788457f1d2c6c036ad5a144aab018240f60f84a8e8929a3a60
- metadata_sha256=7702a3c8c828afb4832c0fb6db758f312a1cc680751e90b59356a6e62154d2a6

## Classification

BUILD=PASS
SEAL=PASS
AUDIT_A=PASS exact-sealed-churn4k-live8-burst8-512MiB-8x64MiB-back-to-back-dwell16s
AUDIT_B=PASS bank32-contract-27000-449-20-1347
RUNTIME=PASS full formal combined completion

No thresholds or workload parameters in this checkpoint are to be changed retroactively. Future representative-workload tests are a separate lane and must not rewrite this result.
