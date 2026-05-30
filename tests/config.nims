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

# EPP-M5 / ETS-M4: the render-serve VideoToolbox encoder adapter
# imports ``isonim_cocoa/appkit/capture_videotoolbox`` unconditionally
# on macOS. The streaming_preview import chain pulls it in transitively
# (isonim_render_serve → adapters/h264_videotoolbox_encoder).
switch("path", "$projectDir/../../isonim-cocoa/src")

# REV-M3: vendored ``db_connector`` (provides ``db_connector/db_postgres``).
# Originally ``std/db_postgres`` in the stdlib; moved out of std in Nim
# 2.x.  Vendoring is the cheapest workaround while ``nimble install
# db_connector`` segfaults under the current Nim package manager (a known
# upstream issue on darwin); the source is the upstream
# ``github.com/nim-lang/db_connector`` mirrored into ``vendor/`` so the
# build is fully hermetic.
switch("path", "$projectDir/../vendor/db_connector/src")

# Phase B: vendored ``chronicles`` + its transitive deps so the daemon
# and CLI can emit structured logs without bringing the segfault-prone
# ``nimble install chronicles`` step into the build path.  See the
# isonim/CLAUDE.md Phase B notes for the vendoring rationale.
switch("path", "$projectDir/../vendor/chronicles")
switch("path", "$projectDir/../vendor/serialization")
switch("path", "$projectDir/../vendor/json_serialization")
switch("define", "nimOldCaseObjects")
switch("define", "chronicles_sinks=textlines[stderr]")
switch("define", "chronicles_runtime_filtering=on")
switch("define", "chronicles_log_level=TRACE")
