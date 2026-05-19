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
    nim c -r tests/test_corner_cases.nim
    nim c -r tests/test_accessibility.nim
    nim c -r tests/test_router.nim
    nim c -r tests/test_ssr_routing.nim
    nim c -r tests/test_server_functions.nim
    nim c -r tests/test_data_loading.nim
    nim c -r tests/test_file_routes.nim
    nim c -r tests/test_http_types.nim
    nim c -r tests/test_streaming_stress.nim
    nim c -r tests/test_third_party.nim
    nim c -r tests/poc_monaco_host.nim

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
    nim js -r tests/test_web_components_advanced.nim
    nim js -r tests/test_third_party.nim
    nim js -r tests/poc_monaco_host.nim
    nim js -r tests/test_accessibility.nim
    nim js -r tests/test_router.nim
    nim js -r tests/test_server_functions.nim
    nim js -r tests/test_data_loading.nim

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

# Run only server function tests
test-server:
    nim c -r tests/test_server_functions.nim
    nim js -r tests/test_server_functions.nim

# Run data loading (server resource) tests
test-data-loading:
    nim c -r tests/test_data_loading.nim
    nim js -r tests/test_data_loading.nim

# Run SSR and round-trip tests
test-ssr:
    nim c -r tests/test_ssr.nim
    nim c -r tests/test_streaming.nim
    nim c -r tests/test_dsl_ssr.nim
    nim c -r tests/test_round_trip.nim

# Run only web renderer tests (JS-only)
test-web:
    nim js -r tests/test_web.nim

# --- IsoNim Design Review CLI (REV-M1) ---

# Build the isonim-review CLI. Compiles tools/isonim_review/main.nim to
# build/bin/isonim-review. Used by REV-M1's CLI integration tests and
# by the capture / review loop (REV-M5+).
isonim-review-build:
    mkdir -p build/bin
    nim c -d:release --path:src --hints:off --out:build/bin/isonim-review tools/isonim_review/main.nim
    @echo "Built: build/bin/isonim-review"

# Run REV-M1's design-review unit + integration tests.
test-design-review: isonim-review-build
    nim c -r tests/test_design_review_brief_format.nim
    nim c -r tests/test_design_review_brief_index.nim
    nim c -r tests/test_design_review_isonim_review_cli.nim

# --- IsoNim Editor ---

# Build the editor (Nim → JS)
editor-build:
    mkdir -p build/editor
    nim js --path:src --path:. --path:../nim-everywhere/src -o:build/editor/editor.js src/isonim/editor/main.nim
    cp src/isonim/editor/index.html build/editor/index.html
    cp node_modules/fabric/dist/index.min.js build/editor/fabric.min.js
    cp node_modules/paper/dist/paper-core.min.js build/editor/paper-core.min.js
    cp node_modules/svgo/dist/svgo.browser.js build/editor/svgo.browser.js
    @echo "Built: build/editor/ — open build/editor/index.html"

# Build and serve the editor
editor-serve: editor-build
    @echo "Serving editor on http://localhost:8090"
    cd build/editor && python3 -m http.server 8090

# Screenshot all views at all sizes → build/editor/screenshots/
editor-screenshot:
    node tools/editor-screenshot.mjs

# Screenshot a specific view (shell, sidebar-only, inspector-only, preview-only)
editor-screenshot-view view:
    node tools/editor-screenshot.mjs --view {{view}}

# Screenshot at a specific size (wide, laptop, medium, tablet, narrow, mobile)
editor-screenshot-size size:
    node tools/editor-screenshot.mjs --size {{size}}

# Screenshot a specific view at a specific size
editor-shot view size:
    node tools/editor-screenshot.mjs --view {{view}} --size {{size}}

# Quick screenshot — shell at wide, skip rebuild
editor-quick:
    node tools/editor-screenshot.mjs --view shell --size wide --no-build

# List available views and sizes
editor-screenshot-list:
    node tools/editor-screenshot.mjs --list

# Run editor ViewModel tests
test-editor:
    nim c -r tests/test_editor_workspace.nim
    nim c -r tests/test_editor_public_api.nim
    nim js --path:src -o:build/test_editor_public_browser_imports.js tests/test_editor_public_browser_imports.nim
    nim c -r tests/test_editor_release_gate.nim
    node --test tests/test_editor_visual_review_brief.mjs
    nim c -r tests/test_editor_viewmodels.nim
    nim c -r --path:../nim-acp/src tests/test_editor_agent_context.nim
    nim c -r tests/test_editor_agent_harbor.nim
    nim c -r tests/test_editor_user_project.nim
    nim c -r tests/test_editor_shell_views.nim
    nim c -r tests/test_editor_task_views.nim
    nim c -r tests/test_editor_interactivity.nim
    nim c -r tests/test_editor_responsive.nim
    nim c -r tests/test_editor_streaming_preview.nim

