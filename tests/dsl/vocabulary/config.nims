## tests/dsl/vocabulary/config.nims — path fix for compile-failure fixtures.
##
## `tests/config.nims` addresses paths with `$projectDir` (the compiled main
## file's directory), which only resolves for mains directly under `tests/`.
## Fixture mains live three levels deeper, so `nim check` on them cannot see
## `isonim/*` without this file. `$config` is this file's own directory, so
## these paths are stable. Merged with (not replacing) `tests/config.nims`.
switch("path", "$config/../../../src")

# Sibling repos, mirroring tests/config.nims with fixed depth. Only those
# in the fixtures' transitive import closure are strictly needed; the rest
# are listed so a future fixture import cannot fail for a missing path.
switch("path", "$config/../../../../nim-faststreams")
switch("path", "$config/../../../../nim-stew")
switch("path", "$config/../../../../nim-everywhere/src")
switch("path", "$config/../../../../nim-acp/src")
switch("path", "$config/../../../../nim-agent-harbor/src")
switch("path", "$config/../../../../nim-agents/src")
