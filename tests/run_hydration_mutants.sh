#!/usr/bin/env bash
#
# The falsifying mutation of test_ssr_hydration_e2e.nim's
# hydrate_releases_unclaimed_nodes: `hydrate` built from a copy of src/ that
# keeps its registry once hydration is done. The test, built against that
# copy, must FAIL at that test. Exits 0 when the mutant is caught.
#
# Run from the checkout (inside the dev shell, as `just test-js` runs the
# hydration tests).

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/isonim-hydration-mutants.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

cp -r "${ROOT}/src" "${WORK}/src"
mkdir "${WORK}/tests"
cp "${ROOT}/tests/test_ssr_hydration_e2e.nim" "${WORK}/tests/"
# The checkout's test configuration (its sibling paths made absolute), with
# the mutated copy of src/ in place of the checkout's.
sed -e "s|\$projectDir/\.\./src\"|${WORK}/src\"|" -e "s|\$projectDir|${ROOT}/tests|g" \
  "${ROOT}/tests/config.nims" > "${WORK}/tests/config.nims"

python3 - "${WORK}/src/isonim/web/hydration.nim" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
old = "  sharedConfig.registry = nil\n"
marker = "  sharedConfig.done = true\n"
i = text.index(marker)
j = text.index(old, i)
open(path, "w").write(text[:j] + text[j + len(old):])
PY

if (cd "${WORK}" && nim js -r --hints:off --nimcache:"${WORK}/nimcache" \
      tests/test_ssr_hydration_e2e.nim) >"${WORK}/run.log" 2>&1; then
  echo "MISSED: the registry kept after hydration passes test_ssr_hydration_e2e"
  exit 1
fi
if grep -q '\[FAILED\] hydrate_releases_unclaimed_nodes' "${WORK}/run.log"; then
  echo "KILLED: the registry kept after hydration fails hydrate_releases_unclaimed_nodes"
else
  tail -30 "${WORK}/run.log"
  echo "MISSED: the mutant failed, but not at hydrate_releases_unclaimed_nodes"
  exit 1
fi
