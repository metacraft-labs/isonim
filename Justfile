# IsoNim — Isomorphic reactive web framework for Nim

# Run all tests (both JS and C targets)
test: test-c test-js

# Run tests on C target
test-c:
    nim c -r tests/test_signals.nim
    nim c -r tests/test_effects.nim
    nim c -r tests/test_clock.nim
    nim c -r tests/test_context.nim
    nim c -r tests/test_rxcore.nim
    nim c -r tests/test_dsl.nim

# Run tests on JS target
test-js:
    nim js -r tests/test_signals.nim
    nim js -r tests/test_effects.nim
    nim js -r tests/test_clock.nim
    nim js -r tests/test_context.nim
    nim js -r tests/test_rxcore.nim
    nim js -r tests/test_dsl.nim
    nim js -r tests/test_web.nim

# Run only signal tests
test-signals:
    nim c -r tests/test_signals.nim
    nim js -r tests/test_signals.nim

# Run only clock/scheduler tests
test-clock:
    nim c -r tests/test_clock.nim
    nim js -r tests/test_clock.nim

# Run only context/resource/suspense/transition tests
test-context:
    nim c -r tests/test_context.nim
    nim js -r tests/test_context.nim

# Run only effect/memo/owner/batch tests
test-effects:
    nim c -r tests/test_effects.nim
    nim js -r tests/test_effects.nim

# Run only rxcore/renderer/mock-dom tests
test-rxcore:
    nim c -r tests/test_rxcore.nim
    nim js -r tests/test_rxcore.nim

# Run only DSL/html/components tests
test-dsl:
    nim c -r tests/test_dsl.nim
    nim js -r tests/test_dsl.nim

# Run only web renderer tests (JS-only)
test-web:
    nim js -r tests/test_web.nim

# Build js-framework-benchmark entry
bench-build:
    mkdir -p benchmarks/keyed/isonim/dist
    nim js -d:danger -o:benchmarks/keyed/isonim/dist/main.js benchmarks/keyed/isonim/src/main.nim

# Show benchmark bundle size
bench-size:
    @wc -c benchmarks/keyed/isonim/dist/main.js

# Run benchmark tests
bench-test:
    nim c -r tests/test_benchmark.nim
    nim js -r tests/test_benchmark.nim

# Build and report benchmark metrics
bench-framework: bench-build bench-size

# Build and serve SolidJS demo
demo-solid:
    @echo "TODO: implement after M9"

# Build and serve IsoNim demo
demo-isonim:
    @echo "TODO: implement after M10"
