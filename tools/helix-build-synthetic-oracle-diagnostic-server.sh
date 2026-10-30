#!/usr/bin/env bash
set -euo pipefail

REPO="Chineko/WiVRn"
BASE="951ce95cd2ea14bf34e099d2b7e56f272d05cdac"
TRANSFORM_COMMIT="601f29b8542136cf6dea4c33e72681c9bbdef966"
TRANSFORM_PATH="tools/helix-apply-synthetic-oracle-diagnostics.py"
OUT_BRANCH="helix-synthetic-network-oracle-diag"

fail(){ echo "FAIL: $*" >&2; exit 2; }
for c in git python3 cmake sha256sum awk grep realpath cp; do
  command -v "$c" >/dev/null 2>&1 || fail "missing command $c"
done

root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[[ -n "$root" ]] || fail "run inside WiVRn checkout"
cd "$root"

git cat-file -e "${BASE}^{commit}" 2>/dev/null || git fetch origin "$BASE"
git cat-file -e "${TRANSFORM_COMMIT}^{commit}" 2>/dev/null || git fetch origin "$TRANSFORM_COMMIT"
[[ "$(git rev-parse "$BASE")" == "$BASE" ]] || fail "base commit unavailable"

remote_expected="$(git ls-remote origin "refs/heads/$OUT_BRANCH" | awk '{print $1}')"
[[ -n "$remote_expected" ]] || fail "remote diagnostic branch missing"

stamp="$(date +%Y%m%d-%H%M%S)"
out="$HOME/helix-synthetic-oracle-diag-build-$stamp"
worktree="$out/worktree"
mkdir -p "$out"
git worktree add --detach "$worktree" "$BASE" >/dev/null
trap 'git -C "$root" worktree remove --force "$worktree" >/dev/null 2>&1 || true' EXIT INT TERM

transform="$out/oracle-transform.py"
git show "$TRANSFORM_COMMIT:$TRANSFORM_PATH" > "$transform"
python3 -m py_compile "$transform"

cd "$worktree"
[[ -z "$(git status --porcelain)" ]] || fail "isolated worktree dirty before transform"
python3 "$transform" | tee "$out/transform.txt"

git diff --check -- server/helix_synthetic_transport.cpp
mapfile -t changed < <(git diff --name-only)
[[ ${#changed[@]} -eq 1 && "${changed[0]}" == "server/helix_synthetic_transport.cpp" ]] || {
  printf 'unexpected changed files:\n%s\n' "${changed[*]}" >&2
  exit 2
}
grep -Fq 'HELIX_SYNTHETIC_TRANSPORT_ORACLE_DETAIL' server/helix_synthetic_transport.cpp || fail "diagnostic marker missing"
grep -Fq 'return accepts_expected && rejects_mutations;' server/helix_synthetic_transport.cpp || fail "oracle pass semantics changed"
git diff -- server/helix_synthetic_transport.cpp > "$out/source.diff"

git add server/helix_synthetic_transport.cpp
git commit -m 'Helix: instrument synthetic transport oracle predicates' | tee "$out/commit.txt"
source_commit="$(git rev-parse HEAD)"

cmake --preset server 2>&1 | tee "$out/configure.txt"
cmake --build build-server --target wivrn-server -j 2 2>&1 | tee "$out/build.txt"
built_server="$(realpath build-server/server/wivrn-server)"
[[ -x "$built_server" && -s "$built_server" ]] || fail "diagnostic server missing"
server="$out/wivrn-server"
cp "$built_server" "$server"
chmod +x "$server"
[[ -x "$server" && -s "$server" ]] || fail "persistent diagnostic server copy missing"
server_sha="$(sha256sum "$server" | awk '{print $1}')"
[[ "$(sha256sum "$built_server" | awk '{print $1}')" == "$server_sha" ]] || fail "persistent diagnostic server hash mismatch"

git push --force-with-lease="refs/heads/$OUT_BRANCH:$remote_expected" origin "HEAD:$OUT_BRANCH" 2>&1 | tee "$out/push.txt"
remote_head="$(git ls-remote origin "refs/heads/$OUT_BRANCH" | awk '{print $1}')"
[[ "$remote_head" == "$source_commit" ]] || fail "remote diagnostic branch mismatch"

cat > "$out/metadata.txt" <<EOF
base=$BASE
transform_commit=$TRANSFORM_COMMIT
source_commit=$source_commit
remote_expected=$remote_expected
remote_head=$remote_head
server=$server
server_sha256=$server_sha
apk_reuse_source=$BASE
purpose=DIAGNOSTIC_ONLY_oracle_predicate_observability
artifact_gate=PASS diagnostic-server-exact-source-one-file
EOF

printf '\nDIAGNOSTIC_SERVER_BUILD=PASS\n'
printf 'source_commit=%s\nserver=%s\nserver_sha256=%s\nevidence=%s\n' "$source_commit" "$server" "$server_sha" "$out"
