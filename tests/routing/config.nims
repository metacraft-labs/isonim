# tests/routing: the route-manifest tests that run against the nginx fixture
# (tests/nginx/README.md).  tests/config.nims is read here too, but its
# `$projectDir`-relative paths assume tests/ as the project directory, so the
# paths these tests need are given again relative to tests/routing.
switch("path", "$projectDir/../../src")
switch("path", "$projectDir/..")
switch("path", "$projectDir/../../../nim-everywhere/src")
switch("path", "$projectDir/../../../nim-faststreams")
switch("path", "$projectDir/../../../nim-stew")
