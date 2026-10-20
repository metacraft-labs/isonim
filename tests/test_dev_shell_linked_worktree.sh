#!/usr/bin/env bash
# Exercise the evaluated shellHook and real pre-commit in isolated Git repos.
# A local, always-run check writes a receipt so successful shell entry alone
# cannot hide an installer that has stopped installing working hooks.
# The fixture commits a harmless local config instead of the product checks:
# this isolates installation/dispatch from unrelated checks and network setup.
# test_dev_shell_writes_nothing_elsewhere.sh separately verifies installation
# of the repository's unchanged committed config. No Git/Nix/pre-commit mocks.
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git init -q "$SCRATCH/main"
cp "$REPO/flake.nix" "$SCRATCH/main/flake.nix"
cat > "$SCRATCH/main/.pre-commit-config.yaml" <<'CONFIG'
repos:
  - repo: local
    hooks:
      - id: shell-hook-receipt
        name: shell hook receipt
        language: system
        entry: bash -c 'printf invoked > hook-ran'
        always_run: true
        pass_filenames: false
CONFIG
git -C "$SCRATCH/main" add flake.nix .pre-commit-config.yaml
git -C "$SCRATCH/main" -c core.hooksPath=/dev/null -c user.name=Test -c user.email=test@example.invalid commit -qm fixture
git -C "$SCRATCH/main" -c core.hooksPath=/dev/null worktree add -q --detach "$SCRATCH/linked"
common_hooks="$(git -C "$SCRATCH/main" rev-parse --path-format=absolute --git-common-dir)/hooks"
config_before="$(git -C "$SCRATCH/main" hash-object .pre-commit-config.yaml)"

enter_shell() {
  local dir=$1
  # Keep diagnostics visible: the regression is Git's 'Not a directory', not
  # a generic failed shell or a failed source-text ordering assertion.
  (cd "$dir" && nix develop "$REPO" --no-write-lock-file -c true) \
    || fail "the dev shell did not start from $dir"
}
assert_hook_runs() {
  local dir
  dir="$(git -C "$1" rev-parse --show-toplevel)"
  [ "$(git -C "$dir" hash-object .pre-commit-config.yaml)" = "$config_before" ] \
    && [ ! -L "$dir/.pre-commit-config.yaml" ] \
    || fail "the committed config changed"
  rm -f "$dir/hook-ran"
  git -C "$dir" -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m receipt \
    || fail "the installed hook failed"
  [ "$(cat "$dir/hook-ran")" = invoked ] || fail "the installed hook did not execute the committed config"
}

# Seed the shared legacy value before entering the linked worktree. Its .git
# is a file, so resolving .git/hooks before repair fails with Git exit 128.
git -C "$SCRATCH/main" config --local core.hooksPath .git/hooks
mkdir -p "$SCRATCH/linked/subdirectory"
for dir in "$SCRATCH/linked" "$SCRATCH/linked/subdirectory" "$SCRATCH/main"; do
  git -C "$SCRATCH/main" config --local core.hooksPath .git/hooks
  enter_shell "$dir"
  [ "$(git -C "$dir" config --local --get core.hooksPath)" = "$common_hooks" ] \
    || fail "legacy hooksPath was not repaired to the absolute common directory"
  assert_hook_runs "$dir"
  mkdir -p "$dir/subdirectory"
  enter_shell "$dir/subdirectory"
  assert_hook_runs "$dir"
done

# Existing explicit absolute paths and Git's unset default keep their semantics.
custom_hooks="$SCRATCH/custom-hooks"
git -C "$SCRATCH/main" config --local core.hooksPath "$custom_hooks"
enter_shell "$SCRATCH/linked"
[ "$(git -C "$SCRATCH/linked" config --local --get core.hooksPath)" = "$custom_hooks" ] \
  || fail "an explicit custom hooksPath changed"
assert_hook_runs "$SCRATCH/linked"
git -C "$SCRATCH/main" config --local --unset core.hooksPath
enter_shell "$SCRATCH/linked"
[ -z "$(git -C "$SCRATCH/linked" config --local --get core.hooksPath || true)" ] \
  || fail "an unset hooksPath changed"
assert_hook_runs "$SCRATCH/linked"
echo "PASS: linked-worktree shell entry repairs the legacy hooksPath and installs working hooks"
