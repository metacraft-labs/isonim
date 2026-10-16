#!/usr/bin/env bash
# Use the complete Nix standard hook set and the exact guarded constructor.
# The portable committed configuration remains source; it is never installed
# in place of the full native checks by this entrypoint.
set -euo pipefail
if (($#)); then
  echo 'Usage: bash scripts/install-git-hooks.sh (inside the declared dev environment)' >&2
  exit 2
fi
repo_root="$(git rev-parse --show-toplevel)"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [[ $repo_root != "$script_root" ]]; then
  echo "Refusing hook installation outside this script's owning repository" >&2
  exit 1
fi
cd "$repo_root"
exec direnv exec "$repo_root" bash -c '
  test "${NIX_DIRENV_DID_FALLBACK:-0}" != 1 || exit 1
  if [[ -z ${ISONIM_HOOK_INSTALLER:-} || ! -x $ISONIM_HOOK_INSTALLER ]]; then
    echo "The owning shell did not supply its guarded hook installer" >&2
    exit 1
  fi
  exec "$ISONIM_HOOK_INSTALLER"
'
