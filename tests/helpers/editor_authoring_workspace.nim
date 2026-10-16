## Thin mounted GRIP source-project composition for real-model acceptance.
## The fixture exposes ephemeral context controls on the actual EditorVM only;
## it substitutes no agent, HTTP, RPC, dispatcher, filesystem, compiler or view.
## The source-backed preview catalog is compiled from the real GRIP sources.
import isonim/editor/[browser, source_browser, workspace, viewmodels]
import isonim/core/signals
import isonim/editor/types
let project = newEditorWorkspace("GRIP authoring acceptance", @[], id = "grip-web-site",
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let editor = mountEditor(project)
editor.attachSourceProject(project)
proc context(value: cstring) = editor.chat.designSystemConstraints.val = @[$value]
proc draft(): cstring = editor.chat.inputText.val.cstring
proc busy(): bool = editor.chat.promptInFlight
{.emit: ["window.__authoringAcceptance = {context:", context, ", draft:", draft, ", busy:", busy, "};"].}
