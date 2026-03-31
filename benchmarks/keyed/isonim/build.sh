#!/usr/bin/env bash
# Build the js-framework-benchmark entry for IsoNim
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC="$SCRIPT_DIR/src/main.nim"
OUT="$SCRIPT_DIR/dist/main.js"

mkdir -p "$SCRIPT_DIR/dist"
nim js -d:danger -o:"$OUT" "$SRC"

echo "Built: $OUT ($(wc -c < "$OUT") bytes)"
