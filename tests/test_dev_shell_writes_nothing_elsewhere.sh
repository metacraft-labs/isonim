#!/usr/bin/env bash
# Entering this repository's dev shell from ANOTHER git repository writes
# nothing into that repository.
#
# The dev shell's hook installs git hooks (`.pre-commit-config.yaml`, hooks
# under `.git/hooks`, `core.hooksPath`). git-hooks.nix aims them at
# `git rev-parse --show-toplevel` of the CURRENT DIRECTORY, so without a guard
# `nix develop /path/to/this-repo` run from a sibling checkout plants this
# repository's hooks there: an untracked file that blocks that repository's
# pre-push gate, and foreign checks on its commits. flake.nix runs the hook only
# when the enclosing repository is this one.
#
# Asserted, from a scratch git repository and from a subdirectory of it: no
# file or directory appears, no hook is
# installed and `core.hooksPath` is untouched. As the positive control, entered
# from inside this repository the hook still installs the pre-commit hook
# (running the complete selected native config while leaving the tracked
# portable `.pre-commit-config.yaml` byte-identical).
#
#   bash tests/test_dev_shell_writes_nothing_elsewhere.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Resolve the same declared develop-set arguments as the owning environment.
# Full Nix shell activation remains the subject, including every shellHook effect.
: "${REPROBUILD_REPRO:?the owning shell must supply its managed constructor}"
flake_args_quoted="$(cd "$REPO" && "$REPROBUILD_REPRO" flake override-args --all)"
eval "flake_args=( ${flake_args_quoted} )"
expected_native="${ISONIM_EXPECTED_NATIVE_HOOKS:?the owning shell must supply its native factory}"
expected_config="${ISONIM_FULL_HOOK_CONFIG:?the owning shell must supply its full configuration}"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

git -C "$SCRATCH" init -q
git -C "$SCRATCH" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init
mkdir -p "$SCRATCH/sub"
hooks_before="$(ls "$SCRATCH/.git/hooks")"

for dir in "$SCRATCH" "$SCRATCH/sub"; do
  ( cd "$dir" && nix develop "$REPO" "${flake_args[@]}" --no-write-lock-file --option fallback false -c true ) >/dev/null 2>&1 \
    || fail "the dev shell did not start from $dir"
  [ -z "$(git -C "$SCRATCH" status --porcelain --ignored)" ] \
    || fail "entered from $dir: files were written into the other repository: $(git -C "$SCRATCH" status --porcelain --ignored | tr '\n' ' ')"
  # git status does not list empty directories.
  extra="$(cd "$SCRATCH" && find . -mindepth 1 -path ./.git -prune -o ! -path ./sub -print)"
  [ -z "$extra" ] || fail "entered from $dir: entries were created in the other repository: $(echo $extra)"
  [ "$(ls "$SCRATCH/.git/hooks")" = "$hooks_before" ] \
    || fail "entered from $dir: git hooks were installed into the other repository"
  [ -z "$(git -C "$SCRATCH" config --local --get core.hooksPath || true)" ] \
    || fail "entered from $dir: the other repository's core.hooksPath was changed"
done

# Positive control: the guard must not stop the hook in this repository.
config_before="$(git -C "$REPO" hash-object .pre-commit-config.yaml)"
hooks_dir="$(git -C "$REPO" rev-parse --path-format=absolute --git-path hooks)"
( cd "$REPO" && nix develop "$REPO" "${flake_args[@]}" --no-write-lock-file --option fallback false -c true ) >/dev/null 2>&1 \
  || fail "the dev shell did not start from this repository"
[ -f "$REPO/.pre-commit-config.yaml" ] && [ ! -L "$REPO/.pre-commit-config.yaml" ] \
  && [ "$(git -C "$REPO" hash-object .pre-commit-config.yaml)" = "$config_before" ] \
  || fail "control: the committed .pre-commit-config.yaml was replaced or changed"
[ -L "$REPO/.pre-commit-config.nix.yaml" ] \
  && [ "$(readlink "$REPO/.pre-commit-config.nix.yaml")" = "$expected_config" ] \
  || fail "control: the complete native configuration is not the selected immutable producer"
for hook in pre-commit pre-push; do
  if ! cmp -s "$expected_native/$hook" "$hooks_dir/$hook" \
    && ! cmp -s "$expected_native/$hook" "$hooks_dir/$hook.repro-local"; then
    fail "control: full shell activation did not install the exact selected native $hook body"
  fi
done

echo "PASS: entered from another repository the dev shell writes nothing there; from this one it installs its hooks"
