#!/usr/bin/env bash
# Interleaved A/B run of the js-framework-benchmark suite: two IsoNim
# revisions and the SolidJS reference, on one host, in one session.
#
# Usage (inside the Nix dev shell, from the repository root):
#   just bench-ab <rev-a> <rev-b>
#   repro exec -- just bench-ab 5a35eb01f8 origin/agents
#
# Why a separate script: `run-comparison.sh` runs each framework once and
# compares against numbers taken at another time. A difference between two
# revisions of the same framework is usually smaller than the drift of a
# shared host over a few minutes, so this script
#   1. builds the benchmark app (`just bench-build`) in a detached git worktree
#      per revision, and installs the two bundles side by side in the runner as
#      keyed/isonim-a and keyed/isonim-b (keyed/solid is the reference);
#   2. runs BENCH_AB_ROUNDS rounds; in each round every benchmark is run for
#      the three frameworks back to back, one runner invocation each. The
#      order is rotated per round and per benchmark, and reversed on even
#      rounds, so every one of the six orders occurs and A runs before B as
#      often as B before A (given an even number of rounds);
#   3. records the host load at the start of every round (load.log);
#   4. pools the samples of all rounds and lets bench_ab_report.py compute the
#      median and spread per benchmark and build, the A->B delta, and a
#      mechanical verdict (see that file for the rule).
#
# Environment:
#   BENCH_AB_ROUNDS     rounds (default 6)
#   BENCH_AB_COUNT      runner --count per invocation (default 5; the runner
#                       adds 10 runs to select row)
#   BENCH_AB_BENCHMARKS benchmark selectors, matched by the runner as
#                       substrings of the benchmark ids (default: the nine
#                       CPU benchmarks, the three memory benchmarks the
#                       pinned runner enables, 40_ = sizes and first paint)
#   BENCH_AB_PATCH_B    a patch applied to the B worktree after checkout, to
#                       measure an uncommitted change (nothing is committed)
#   BENCH_AB_OUT        results directory (default
#                       benchmarks/results/ab-<UTC timestamp>)
#   BENCH_AB_WORKDIR    where the worktrees go (default $BENCH_AB_OUT/worktrees)
#   BENCH_RUNNER_REV    runner tag, see run-comparison.sh
#
# The exit status is the report's: 1 when B is flagged slower than A on any
# benchmark, 0 otherwise.

set -euo pipefail

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <rev-a> <rev-b>" >&2
  exit 2
fi
REV_A_ARG="$1"
REV_B_ARG="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNNER_DIR="$SCRIPT_DIR/runner"
ROUNDS="${BENCH_AB_ROUNDS:-6}"
COUNT="${BENCH_AB_COUNT:-5}"
BENCHMARKS_STR="${BENCH_AB_BENCHMARKS:-01_ 02_ 03_ 04_ 05_ 06_ 07_ 08_ 09_ 21_ 22_ 25_ 40_}"
read -r -a BENCHMARKS <<<"$BENCHMARKS_STR"
OUT_DIR="${BENCH_AB_OUT:-$SCRIPT_DIR/results/ab-$(date -u +%Y%m%dT%H%M%SZ)}"
WORK_DIR="${BENCH_AB_WORKDIR:-$OUT_DIR/worktrees}"
PATCH_B="${BENCH_AB_PATCH_B:-}"

CHROME_BIN="${CHROME_BIN:-$(command -v chromium 2>/dev/null || true)}"
if [ -z "$CHROME_BIN" ]; then
  echo "ERROR: chromium not found. Run inside the Nix dev shell (repro exec -- just bench-ab ...)" >&2
  exit 1
fi
export CHROME_BIN PUPPETEER_EXECUTABLE_PATH="$CHROME_BIN"
export PUPPETEER_SKIP_DOWNLOAD=1 PUPPETEER_SKIP_CHROMIUM_DOWNLOAD=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

REV_A="$(git -C "$REPO_DIR" rev-parse --verify "$REV_A_ARG^{commit}")"
REV_B="$(git -C "$REPO_DIR" rev-parse --verify "$REV_B_ARG^{commit}")"
if [ -n "$PATCH_B" ]; then
  PATCH_B="$(cd "$(dirname "$PATCH_B")" && pwd)/$(basename "$PATCH_B")"
fi

mkdir -p "$OUT_DIR" "$WORK_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
WORK_DIR="$(cd "$WORK_DIR" && pwd)"
LOAD_LOG="$OUT_DIR/load.log"

log_load() {
  {
    echo "== $1 $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    uptime
    ps -eo pcpu,comm --sort=-pcpu | head -6
  } >>"$LOAD_LOG"
}

# ---------------------------------------------------------------------------
# Runner, SolidJS reference and the root node_modules (terser)
# ---------------------------------------------------------------------------
BENCH_SETUP_ONLY=1 bash "$SCRIPT_DIR/run-comparison.sh"
(cd "$REPO_DIR" && just node-deps)
export PATH="$REPO_DIR/node_modules/.bin:$PATH"

# ---------------------------------------------------------------------------
# One worktree and one bundle per side
# ---------------------------------------------------------------------------
# `just bench-build` compiles against ../nim-everywhere/src relative to the
# repository root, so the worktrees' parent gets a link to the sibling the
# main checkout uses.
if [ ! -e "$WORK_DIR/nim-everywhere" ]; then
  ln -s "$(cd "$REPO_DIR/../nim-everywhere" && pwd)" "$WORK_DIR/nim-everywhere"
fi

WORKTREES=()
cleanup_worktrees() {
  for wt in "${WORKTREES[@]}"; do
    rm -f "$wt/node_modules"
    git -C "$REPO_DIR" worktree remove --force "$wt" 2>/dev/null || true
  done
  rm -f "$WORK_DIR/nim-everywhere"
}

