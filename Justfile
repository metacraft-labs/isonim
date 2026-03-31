# IsoNim — Isomorphic reactive web framework for Nim

# Run all tests (both JS and C targets)
test: test-c test-js

# Run tests on C target
test-c:
    nim c -r tests/test_signals.nim
    nim c -r tests/test_effects.nim

# Run tests on JS target
test-js:
    nim js -r tests/test_signals.nim
    nim js -r tests/test_effects.nim

# Run only signal tests
test-signals:
    nim c -r tests/test_signals.nim
    nim js -r tests/test_signals.nim

# Run only effect/memo/owner/batch tests
test-effects:
    nim c -r tests/test_effects.nim
    nim js -r tests/test_effects.nim

# Run js-framework-benchmark
bench-framework:
    @echo "TODO: implement after M8"

# Build and serve SolidJS demo
demo-solid:
    @echo "TODO: implement after M9"

# Build and serve IsoNim demo
demo-isonim:
    @echo "TODO: implement after M10"
