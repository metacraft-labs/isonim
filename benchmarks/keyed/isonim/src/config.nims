switch("path", "$projectDir/../../../../src")
# The `nim-everywhere` sibling, declared here rather than only on one command
# line. `just bench-build` passes `--path:$PWD/../nim-everywhere/src` itself, so
# IT worked; `scripts/collect-metrics.sh --sizes` re-implements the same build
# with a bare `nim js` and no such flag, so it died on
# `src/isonim/core/js_collections.nim(5, 22) Error: cannot open file:
# nim_everywhere/js_collections`. Two spellings of one build is what let them
# drift. Declaring it here fixes the second without the first having to know.
# (`demos/config.nims` already declares its sibling path this way.)
switch("path", "$projectDir/../../../../../nim-everywhere/src")
