#!/usr/bin/env bash
# Collects IsoNim performance metrics for CI benchmark tracking.
# Output format: JSON array compatible with github-action-benchmark.
#
# The output contains two sections:
#   - Bundle sizes (customSmallerIsBetter): JS bundle sizes for benchmark, demo, etc.
#   - Test counts (customBiggerIsBetter): number of passing tests per backend
#
# Usage:
#   ./scripts/collect-metrics.sh              # All metrics (sizes + tests)
#   ./scripts/collect-metrics.sh --sizes      # Bundle sizes only
#   ./scripts/collect-metrics.sh --tests      # Test counts only

set -euo pipefail

MODE="${1:---all}"

# Format bytes to human-readable string.
format_bytes() {
  local bytes=$1
  local unit_divisor=1
  local unit_suffix="B"
  local tenths=0

  if ((bytes >= 1073741824)); then
    unit_divisor=1073741824
    unit_suffix="GB"
  elif ((bytes >= 1048576)); then
    unit_divisor=1048576
    unit_suffix="MB"
  elif ((bytes >= 1024)); then
    unit_divisor=1024
    unit_suffix="KB"
  else
    printf "%d B" "$bytes"
    return
  fi

  tenths=$(((bytes * 10 + (unit_divisor / 2)) / unit_divisor))
  printf "%d.%d %s" "$((tenths / 10))" "$((tenths % 10))" "$unit_suffix"
}

# Output a single metric in JSON format.
# Args: name, value, unit, extra, is_first
output_metric() {
  local name=$1
  local value=$2
  local unit=$3
  local extra=$4
  local is_first=$5

  if [[ "$is_first" != "true" ]]; then
    printf ",\n"
  fi

  printf '  {\n'
  printf '    "name": "%s",\n' "$name"
  printf '    "unit": "%s",\n' "$unit"
  printf '    "value": %s,\n' "$value"
  printf '    "extra": "%s"\n' "$extra"
  printf '  }'
}

# Get file size in bytes (cross-platform).
get_file_size() {
  local file=$1
  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi
  stat -c %s "$file" 2>/dev/null || stat -f %z "$file" 2>/dev/null || echo "0"
}

# Count test cases by running nim tests and counting "  [OK]" lines.
count_tests() {
  local backend=$1  # "c" or "js"
  local count=0
  local test_files

  if [[ "$backend" == "c" ]]; then
    test_files=(
      tests/test_signals.nim
      tests/test_effects.nim
      tests/test_clock.nim
      tests/test_context.nim
      tests/test_rxcore.nim
      tests/test_dsl.nim
      tests/test_ssr.nim
      tests/test_streaming.nim
      tests/test_dsl_ssr.nim
      tests/test_round_trip.nim
      tests/test_benchmark.nim
      tests/test_viewmodel.nim
      tests/test_demo_vm.nim
      tests/test_terminal.nim
      tests/test_native_renderer.nim
      tests/test_nginx_module.nim
      tests/test_corner_cases.nim
      tests/test_accessibility.nim
    )
  else
    test_files=(
      tests/test_signals.nim
      tests/test_effects.nim
      tests/test_clock.nim
      tests/test_context.nim
      tests/test_rxcore.nim
      tests/test_dsl.nim
      tests/test_web.nim
      tests/test_demo_vm.nim
      tests/test_benchmark.nim
      tests/test_viewmodel.nim
      tests/test_terminal.nim
      tests/test_hydration.nim
      tests/test_ssr_hydration_e2e.nim
      tests/test_app_e2e.nim
      tests/test_web_components_advanced.nim
      tests/test_accessibility.nim
    )
  fi

  for test_file in "${test_files[@]}"; do
    if [[ -f "$test_file" ]]; then
      local result
      result=$(nim "$backend" -r "$test_file" 2>&1 || true)
      local file_count
      file_count=$(echo "$result" | grep -c '\[OK\]' || true)
      count=$((count + file_count))
    fi
  done

  echo "$count"
}

