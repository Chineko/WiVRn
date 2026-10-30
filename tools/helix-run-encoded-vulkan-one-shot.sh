#!/usr/bin/env bash
set -euo pipefail

# One-shot encoded NVENC validation: build the graphics-bound Vulkan stimulus
# against the frozen encoded artifacts, then immediately run the audited
# Vulkan/OpenXR runtime harness only if that build/audit gate passes.
build_tooling="9fe49dbcc65534b08a8537aa85a855aa399b6a98"
runtime_tooling="cfa03d67546f25ed5d074d41f035adbf2918bbcd"

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$repo_root" ]] || { echo "FAIL: run from inside WiVRn checkout" >&2; exit 2; }
cd "$repo_root"

build_script="$(mktemp)"
runtime_script="$(mktemp)"
cleanup(){ rm -f "$build_script" "$runtime_script"; }
trap cleanup EXIT INT TERM

git cat-file -e "${build_tooling}^{commit}" 2>/dev/null || git fetch origin "$build_tooling"
git cat-file -e "${runtime_tooling}^{commit}" 2>/dev/null || git fetch origin "$runtime_tooling"
git show "${build_tooling}:tools/helix-build-encoded-vulkan-stimulus.sh" >"$build_script"
git show "${runtime_tooling}:tools/helix-run-encoded-nvenc-torture-vulkan.sh" >"$runtime_script"

# Static contract checks before touching the Quest.
grep -Fq 'stimulus_contract=PASS graphics-bound-vulkan-projection-layer' "$build_script"
grep -Fq 'XR_KHR_VULKAN_ENABLE2_EXTENSION_NAME' "$build_script"
grep -Fq 'xrCreateSwapchain' "$build_script"
grep -Fq 'xrEndFrame' "$build_script"
grep -Fq 'HELIX_VULKAN_DONE frames=220' "$runtime_script"
! grep -Fq 'XR_MND_headless' "$runtime_script"

echo '[A/2] Building and statically auditing graphics-bound Vulkan stimulus'
bash "$build_script"

echo '[B/2] Running encoded NVENC -> Quest recovery gate'
bash "$runtime_script"
