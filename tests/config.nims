switch("path", "$projectDir/../src")
switch("path", "$projectDir/..")
switch("path", "$projectDir/../demos/isonim-replica/src")

# Local workspace paths for sibling repos
switch("path", "$projectDir/../../nim-faststreams")
switch("path", "$projectDir/../../nim-stew")
switch("path", "$projectDir/../../nim-everywhere/src")
switch("path", "$projectDir/../../nim-acp/src")
switch("path", "$projectDir/../../nim-agent-harbor/src")
switch("path", "$projectDir/../../nim-agents/src")

# RS-M7: tests/test_editor_streaming_preview.nim imports
# isonim-render-serve via the streaming-preview widget.
switch("path", "$projectDir/../../isonim-render-serve/src")

# REV-M3: vendored ``db_connector`` (provides ``db_connector/db_postgres``).
# Originally ``std/db_postgres`` in the stdlib; moved out of std in Nim
# 2.x.  Vendoring is the cheapest workaround while ``nimble install
# db_connector`` segfaults under the current Nim package manager (a known
# upstream issue on darwin); the source is the upstream
# ``github.com/nim-lang/db_connector`` mirrored into ``vendor/`` so the
# build is fully hermetic.
switch("path", "$projectDir/../vendor/db_connector/src")
