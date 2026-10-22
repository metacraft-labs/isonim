#!/usr/bin/env bash
# Real compilers, shared SSR fixture, HTTP and Chromium. No simulated DOM.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
common=(--hints:off --path:src --path:../nim-everywhere/src)
ids=(-d:isonimStableIds "-d:iidProjectRoot=$PWD")
fixture=tests/fixtures/listen/task_app.nim
nim c "${common[@]}" "${ids[@]}" -d:isServer --out:build/listen_ssr "$fixture"
nim js "${common[@]}" "${ids[@]}" --out:build/listen.js "$fixture"
nim c "${common[@]}" -d:isServer --out:build/listen_plain_ssr "$fixture"
nim js "${common[@]}" --out:build/listen_plain.js "$fixture"
export PLAYWRIGHT_CHROMIUM_EXECUTABLE="${PLAYWRIGHT_CHROMIUM_EXECUTABLE:-$(command -v chromium)}"
node tests/test_listen_browser.mjs
# The actual raw component registers a real callback with no observation.
# Verify its exact finding, independent of the main source allowlist.
python3 - <<'PY'
import sys
sys.path.insert(0,'tools')
from pathlib import Path
from lint_nondet import scan_file
path=Path('tests/fixtures/listen/raw_component.nim')
findings=scan_file(path,str(path))
assert len(findings)==1, findings
assert findings[0].api=='addEventListener', findings
assert findings[0].path.endswith('tests/fixtures/listen/raw_component.nim'), findings
print('actual raw component lint: PASS')
PY
for backend in c js; do
  for flag in '' -d:markerBypass; do
    if nim "$backend" "${common[@]}" $flag --out:build/invalid_record tests/fixtures/listen/invalid_record.nim > build/invalid_record.log 2>&1; then
      echo 'unsafe record directive compiled' >&2; exit 1
    fi
    grep -Eq 'recordDirective|typed record' build/invalid_record.log
  done
done
nim c -r --hints:off --out:build/test_record_directive tests/test_record_directive.nim
python3 tools/test_listen_mutants.py
