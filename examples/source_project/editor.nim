## Consumer composition root. The editor framework owns commands and transport;
## this source project owns fixtures, native producer and rendered catalog.
import isonim/editor/[browser, source_browser, workspace]
let project = newEditorWorkspace("Source project", @[], id = "source-project",
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let editor = mountEditor(project)
editor.attachSourceProject(project)
