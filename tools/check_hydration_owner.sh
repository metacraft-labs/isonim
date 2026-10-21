#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
common=(--hints:off --path:src --path:../nim-everywhere/src)
nim c "${common[@]}" --out:build/hydration_owner_ssr tests/fixtures/hydration_owner.nim
nim js "${common[@]}" --out:build/hydration_owner.js tests/fixtures/hydration_owner.nim
export PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}"
node tests/test_hydration_owner.mjs
python3 tools/test_hydration_owner_mutant.py