SERVER_PID=""
cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  cleanup_worktrees
}
trap cleanup EXIT
# An interrupted run still removes its worktrees and stops the server.
trap 'exit 130' INT
trap 'exit 143' TERM

build_side() {
  local side="$1" rev="$2" patch="$3"
  local wt="$WORK_DIR/isonim-$side"
  local dest="$RUNNER_DIR/frameworks/keyed/isonim-$side"
  git -C "$REPO_DIR" worktree add --detach "$wt" "$rev" >/dev/null
  WORKTREES+=("$wt")
  if [ -n "$patch" ]; then
    git -C "$wt" apply "$patch"
  fi
  # terser from the main checkout's yarn.lock install; without this `npx`
  # finds no local node_modules in the fresh worktree and downloads whatever
  # terser version is current.
  ln -s "$REPO_DIR/node_modules" "$wt/node_modules"
  echo "=== Building isonim-$side at $rev${patch:+ plus $patch} ==="
  (cd "$wt" && just bench-build)
  rm -rf "$dest"
  mkdir -p "$dest/dist" "$dest/node_modules"
  cp "$wt/benchmarks/keyed/isonim/index.html" "$wt/benchmarks/keyed/isonim/package.json" \
    "$wt/benchmarks/keyed/isonim/package-lock.json" "$dest/"
  cp "$wt/benchmarks/keyed/isonim/dist/main.js" "$dest/dist/"
  # The runner shows the package name; make the two sides distinguishable.
  sed -i "s/\"js-framework-benchmark-keyed-isonim\"/\"js-framework-benchmark-keyed-isonim-$side\"/" \
    "$dest/package.json"
  cp "$wt/benchmarks/keyed/isonim/dist/main.js" "$OUT_DIR/main-$side.js"
}

log_load "before-build"
build_side a "$REV_A" ""
build_side b "$REV_B" "$PATCH_B"
cleanup_worktrees
WORKTREES=()

{
  echo "rev_a=$REV_A"
  echo "rev_a_arg=$REV_A_ARG"
  echo "rev_b=$REV_B"
  echo "rev_b_arg=$REV_B_ARG"
  echo "patch_b=$PATCH_B"
  echo "nim_everywhere=$(git -C "$REPO_DIR/../nim-everywhere" rev-parse HEAD)"
  echo "runner=$(git -C "$RUNNER_DIR" rev-parse HEAD)"
  echo "chrome=$("$CHROME_BIN" --version)"
  echo "host=$(hostname)"
  echo "nproc=$(nproc)"
  echo "rounds=$ROUNDS"
  echo "count=$COUNT"
  echo "benchmarks=${BENCHMARKS[*]}"
  echo "same_bundle=$(cmp -s "$OUT_DIR/main-a.js" "$OUT_DIR/main-b.js" && echo yes || echo no)"
} >"$OUT_DIR/meta.txt"
cat "$OUT_DIR/meta.txt"

# ---------------------------------------------------------------------------
# HTTP server of the runner (port 8080, fixed by the runner)
# ---------------------------------------------------------------------------
if curl -sf http://localhost:8080/ >/dev/null 2>&1; then
  echo "ERROR: something already listens on localhost:8080; the runner needs that port" >&2
  exit 1
fi
(cd "$RUNNER_DIR" && exec npm start) >"$OUT_DIR/server.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 30); do
  curl -sf http://localhost:8080/ >/dev/null 2>&1 && break
  sleep 1
done
curl -sf http://localhost:8080/ >/dev/null || { echo "ERROR: runner server did not start" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Interleaved rounds
# ---------------------------------------------------------------------------
FRAMEWORKS=(isonim-a isonim-b solid)
RESULTS_SRC="$RUNNER_DIR/webdriver-ts/results"
for round in $(seq 1 "$ROUNDS"); do
  log_load "round-$round"
  for j in "${!BENCHMARKS[@]}"; do
    bench="${BENCHMARKS[$j]}"
    for k in 0 1 2; do
      if [ $((round % 2)) -eq 1 ]; then
        fw="${FRAMEWORKS[$(((round + j + k) % 3))]}"
      else
        fw="${FRAMEWORKS[$(((round + j + 3 - k) % 3))]}"
      fi
      dest="$OUT_DIR/rounds/r$round/$fw"
      mkdir -p "$dest"
      # The size benchmark ignores --count (one run per invocation); invoke it
      # COUNT times so first paint gets as many samples as the others.
      reps=1
      [ "$bench" = "40_" ] && reps="$COUNT"
      for rep in $(seq 1 "$reps"); do
        rm -rf "$RESULTS_SRC"
        echo "--- round $round/$ROUNDS benchmark $bench $fw ($rep/$reps)"
        (cd "$RUNNER_DIR" && npm run bench -- --framework "keyed/$fw" --benchmark "$bench" \
          --headless --chromeBinary "$CHROME_BIN" --count "$COUNT") \
          >>"$OUT_DIR/runner.log" 2>&1 || {
          echo "ERROR: runner failed for $fw $bench (see $OUT_DIR/runner.log)" >&2
          exit 1
        }
        # A run that wrote no result file is a failure, not an empty sample.
        copied=0
        for f in "$RESULTS_SRC"/*.json; do
          [ -e "$f" ] || continue
          cp "$f" "$dest/$(basename "$f" .json).rep$rep.json"
          copied=$((copied + 1))
        done
        if [ "$copied" -eq 0 ]; then
          echo "ERROR: runner wrote no results for $fw $bench (see $OUT_DIR/runner.log)" >&2
          exit 1
        fi
      done
    done
  done
done
log_load "after"

python3 "$SCRIPT_DIR/bench_ab_report.py" "$OUT_DIR"