# Run packaged editor browser tests.
test-browser-editor-example: editor-build
    cd tests/browser && npm install && npx playwright test --project=editor-example

# Run the M43 visual screenshot, pixel, layout, and review brief gates.
test-editor-visual-gates: editor-build
    node --test tests/test_editor_visual_review_brief.mjs
    cd tests/browser && npm install && npx playwright test --project=editor-example --grep "e2e_editor_visual_baselines_cover_all_primary_modes|e2e_editor_ui_quality_no_overlap_or_unexpected_scrollbars|e2e_long_tail_css_property_visual_evidence"

# Run live consumer browser contract tests against metacraft-web.
test-browser-editor-consumer:
    cd ../metacraft-web && just build-back-office-editor
    cd tests/browser && npm install && npx playwright test --project=metacraft-web-editor

# Run all editor browser tests.
test-browser-editor: test-browser-editor-example test-browser-editor-consumer

# --- Benchmarks ---

# Build js-framework-benchmark entry. The benchmark imports
# `nim_everywhere/js_collections` transitively; resolve via an
# explicit --path so the build doesn't depend on `nimble develop`
# state. We invoke nim directly here rather than via the
# benchmarks/.../build.sh wrapper because the wrapper is intended to
# stay path-agnostic (so it works whether nimble develop has linked
# nim_everywhere or not).
bench-build:
    mkdir -p benchmarks/keyed/isonim/dist
    nim js -d:danger --path:$PWD/../nim-everywhere/src \
      -o:benchmarks/keyed/isonim/dist/main.raw.js \
      benchmarks/keyed/isonim/src/main.nim
    npx terser benchmarks/keyed/isonim/dist/main.raw.js --compress --mangle \
      -o benchmarks/keyed/isonim/dist/main.js

# Build the HMR-enabled benchmark entry. Same workload as
# bench-build, but compiled with -d:isonimHmr so the HMR runtime is
# linked in. Use this to quantify HMR's bundle-size cost.
bench-build-hmr:
    mkdir -p benchmarks/keyed/isonim-hmr/dist
    nim js -d:danger -d:isonimHmr --path:$PWD/../nim-everywhere/src \
      -o:benchmarks/keyed/isonim-hmr/dist/main.raw.js \
      benchmarks/keyed/isonim-hmr/src/main.nim
    npx terser benchmarks/keyed/isonim-hmr/dist/main.raw.js --compress --mangle \
      -o benchmarks/keyed/isonim-hmr/dist/main.js

# Show benchmark bundle size (raw, minified, gzipped)
bench-size:
    @echo "Raw:      $$(wc -c < benchmarks/keyed/isonim/dist/main.raw.js 2>/dev/null || echo '?') bytes"
    @echo "Minified: $$(wc -c < benchmarks/keyed/isonim/dist/main.js) bytes"
    @echo "Gzipped:  $$(gzip -c benchmarks/keyed/isonim/dist/main.js | wc -c) bytes"

# Run benchmark tests
bench-test:
    nim c -r tests/test_benchmark.nim
    nim js -r tests/test_benchmark.nim

# Set up the krausest benchmark runner (clone + install, one-time)
bench-setup:
    @echo "Setting up benchmark runner..."
    BENCH_SETUP_ONLY=1 bash benchmarks/run-comparison.sh || true
    @echo "Runner ready at benchmarks/runner/"

# Run IsoNim vs SolidJS comparison benchmark. Builds both isonim
# variants (vanilla + HMR-enabled) so the comparison includes the
# HMR overhead measurement alongside the SolidJS reference.
bench-compare: bench-build bench-build-hmr
    bash benchmarks/run-comparison.sh

# Run comparison with fewer iterations (quick check)
bench-compare-quick: bench-build bench-build-hmr
    BENCH_ITERATIONS=3 bash benchmarks/run-comparison.sh

# View benchmark results (starts HTTP server)
bench-results:
    @if [ ! -d benchmarks/runner ]; then echo "Run 'just bench-compare' first"; exit 1; fi
    @echo "Starting server... Open http://localhost:8080/webdriver-ts-results/dist/index.html"
    cd benchmarks/runner && npm start

# Build and report benchmark metrics
bench-framework: bench-build bench-size

# Run headless E2E app tests (Node.js DOM shim)
test-app-e2e:
    nim js -r tests/test_app_e2e.nim

# Build demo app for browser testing
demo-build:
    nim js --path:../nim-everywhere/src -o:demos/isonim-replica/dist/main.js demos/isonim-replica/src/main.nim

# Build SSR test HTML (C target: generates tests/browser/dist/ssr.html)
build-ssr-test:
    mkdir -p tests/browser/dist
    nim c --path:../nim-everywhere/src -d:isServer -r tests/browser/generate_ssr.nim

# Build hydration entry point (JS target: tests/browser/dist/main.js)
build-hydrate:
    mkdir -p tests/browser/dist
    nim js --path:../nim-everywhere/src -o:tests/browser/dist/main.js tests/browser/hydrate_entry.nim