collect_sizes() {
  local is_first="true"
  local bench_bundle="benchmarks/keyed/isonim/dist/main.js"
  local demo_bundle="demos/isonim-replica/dist/main.js"
  local wc_bundle="demos/web-components/dist/components.js"

  echo "["

  # Build bundles if they don't exist
  if [[ ! -f "$bench_bundle" ]]; then
    echo "Building benchmark bundle..." >&2
    mkdir -p "$(dirname "$bench_bundle")"
    nim js -d:danger -o:"$bench_bundle" benchmarks/keyed/isonim/src/main.nim 2>&2
  fi

  if [[ -f "$bench_bundle" ]]; then
    local size
    size=$(get_file_size "$bench_bundle")
    local human
    human=$(format_bytes "$size")
    output_metric "isonim-benchmark-bundle" "$size" "bytes" "$human (keyed, -d:danger)" "$is_first"
    is_first="false"
  else
    echo "Warning: Benchmark bundle not found: $bench_bundle" >&2
  fi

  if [[ ! -f "$demo_bundle" ]]; then
    echo "Building demo bundle..." >&2
    mkdir -p "$(dirname "$demo_bundle")"
    nim js -d:danger -o:"$demo_bundle" demos/isonim-replica/src/main.nim 2>&2
  fi

  if [[ -f "$demo_bundle" ]]; then
    local size
    size=$(get_file_size "$demo_bundle")
    local human
    human=$(format_bytes "$size")
    output_metric "isonim-demo-bundle" "$size" "bytes" "$human (-d:danger)" "$is_first"
    is_first="false"
  else
    echo "Warning: Demo bundle not found: $demo_bundle" >&2
  fi

  if [[ ! -f "$wc_bundle" ]]; then
    echo "Building web components bundle..." >&2
    mkdir -p "$(dirname "$wc_bundle")"
    nim js -d:danger -o:"$wc_bundle" demos/web-components/src/components.nim 2>&2
  fi

  if [[ -f "$wc_bundle" ]]; then
    local size
    size=$(get_file_size "$wc_bundle")
    local human
    human=$(format_bytes "$size")
    output_metric "isonim-webcomponents-bundle" "$size" "bytes" "$human" "$is_first"
    is_first="false"
  else
    echo "Warning: Web components bundle not found: $wc_bundle" >&2
  fi

  echo ""
  echo "]"
}

collect_tests() {
  local is_first="true"

  echo "["

  echo "Counting C backend tests..." >&2
  local c_count
  c_count=$(count_tests "c")
  output_metric "isonim-test-count-c" "$c_count" "tests" "$c_count passing tests (C backend)" "$is_first"
  is_first="false"

  echo "Counting JS backend tests..." >&2
  local js_count
  js_count=$(count_tests "js")
  output_metric "isonim-test-count-js" "$js_count" "tests" "$js_count passing tests (JS backend)" "$is_first"

  echo ""
  echo "]"
}

case "$MODE" in
  --sizes)
    collect_sizes
    ;;
  --tests)
    collect_tests
    ;;
  --all)
    # Combine both outputs into a single JSON array.
    # We collect sizes and tests separately, then merge.
    sizes_json=$(collect_sizes 2>/dev/null)
    tests_json=$(collect_tests 2>/dev/null)

    # Strip the outer [ ] and combine
    sizes_inner=$(echo "$sizes_json" | sed '1d;$d')
    tests_inner=$(echo "$tests_json" | sed '1d;$d')

    echo "["
    if [[ -n "$sizes_inner" ]] && [[ -n "$tests_inner" ]]; then
      echo "$sizes_inner,"
      echo "$tests_inner"
    elif [[ -n "$sizes_inner" ]]; then
      echo "$sizes_inner"
    elif [[ -n "$tests_inner" ]]; then
      echo "$tests_inner"
    fi
    echo "]"
    ;;
  --help|-h)
    echo "Usage: $0 [--sizes|--tests|--all]"
    exit 0
    ;;
  *)
    echo "Error: Unknown option: $MODE" >&2
    echo "Usage: $0 [--sizes|--tests|--all]" >&2
    exit 1
    ;;
esac
