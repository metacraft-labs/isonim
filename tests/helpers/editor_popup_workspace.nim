## Production source-backed editor for mounted popup acceptance. This composition
## replaces no renderer, inspector, DOM, HTTP, source adapter, filesystem or compiler.
## Only foundation metadata is supplied by the fixture because the minimal source
## project has no design-token library. Token metadata is ordinary workspace data,
## not a substitute for successful source edits. This project supports genuine
## preview edits; a real read-only permission transition tests refusal. No literal
## write adapter is installed. A small driver exposes readonly state snapshots,
## production selection and permission configuration for deterministic scenarios.
import std/[json, options]
import isonim/editor/[browser, source_browser, workspace, viewmodels, types]
import isonim/core/signals
var items: seq[StoryItem] = @[]
for i in 0 ..< 100:
  items.add StoryItem(name: "long story " & $i, group: "Card", kind: skComponent)
items.add StoryItem(name: "default ready", group: "Card", kind: skComponent)
let project = newEditorWorkspace("Popup acceptance", @[StoryGroup(name: "Card", kind: skComponent, items: items)], id = "source-project",
  initialView = evComponentDetail,
  initialStory = some(StoryRef(kind: skComponent, group: "Card", name: "default ready")),
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let editor = mountEditor(project)
editor.attachSourceProject(project)
let initialChat = editor.chats.val[0].vm
{.emit: ["window.__popupInitialClient = globalThis.__isonimEditorAgentClients.get(", initialChat, ");"].}
proc unmount(): bool = unmountEditor(editor)
proc remount(): bool = mountEditor(editor, injectStyles = false) == editor
proc sameClient(): bool =
  {.emit: [result, " = globalThis.__isonimEditorAgentClients.get(", initialChat, ") === window.__popupInitialClient;"].}
proc readOnly(value: bool) =
  var permissions = editor.workspacePermissions.val
  permissions.writeSource = not value
  editor.workspacePermissions.val = permissions
proc tokens() =
  var entries: seq[FoundationTokenEntry] = @[]
  for i in 0 ..< 90:
    entries.add FoundationTokenEntry(key: "color/test-" & $i,
      kind: ftkSemanticColor, value: "#112233")
  editor.foundations.tokens.val = entries
proc select(id: cstring): bool = editor.selectInspectorElementById($id)
proc clear() = editor.clearInspectorSelection()
proc activeView(edit: bool) = editor.setActiveView(if edit: evComponentEdit else: evComponentDetail)
proc snapshot(): cstring =
  var properties = newJArray()
  for property in editor.inspector.selectedElement.val.properties:
    properties.add %*{"name": property.name, "value": property.value}
  var bindings = newJObject()
  for property in ["color", "background-color"]:
    let binding = editor.inspectorBindingFor(property)
    bindings[property] = %(if binding.isSome: binding.get.variableKey else: "")
  cstring($(%*{"bindings": bindings, "selected": editor.inspector.selectedElement.val.id,
    "activeView": $editor.activeView.val, "leftWidth": editor.leftSidebarWidth.val, "rightWidth": editor.rightPanelWidth.val,
    "hover": editor.inspector.hoveredElementId.val,
    "layerSearch": editor.inspector.layerSearch.val, "expandedLayers": editor.inspector.expandedLayerIds.val,
    "stage": $editor.workspaceEditStage.val,
    "sourcePlans": editor.inspector.pendingSourceEdits.val.len, "undoCount": editor.inspector.undoStack.val.len, "sourceGeneration": editor.preview.sourceGeneration.val, "properties": properties}))
{.emit: ["window.__popupAcceptance = {clear:", clear, ", activeView:", activeView, ", unmount:", unmount, ", remount:", remount, ", sameClient:", sameClient, ", readOnly:", readOnly, ", tokens:", tokens, ", select:", select, ", snapshot:", snapshot, "};"].}
