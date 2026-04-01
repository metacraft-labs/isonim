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
    nim c -r tests/test_ssr.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim
    nim c -r tests/test_benchmark.nim
    nim c -r tests/test_viewmodel.nim
    nim c -r tests/test_demo_vm.nim
    nim c -r tests/test_terminal.nim
    nim c -r tests/test_native_renderer.nim
    nim c -r tests/test_nginx_module.nim

# Run tests on JS target
test-js:
    nim js -r tests/test_signals.nim
    nim js -r tests/test_effects.nim
    nim js -r tests/test_clock.nim
    nim js -r tests/test_context.nim
    nim js -r tests/test_rxcore.nim
    nim js -r tests/test_dsl.nim
    nim js -r tests/test_web.nim
    nim js -r tests/test_demo_vm.nim
    nim js -r tests/test_benchmark.nim
    nim js -r tests/test_viewmodel.nim
    nim js -r tests/test_terminal.nim
    nim js -r tests/test_hydration.nim
    nim js -r tests/test_ssr_hydration_e2e.nim
    nim js -r tests/test_app_e2e.nim

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
    nim c -r tests/test_dsl_ssr.nim

# Run SSR and round-trip tests
test-ssr:
    nim c -r tests/test_ssr.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim

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

# Run headless E2E app tests (Node.js DOM shim)
test-app-e2e:
    nim js -r tests/test_app_e2e.nim

# Build demo app for browser testing
demo-build:
    nim js -o:demos/isonim-replica/dist/main.js demos/isonim-replica/src/main.nim

# Run Playwright browser tests (requires: just demo-build && cd tests/browser && npm install)
test-browser:
    cd tests/browser && npx playwright test

# Build and serve SolidJS demo
demo-solid:
    @echo "TODO: implement after M9"

# Build and serve IsoNim demo
demo-isonim:
    @echo "TODO: implement after M10"

# Run Storybook for visual component development
storybook:
    cd demos/isonim-replica/storybook && npx storybook dev -p 6006
