#!/usr/bin/env bash
# Run js-framework-benchmark comparison: IsoNim vs SolidJS
#
# Prerequisites: Nix dev shell with chromium and chromedriver.
# Usage:        just bench-compare
# First run:    clones the benchmark runner (~2 min), then runs benchmarks.
# Subsequent:   reuses the cloned runner, only re-copies isonim entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER_DIR="$SCRIPT_DIR/runner"
ISONIM_ENTRY="$SCRIPT_DIR/keyed/isonim"
ISONIM_HMR_ENTRY="$SCRIPT_DIR/keyed/isonim-hmr"
RESULTS_DIR="$SCRIPT_DIR/results"

# Default: include both isonim variants (vanilla + HMR-enabled) so we
# can quantify the cost of the HMR runtime alongside the SolidJS
# comparison. Set BENCH_FRAMEWORKS to override.
FRAMEWORKS_STR="${BENCH_FRAMEWORKS:-keyed/isonim keyed/isonim-hmr keyed/solid}"
read -r -a FRAMEWORKS <<<"$FRAMEWORKS_STR"
NUM_ITERATIONS="${BENCH_ITERATIONS:-5}"

# ---------------------------------------------------------------------------
# Ensure chromium is available (from Nix dev shell)
# ---------------------------------------------------------------------------
CHROME_BIN="${CHROME_BIN:-$(command -v chromium 2>/dev/null || command -v google-chrome-stable 2>/dev/null || true)}"
if [ -z "$CHROME_BIN" ]; then
  echo "ERROR: chromium not found. Run inside the Nix dev shell (direnv exec . just bench-compare)" >&2
  exit 1
fi
export CHROME_BIN
echo "Using Chrome: $CHROME_BIN"

# Prevent Puppeteer/Playwright from downloading their own browser binaries
export PUPPETEER_SKIP_DOWNLOAD=1
export PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1
export PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
export PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"

# ---------------------------------------------------------------------------
# Step 1: Clone the benchmark runner (one-time)
# ---------------------------------------------------------------------------
if [ ! -d "$RUNNER_DIR" ]; then
  echo "=== Cloning js-framework-benchmark ==="
  git clone --depth 1 https://github.com/krausest/js-framework-benchmark.git "$RUNNER_DIR"
fi

# ---------------------------------------------------------------------------
# Step 2: Install runner dependencies (one-time or after updates)
# ---------------------------------------------------------------------------
if [ ! -d "$RUNNER_DIR/node_modules" ]; then
  echo "=== Installing runner dependencies ==="
  cd "$RUNNER_DIR"
  npm ci
  npm run install-local
  cd "$SCRIPT_DIR"
fi

# Early exit for setup-only mode
if [ "${BENCH_SETUP_ONLY:-}" = "1" ]; then
  echo "Setup complete. Runner installed at: $RUNNER_DIR"
  exit 0
fi

# ---------------------------------------------------------------------------
# Step 3: Build SolidJS entry (one-time)
# ---------------------------------------------------------------------------
SOLID_DIR="$RUNNER_DIR/frameworks/keyed/solid"
if [ ! -d "$SOLID_DIR/dist" ]; then
  echo "=== Building SolidJS benchmark entry ==="
  cd "$SOLID_DIR"
  npm ci
  npm run build-prod
  cd "$SCRIPT_DIR"
fi

# ---------------------------------------------------------------------------
# Step 4: Copy/refresh isonim entries into the runner
# ---------------------------------------------------------------------------
copy_isonim_entry() {
  local src="$1"
  local name="$2"
  local dest="$RUNNER_DIR/frameworks/keyed/$name"
  echo "=== Copying $name benchmark entry ==="
  mkdir -p "$dest/dist"
  cp "$src/index.html" "$dest/"
  cp "$src/package.json" "$dest/"
  cp "$src/package-lock.json" "$dest/"
  cp "$src/dist/main.js" "$dest/dist/"
  mkdir -p "$dest/node_modules"
}

copy_isonim_entry "$ISONIM_ENTRY" "isonim"
if [ -d "$ISONIM_HMR_ENTRY" ] && [ -f "$ISONIM_HMR_ENTRY/dist/main.js" ]; then
  copy_isonim_entry "$ISONIM_HMR_ENTRY" "isonim-hmr"
fi

# ---------------------------------------------------------------------------
# Step 5: Build the benchmark driver (webdriver-ts)
# ---------------------------------------------------------------------------
echo "=== Compiling benchmark driver ==="
cd "$RUNNER_DIR/webdriver-ts"
# Recompile only if dist is missing or source is newer
if [ ! -d "dist" ]; then
  npm run compile
fi
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Step 6: Start the HTTP server
# ---------------------------------------------------------------------------
echo "=== Starting benchmark HTTP server ==="
cd "$RUNNER_DIR"
npm start &
SERVER_PID=$!

# Give the server a moment to start
sleep 2

# Ensure cleanup on exit
cleanup() {
  echo ""
  echo "=== Stopping HTTP server (PID $SERVER_PID) ==="
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
}
trap cleanup EXIT

# Quick check that the server is responding
if ! curl -sf http://localhost:8080/ >/dev/null 2>&1; then
  echo "WARNING: Server may not be ready yet, waiting a bit longer..."
  sleep 3
fi

# ---------------------------------------------------------------------------
# Step 7: Run the benchmarks
# ---------------------------------------------------------------------------
FRAMEWORK_ARGS=()
for fw in "${FRAMEWORKS[@]}"; do
  FRAMEWORK_ARGS+=("--framework" "$fw")
done

echo "=== Running benchmarks (${NUM_ITERATIONS} iterations) ==="
echo "    Frameworks: ${FRAMEWORKS[*]}"
echo "    Chrome: $CHROME_BIN"
echo ""

cd "$RUNNER_DIR"
npm run bench -- \
  "${FRAMEWORK_ARGS[@]}" \
  --headless \
  --chromeBinary "$CHROME_BIN" \
  --numIterationsForCPUBenchmarks "$NUM_ITERATIONS" \
  --numIterationsForMemBenchmarks 1 \
  --numIterationsForStartupBenchmark 1

# ---------------------------------------------------------------------------
# Step 8: Generate results
# ---------------------------------------------------------------------------
echo ""
echo "=== Generating results ==="
npm run results 2>/dev/null || true

# ---------------------------------------------------------------------------
# Step 9: Copy results back
# ---------------------------------------------------------------------------
mkdir -p "$RESULTS_DIR"
if [ -d "$RUNNER_DIR/webdriver-ts/results" ]; then
  cp -r "$RUNNER_DIR/webdriver-ts/results/"* "$RESULTS_DIR/" 2>/dev/null || true
fi

echo ""
echo "========================================="
echo " Benchmark comparison complete!"
echo "========================================="
echo ""
echo "Results saved to: $RESULTS_DIR/"
echo ""
echo "To view the interactive results table:"
echo "  cd $RUNNER_DIR && npm start"
echo "  open http://localhost:8080/webdriver-ts-results/dist/index.html"
echo ""

# Print a quick summary from the JSON results if jq is available
if command -v jq >/dev/null 2>&1; then
  echo "=== Quick Summary ==="
  for f in "$RESULTS_DIR"/*.json; do
    [ -f "$f" ] || continue
    basename "$f" .json
    jq -r '"\(.framework): mean=\(.values | to_entries[0].value.mean | . * 10 | round / 10)ms median=\(.values | to_entries[0].value.median | . * 10 | round / 10)ms"' "$f" 2>/dev/null || true
  done
fi
