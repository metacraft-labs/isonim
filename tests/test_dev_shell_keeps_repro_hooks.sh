#!/usr/bin/env bash
# Entering this repository's dev shell, from the main checkout or from any
# linked worktree, leaves Reprobuild's managed git hooks in their slots, and
# the repository's pre-commit checks still run.
#
# Every linked worktree shares the main checkout's hooks directory and its
# config. The dev shell installs the committed .pre-commit-config.yaml as git
# hooks (scripts/install-git-hooks.sh). Where a Reprobuild dispatcher holds a
# slot, the installer writes its hook as `<hook>.repro-local`, which the
# dispatcher runs before its managed hook; and flake.nix moves a dispatcher
# that `pre-commit install` displaced to `<hook>.legacy` back into its slot.
# That is the layout `repro hooks ensure --vcs` produces (reprobuild,
# libs/repro_cli_support: `vcsDispatcherContent`, `localHookPath`).
#
# The test runs on a scratch clone of this repository, carrying the working
# tree's tracked changes (new files must be `git add -N`ed), so the real
# checkout's hooks are never touched. Nothing is mocked: the dispatchers are
# the ones the `repro` on PATH installs, the shell is this flake's dev shell,
# and the checks are the configured pre-commit hooks.
#
# Asserted after entering the shell from a linked worktree and then from the
# main checkout:
#   - the pre-commit and pre-push slots still hold the dispatchers `ensure`
#     wrote, byte-identical, with their `.repro-managed` bodies, and no
#     `<hook>.legacy` is left;
#   - the linked worktree resolves the shared hooks directory;
#   - the installer's pre-commit hook is chained as `pre-commit.repro-local`.
# Positive controls, through the dispatchers:
#   - in the linked worktree and in the main checkout, committing a file over
#     the large-file limit is refused by check-added-large-files, and a small
#     file commits;
#   - a push runs the managed pre-push gate (`repro check`), which prints its
#     verdict. Outside a workspace that is "not a workspace" and the push goes
#     through; where the clone's committed repro.lock makes it a workspace, the
#     gate refuses the scratch remote as not the agreed one. Either way the
#     gate ran, and nothing is published.
#
# Needs `repro` and `nix` on PATH; without `repro` it fails, it does not skip.
#
#   bash tests/test_dev_shell_keeps_repro_hooks.sh
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
command -v repro >/dev/null || fail "repro is not on PATH (prerequisite, not a skip)"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
GIT=(git -c user.name=test -c user.email=test@example.invalid -c commit.gpgsign=false)

main="$SCRATCH/main"
git clone -q --no-hardlinks "$REPO" "$main"
git -C "$REPO" diff HEAD --binary | git -C "$main" apply --allow-empty
git -C "$main" add -A
# No hooks are installed in the fresh clone yet, so this commit runs none.
"${GIT[@]}" -C "$main" commit -q --allow-empty -m "test: working tree under test"
git init -q --bare "$SCRATCH/remote.git"
git -C "$main" remote add test "$SCRATCH/remote.git"

repro hooks ensure --vcs "$main" >/dev/null 2>&1 || fail "repro hooks ensure --vcs failed on the scratch clone"
hooks="$(git -C "$main" rev-parse --path-format=absolute --git-path hooks)"
for h in pre-commit pre-push; do
  grep -q 'reprobuild hook dispatcher' "$hooks/$h" || fail "setup: ensure wrote no $h dispatcher"
  [ -f "$hooks/$h.repro-managed" ] || fail "setup: ensure wrote no $h.repro-managed"
done
sum() { sha256sum "$1" | cut -d' ' -f1; }
declare -A before
for f in pre-commit pre-push pre-commit.repro-managed pre-push.repro-managed; do
  before[$f]="$(sum "$hooks/$f")"
done

wt="$SCRATCH/wt"
git -c advice.detachedHead=false -C "$main" worktree add -q --detach "$wt" HEAD
for dir in "$wt" "$main"; do
  (cd "$dir" && nix develop --no-write-lock-file -c true) >/dev/null 2>&1 \
    || fail "the dev shell did not start from $dir"
done

for f in pre-commit pre-push pre-commit.repro-managed pre-push.repro-managed; do
  [ -f "$hooks/$f" ] && [ "$(sum "$hooks/$f")" = "${before[$f]}" ] \
    || fail "$f is not the hook 'repro hooks ensure' wrote: $(head -3 "$hooks/$f" 2>/dev/null | tr '\n' ' ')"
done
legacy="$(cd "$hooks" && ls -- *.legacy 2>/dev/null || true)"
[ -z "$legacy" ] || fail "a displaced hook is left: $legacy"
[ "$(git -C "$wt" rev-parse --path-format=absolute --git-path hooks)" = "$hooks" ] \
  || fail "the linked worktree does not resolve the shared hooks directory (core.hooksPath=$(git -C "$main" config --get core.hooksPath))"
grep -q 'hook-impl' "$hooks/pre-commit.repro-local" 2>/dev/null \
  || fail "the installer's pre-commit shim is not chained as pre-commit.repro-local"

for dir in "$wt" "$main"; do
  head -c 2097152 /dev/urandom >"$dir/large.bin"
  git -C "$dir" add large.bin
  if out="$("${GIT[@]}" -C "$dir" commit -m "test: large file" 2>&1)"; then
    fail "control ($dir): a 2 MiB file was committed; the pre-commit checks did not run"
  fi
  grep -qi 'large' <<<"$out" || fail "control ($dir): the commit failed, but not on the large-file check: $out"
  git -C "$dir" rm -q --cached large.bin && rm -f "$dir/large.bin"
  echo small >"$dir/small-$(basename "$dir").txt"
  git -C "$dir" add "small-$(basename "$dir").txt"
  out="$("${GIT[@]}" -C "$dir" commit -m "test: small file" 2>&1)" \
    || fail "control ($dir): a small file did not commit: $out"
done

# The gate's own refusal is an accepted outcome (see the header); a push that
# printed no `repro check:` verdict never reached the gate.
if out="$(git -C "$wt" push test HEAD:refs/heads/test 2>&1)"; then
  grep -q 'not a workspace' <<<"$out" || fail "the push went through without the gate's verdict: $out"
else
  grep -q 'push target is not the manifest-agreed remote' <<<"$out" \
    || fail "the push was refused, but not by the pre-push gate's remote check: $out"
fi
grep -q '^repro check:' <<<"$out" || fail "the push did not run the managed pre-push gate: $out"

echo "PASS: the dev shell keeps the Reprobuild dispatchers in place; the pre-commit checks and the pre-push gate run"
