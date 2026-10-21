#!/usr/bin/env bash
# Real compiler/DOM boundaries; no substituted compiler, context or renderer.
set -euo pipefail
if [[ $# -gt 1 || ($# -eq 1 && "$1" != --manifest-only) ]]; then
  echo 'usage: check_experiments.sh [--manifest-only]' >&2; exit 2
fi
cd "$(dirname "$0")/.."
out="$PWD/build/experiments"
rm -rf "$out"
mkdir -p "$out/c" "$out/js"
common=(--hints:off -d:release --stackTrace:off --lineTrace:off --path:src --path:../nim-everywhere/src)
nim --version | head -1
nim c -r "${common[@]}" --out:"$out/runtime" tests/test_experiment_registration.nim
nim js "${common[@]}" --out:"$out/runtime.js" tests/test_experiment_registration.nim
node "$out/runtime.js"
for backend in c js; do
  if nim "$backend" "${common[@]}" --out:"$out/duplicate" tests/fixtures/experiments/duplicate.nim > "$out/duplicate.log" 2>&1; then
    echo 'duplicate experiment key incorrectly compiled' >&2; exit 1
  fi
  grep -q 'duplicate experiment key' "$out/duplicate.log"
  for invalid in badWeightCount badWeightNegative badWeightTotal badDate badDateOrder badEnumStart badEnumHole; do
    if nim "$backend" "${common[@]}" "-d:$invalid" --out:"$out/invalid" tests/fixtures/experiments/invalid.nim > "$out/invalid.log" 2>&1; then
      echo "invalid experiment metadata compiled: $invalid" >&2; exit 1
    fi
    grep -Eq 'experiment (weights|window|enums)' "$out/invalid.log"
  done
done
fixture=tests/fixtures/experiments/app.nim
metadata=(-d:isonimStableIds "-d:iidProjectRoot=$PWD" "-d:experimentProjectRoot=$PWD" -d:experimentRoute=/)
nim c "${common[@]}" "${metadata[@]}" -d:isServer "-d:iidManifestDir=$out/c" "-d:experimentManifestDir=$out/c" --out:"$out/app" "$fixture"
nim js "${common[@]}" "${metadata[@]}" "-d:iidManifestDir=$out/js" "-d:experimentManifestDir=$out/js" --out:"$out/app.js" "$fixture"
"$out/app" > "$out/markup.html"
for backend in c js; do
  mkdir -p "$out/other-$backend"
  nim "$backend" "${common[@]}" "-d:experimentProjectRoot=$PWD" -d:experimentRoute=/other "-d:experimentManifestDir=$out/other-$backend" --out:"$out/other-$backend/app" tests/fixtures/experiments/other.nim
  cp "$out/other-$backend/experiments.json" "$out/$backend/experiments-other.json"
done
"$out/other-c/app"
for backend in c js; do
  node tools/isonim_manifest.mjs "$out/$backend" "$out/app.js" "$out/$backend.json" "$(git rev-parse HEAD)-dirty"
done
diff -u "$out/c.json" "$out/js.json"
for backend in c js; do
  mkdir -p "$out/safe-$backend"
  nim "$backend" "${common[@]}" "-d:experimentProjectRoot=$PWD" -d:experimentRoute=__proto__ "-d:experimentManifestDir=$out/safe-$backend" --out:"$out/safe-$backend/app.js" tests/fixtures/experiments/safe_keys.nim
  for fragment in "$out/$backend"/*.json; do
    case "$(basename "$fragment")" in experiments*) ;; *) cp "$fragment" "$out/safe-$backend/" ;; esac
  done
  node tools/isonim_manifest.mjs "$out/safe-$backend" "$out/app.js" "$out/safe-$backend.json" safe-key-test
done
"$out/safe-c/app.js"
node "$out/safe-js/app.js"
diff -u "$out/safe-c.json" "$out/safe-js.json"
node tests/test_experiment_manifest.mjs
if [[ "${1:-}" != --manifest-only ]]; then
  nim js "${common[@]}" -d:experimentPlainHydrate --out:"$out/plain.js" "$fixture"
  node tests/test_experiments_browser.mjs
  node tests/test_experiment_relocation.mjs
fi
