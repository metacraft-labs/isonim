#!/usr/bin/env bash
# Run the actual prose suite against a copied parser whose inline code branch
# has the original one-backtick opening/closing logic. No live source edits,
# mocks or assertions tailored to the mutant. Compilation must succeed and the
# named double-backtick assertion must fail on both backends.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
scratch=$(mktemp -d "$PWD/build/prose-mutation.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/src/isonim/content" "$scratch/src/isonim/ssr"
cp src/isonim/content/{markdown,anchors,prose,fragments}.nim "$scratch/src/isonim/content/"
cp src/isonim/ssr/escape.nim "$scratch/src/isonim/ssr/"
cp tests/test_content_prose.nim "$scratch/test_content_prose.nim"
node - "$scratch/src/isonim/content/markdown.nim" <<'JS'
const fs = require('fs');
const file = process.argv[2];
const source = fs.readFileSync(file, 'utf8');
const start = source.indexOf('proc parseInlineSpans*');
const old = 'let width = tickRun(text, i)\n      let close = codeSpanEnd(text, i, width)';
const pos = source.indexOf(old, start);
if (pos < 0) throw new Error('Code-span mutation site no longer matches');
fs.writeFileSync(file, source.slice(0, pos) +
  "let width = 1\n      let close = text.find('`', i + 1)" +
  source.slice(pos + old.length));
JS
for backend in c js; do
  output="$scratch/test-$backend"
  flags=()
  if [ "$backend" = js ]; then output="$output.js"; fi
  if [ "$backend" = js ]; then flags=(-d:nodejs); fi
  nim "$backend" "${flags[@]}" --path:"$scratch/src" --out:"$output" \
    --nimcache:"$scratch/nimcache-$backend" "$scratch/test_content_prose.nim" \
    >"$scratch/compile-$backend.log" 2>&1 || { cat "$scratch/compile-$backend.log"; exit 1; }
  set +e
  if [ "$backend" = js ]; then node "$output" >"$scratch/run-$backend.log" 2>&1
  else "$output" >"$scratch/run-$backend.log" 2>&1; fi
  status=$?
  set -e
  if [ "$status" -eq 0 ]; then
    echo "FAIL: $backend accepted the old code-span closing logic" >&2
    exit 1
  fi
  if ! grep -F '[FAILED] double-backtick spans retain embedded ticks and trim one surrounding space' "$scratch/run-$backend.log"; then
    cat "$scratch/run-$backend.log"
    echo "FAIL: $backend failed for a reason other than the required double-backtick test" >&2
    exit 1
  fi
  echo "PASS: $backend compiled the old closing logic and rejected it (exit $status)"
done
