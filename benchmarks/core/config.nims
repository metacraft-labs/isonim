# The library sources and the `nim-everywhere` sibling, declared here so the
# micro-benchmark builds the same way from `just` and from a bare `nim js`
# (the same reasoning as `benchmarks/keyed/isonim/src/config.nims`).
switch("path", "$projectDir/../../src")
switch("path", "$projectDir/../../../nim-everywhere/src")
