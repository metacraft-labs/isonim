#!/usr/bin/env bash
# Build the js-framework-benchmark entry for IsoNim
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/src/main.nim"
OUT="$SCRIPT_DIR/dist/main.js"
OUT_RAW="$SCRIPT_DIR/dist/main.raw.js"

mkdir -p "$SCRIPT_DIR/dist"

# Compile Nim → JS with all optimizations
nim js -d:danger -o:"$OUT_RAW" "$SRC"

# Minify with terser if available (significant size reduction for Nim JS output)
if command -v npx >/dev/null 2>&1 && npx terser --version >/dev/null 2>&1; then
  npx terser "$OUT_RAW" --compress --mangle -o "$OUT"
  echo "Built: $OUT"
  echo "  Raw:      $(wc -c < "$OUT_RAW") bytes"
  RAW_SIZE=$(wc -c < "$OUT_RAW")
  MIN_SIZE=$(wc -c < "$OUT")
  PCT=$((MIN_SIZE * 100 / RAW_SIZE))
  echo "  Minified: $MIN_SIZE bytes (${PCT}% of raw)"
  echo "  Gzipped:  $(gzip -c "$OUT" | wc -c) bytes"
else
  # No terser — use raw output
  cp "$OUT_RAW" "$OUT"
  echo "Built: $OUT ($(wc -c < "$OUT") bytes, not minified — install terser for smaller bundles)"
fi