# Build all SSR test assets
build-ssr-test-all: build-ssr-test build-hydrate

# Build the HMR fixture bundle (JS target with -d:isonimHmr).
build-hmr-fixture:
    mkdir -p tests/browser/hmr_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_fixture/main.js tests/browser/hmr_fixture/main.nim

# Run the HMR Playwright spec (requires: just build-hmr-fixture).
test-browser-hmr: build-hmr-fixture
    cd tests/browser && npx playwright test --project=hmr

# Build the parametric-HMR fixture (JS target with -d:isonimHmr). The
# fixture exercises the parametric `{.uiComponent.}` dispatch and
# `mountUiHot` via two independent panel mounts.
build-hmr-parametric-fixture:
    mkdir -p tests/browser/hmr_parametric_fixture
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_parametric_fixture/main.js tests/browser/hmr_parametric_fixture/main.nim

# Run the parametric-HMR Playwright spec.
test-browser-hmr-parametric: build-hmr-parametric-fixture
    cd tests/browser && npx playwright test --project=hmr-parametric

# Build the SSE-transport fixture: the dev server, the "before" and
# "after" client bundles, and the seeded main.js. The Playwright
# project triggers a rebuild via the dev server's POST /__isonim/trigger
# endpoint to swap before → after at runtime.
build-hmr-transport-fixture:
    nim c -d:isServer --path:src --path:../nim-everywhere/src --path:../nim-faststreams --path:../nim-stew -o:/tmp/isonim_test_server tests/browser/hmr_transport_fixture/server.nim
    nim js -d:isonimHmr --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/app.nim
    nim js -d:isonimHmr -d:transportFixtureAfter --path:src --path:../nim-everywhere/src -o:tests/browser/hmr_transport_fixture/after.js tests/browser/hmr_transport_fixture/app.nim
    cp tests/browser/hmr_transport_fixture/before.js tests/browser/hmr_transport_fixture/main.js

# Run the SSE-transport Playwright spec.
test-browser-hmr-transport: build-hmr-transport-fixture
    cd tests/browser && npx playwright test --project=hmr-transport

# Run Playwright browser tests (requires: just demo-build && cd tests/browser && npm install)
test-browser: test-browser-demo test-browser-ssr test-browser-hmr test-browser-hmr-parametric test-browser-hmr-transport

# Run Playwright demo app tests only
test-browser-demo:
    cd tests/browser && npx playwright test --project=demo-app

# Run Playwright SSR hydration tests (requires: just build-ssr-test-all)
test-browser-ssr: build-ssr-test-all
    cd tests/browser && npx playwright test --project=ssr-hydration

# Build and serve SolidJS demo
demo-solid:
    @echo "TODO: implement after M9"

# Build and serve IsoNim demo
demo-isonim:
    @echo "TODO: implement after M10"

# Build IsoNim components for Storybook (Nim -> JS)
build-storybook-components:
    mkdir -p demos/isonim-replica/storybook/dist
    nim js --path:../nim-everywhere/src -o:demos/isonim-replica/storybook/dist/components.js demos/isonim-replica/src/storybook_components.nim

# Run Storybook for visual component development (builds components first)
storybook: build-storybook-components
    cd demos/isonim-replica/storybook && npx storybook dev -p 6006

# Build Storybook static site (builds components first)
storybook-build: build-storybook-components
    cd demos/isonim-replica/storybook && npx storybook build

# Build standalone Web Components demo (Nim -> JS)
build-web-components:
    mkdir -p demos/web-components/dist
    nim js --path:../nim-everywhere/src -o:demos/web-components/dist/components.js demos/web-components/src/components.nim

# Build and serve the standalone Web Components demo page
demo-web-components: build-web-components
    @echo "Serving demos/web-components/ on http://localhost:8080"
    cd demos/web-components && python3 -m http.server 8080

# Collect benchmark metrics (sizes + test counts)
bench-metrics:
    ./scripts/collect-metrics.sh --all

# Collect bundle size metrics only
bench-metrics-sizes:
    ./scripts/collect-metrics.sh --sizes

# Collect test count metrics only
bench-metrics-tests:
    ./scripts/collect-metrics.sh --tests

# Build all bundles, collect metrics, and report
bench-all: bench-build demo-build build-web-components
    @echo "=== Bundle Size Metrics ==="
    ./scripts/collect-metrics.sh --sizes
    @echo ""
    @echo "=== Test Count Metrics ==="
    ./scripts/collect-metrics.sh --tests

# Lint hook expected by the workspace pre-commit framework. The IsoNim
# Nim style is enforced by --styleCheck:usages --styleCheck:error inside
# the test recipes; this recipe is a placeholder so pre-commit's
# `just lint` hook resolves. Extend it with nimpretty / nim check when
# the linting story is ready.
lint:
    @echo "isonim: lint placeholder (Nim style enforced inside test recipes)"
