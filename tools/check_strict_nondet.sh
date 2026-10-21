#!/usr/bin/env bash
# Real compiler negative controls: failure must name the selected raw binding.
set -euo pipefail
cd "$(dirname "$0")/.."
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for target in c js; do
  for selection in scheduleAtRaw sleepForRaw fetchHttpRaw; do
    flags=()
    case "$selection" in
      sleepForRaw) flags=(-d:rawSleep);;
      fetchHttpRaw) flags=(-d:rawFetch);;
    esac
    nim "$target" --hints:off "${flags[@]}" --out:"$work/raw-$target" tests/strict_nondet_fixture.nim
    if nim "$target" --hints:off "${flags[@]}" -d:isonimStrictNondet --out:"$work/strict-$target" tests/strict_nondet_fixture.nim >"$work/error" 2>&1; then
      echo "strict mode accepted raw $selection" >&2; exit 1
    fi
    if ! grep -F "isonimStrictNondet: raw platform binding $selection" "$work/error"; then
      cat "$work/error" >&2; exit 1
    fi
  done
  nim "$target" --hints:off --out:"$work/seam-normal-$target" tests/strict_nondet_seam_fixture.nim
  nim "$target" --hints:off -d:isonimStrictNondet --out:"$work/seam-$target" tests/strict_nondet_seam_fixture.nim
done
