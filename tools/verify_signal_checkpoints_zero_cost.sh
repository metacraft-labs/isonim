#!/usr/bin/env bash
# Compare exact compiler output; never normalize generated names or paths.
set -euo pipefail
cd "$(dirname "$0")/.."
parent=${1:?usage: verify_signal_checkpoints_zero_cost.sh PARENT_COMMIT}
parent=$(git rev-parse "$parent^{commit}")
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/isonim/build" "$scratch/nim-everywhere"
git archive "$parent" | tar -x -C "$scratch/isonim"
git -C ../nim-everywhere diff --exit-code HEAD -- src
git -C ../nim-everywhere archive HEAD | tar -x -C "$scratch/nim-everywhere"
# Same generated public style input and byte-identical fixture for both builds.
cp build/tailwind-styles.json "$scratch/isonim/build/tailwind-styles.json"
fixture=tests/fixtures/listen/task_app.nim
cmp "$fixture" "$scratch/isonim/$fixture"
opts=(--hints:off -d:release --stackTrace:off --lineTrace:off --path:src --path:../nim-everywhere/src)
(cd "$scratch/isonim"; nim js "${opts[@]}" --out:"$scratch/parent.js" "$fixture")
nim js "${opts[@]}" --out:"$scratch/candidate.js" "$fixture"
nim js "${opts[@]}" -d:isonimRecordable --out:"$scratch/recordable.js" "$fixture"
cmp "$scratch/parent.js" "$scratch/candidate.js"
if cmp -s "$scratch/candidate.js" "$scratch/recordable.js"; then
  echo 'flag-on positive control did not change the task app bundle' >&2; exit 1
fi
printf 'parent=%s candidate_base=%s nim_everywhere=%s\n' "$parent" "$(git rev-parse HEAD)" "$(git -C ../nim-everywhere rev-parse HEAD)"
nim --version | head -1
sha256sum "$scratch/parent.js" "$scratch/candidate.js" "$scratch/recordable.js" build/tailwind-styles.json "$fixture"
printf 'literal parent/candidate byte identity PASS; flag-on positive control PASS\n'
