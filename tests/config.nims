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
