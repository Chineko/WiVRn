#!/usr/bin/env bash
set -euo pipefail

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || true)
[[ -n "$ROOT" ]] || { echo "error: run inside WiVRn checkout" >&2; exit 2; }
cd "$ROOT"

EXPECTED_BRANCH="helix-bounded-time-diverse-recovery"
SOURCE_BASE="fa68cb3af0e0dfcb5e683abd951dfe0d2a126336"
SELF_PATH="tools/helix-runtime-validate-bounded-recovery-v3.sh"
V2_PATH="tools/helix-runtime-validate-bounded-recovery-v2.sh"
DEV_MANIFEST="$ROOT/build-everything/openxr_wivrn-dev.json"

fail() { echo "Helix v3 runtime gate: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || fail "missing required command: $1"; }
for cmd in bash cmake git python3; do need "$cmd"; done

[[ "$(git branch --show-current)" == "$EXPECTED_BRANCH" ]] || fail "expected branch $EXPECTED_BRANCH"
git cat-file -e "$SOURCE_BASE^{commit}" 2>/dev/null || fail "frozen source base $SOURCE_BASE is not available locally"
if ! git diff --quiet "$SOURCE_BASE" -- . ':(exclude)docs/**' ':(exclude)tools/**'; then
    fail "runtime source differs from frozen prototype $SOURCE_BASE"
fi
if ! git diff --quiet || ! git diff --cached --quiet; then
    fail "tracked working-tree changes are present"
fi

# Exact tooling identity: both this wrapper and the already audited v2 runtime
# harness must be byte-identical to the files committed at HEAD.
for path in "$SELF_PATH" "$V2_PATH"; do
    head_blob=$(git rev-parse "HEAD:$path" 2>/dev/null || true)
    [[ "$head_blob" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve $path at HEAD"
    local_blob=$(git hash-object "$path")
    [[ "$local_blob" == "$head_blob" ]] || fail "local $path differs from HEAD artifact"
done

# The everything preset enables the server, dashboard, Monado OpenXR runtime
# target (openxr_wivrn), and the monado library used by its build-tree manifest.
# Build only that dependency set instead of unrelated ALL targets.
echo "[v3 preflight 1/2] Building desktop + build-tree OpenXR runtime targets"
if [[ ! -f build-everything/build.ninja ]]; then
    cmake --preset everything
fi
cmake --build build-everything --target wivrn-server wivrn-dashboard openxr_wivrn monado -j

# active_runtime::manifest_path() deliberately looks for this exact build-tree
# manifest before falling back to the install prefix. Validate the JSON and prove
# that its runtime library resolves inside this exact build tree.
echo "[v3 preflight 2/2] Verifying build-tree OpenXR development runtime"
[[ -s "$DEV_MANIFEST" ]] || fail "missing build-tree OpenXR development manifest: $DEV_MANIFEST"
python3 - "$DEV_MANIFEST" "$ROOT/build-everything" <<'PY'
import json
import pathlib
import sys

manifest = pathlib.Path(sys.argv[1]).resolve()
build_root = pathlib.Path(sys.argv[2]).resolve()
try:
    doc = json.loads(manifest.read_text())
except Exception as exc:
    raise SystemExit(f"invalid OpenXR development manifest {manifest}: {exc}")

if doc.get("file_format_version") != "1.0.0":
    raise SystemExit(f"unexpected file_format_version in {manifest}")
runtime = doc.get("runtime")
if not isinstance(runtime, dict):
    raise SystemExit(f"missing runtime object in {manifest}")
lib_value = runtime.get("library_path")
if not isinstance(lib_value, str) or not lib_value:
    raise SystemExit(f"missing runtime.library_path in {manifest}")
lib = pathlib.Path(lib_value)
if not lib.is_absolute():
    lib = (manifest.parent / lib).resolve()
else:
    lib = lib.resolve()
try:
    lib.relative_to(build_root)
except ValueError:
    raise SystemExit(f"OpenXR runtime library escapes build tree: {lib}")
if not lib.is_file():
    raise SystemExit(f"OpenXR runtime library referenced by {manifest} does not exist: {lib}")
if lib.stat().st_size == 0:
    raise SystemExit(f"OpenXR runtime library is empty: {lib}")
print(f"OpenXR development manifest: {manifest}")
print(f"OpenXR runtime library:       {lib}")
PY

# V2 owns the remaining already-audited identity, Quest install, clean desktop
# ownership, pre-arm server provenance, bounded workload, USB reconnect, capture,
# and reducer gates. It will rebuild server/dashboard cheaply if already current.
exec bash "$V2_PATH"
