## Consumer composition root. The editor framework owns commands and transport;
## this source project owns fixtures, native producer and rendered catalog.
import isonim/editor/[browser, source_browser, workspace, types]
let project = newEditorWorkspace("Source project", @[], id = "source-project",
  foundationTokens = @[
    FoundationTokenEntry(key: "color/surface", kind: ftkSemanticColor, value: "#112233"),
    FoundationTokenEntry(key: "color/accent", kind: ftkSemanticColor, value: "#445566")],
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let editor = mountEditor(project)
editor.attachSourceProject(project)
