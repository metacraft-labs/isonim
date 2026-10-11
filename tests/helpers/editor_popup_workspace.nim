## Mounted production editor with real source catalog/agent-command transports.
## No renderer, filesystem or compiler boundary is mocked. Foundation metadata
## is ordinary fixture data for this minimal project. The catalog-only build
## explicitly preserves the original preview-edit consumer contract; its edits
## do not claim source persistence. The default/native-inspector build installs
## genuine guarded source writes and diagnoses unsupported declarations readonly.
## Production attachment defaults to native inspector editing. The controlled
## peer only permits daemon startup; actual suites assert zero agent requests.
import std/[json, options]
import isonim/editor/[browser, source_browser, workspace, viewmodels, types]
import isonim/core/signals
var items: seq[StoryItem] = @[]
for i in 0 ..< 100:
  items.add StoryItem(name: "long story " & $i, group: "Card", kind: skComponent)
items.add StoryItem(name: "default ready", group: "Card", kind: skComponent)
proc fixtureTokens(): seq[FoundationTokenEntry] =
  for i in 0 ..< 90:
    result.add FoundationTokenEntry(key: "color/test-" & $i,
      kind: ftkSemanticColor, value: "#112233")
let project = newEditorWorkspace("Popup acceptance", @[StoryGroup(name: "Card", kind: skComponent, items: items)], id = "source-project",
  initialView = evComponentDetail,
  initialStory = some(StoryRef(kind: skComponent, group: "Card", name: "default ready")),
  foundationTokens = fixtureTokens(),
  permissions = EditorWorkspacePermissions(readSource: true, writeSource: true, createStory: true))
let editor = mountEditor(project)
editor.attachSourceProject(project, inspectorEditing = not defined(isonimCatalogOnlyPopup))
let initialChat = editor.chats.val[0].vm
{.emit: ["window.__popupInitialClient = globalThis.__isonimEditorAgentClients.get(", initialChat, ");"].}
proc catalogOnlyAttempt(): cstring =
  try:
    editor.attachSourceProject(project, inspectorEditing = false)
    return ""
  except ValueError as error:
    return error.msg.cstring
proc unmount(): bool = unmountEditor(editor)
proc remount(): bool = mountEditor(editor, injectStyles = false) == editor
proc sameClient(): bool =
  {.emit: [result, " = globalThis.__isonimEditorAgentClients.get(", initialChat, ") === window.__popupInitialClient;"].}
proc readOnly(value: bool) =
  var permissions = editor.workspacePermissions.val
  permissions.writeSource = not value
  editor.workspacePermissions.val = permissions
proc tokens() =
  editor.foundations.tokens.val = fixtureTokens()
proc select(id: cstring): bool = editor.selectInspectorElementById($id)
proc openStory(group, name: cstring): bool =
  for entry in editor.sidebar.groups.val:
    for index, story in entry.items:
      if story.group == $group and story.name == $name:
        return editor.selectStory(StoryRef(group: story.group, name: story.name, kind: story.kind, index: index))
proc history(redo: bool) = discard editor.runEditorCommand(if redo: eckRedo else: eckUndo)
proc clear() = editor.clearInspectorSelection()
proc activeView(edit: bool) = editor.setActiveView(if edit: evComponentEdit else: evComponentDetail)
proc observerDetails(): cstring =
  let state = editor.inspector.selectedElement
  {.emit: [result, """ = JSON.stringify((function (state) {
    const groups = new Map(), unique = new Set(state.observers);
    for (const node of unique) {
      const name = node.fn?.ClP_0?.name || node.fn?.name || 'unnamed';
      const owner = node.owner?.fn?.ClP_0?.name || node.owner?.fn?.name || 'root';
      const key = name + ' / owner:' + owner;
      const group = groups.get(key) || {name,owner,computations:0,sourceEdges:0,ownerDepth:0};
      group.computations++; group.sourceEdges+=node.sources.length;
      let parent=node.owner,depth=0;while(parent&&depth<30){depth++;parent=parent.owner;}
      group.ownerDepth=Math.max(group.ownerDepth,depth);groups.set(key,group);
    }
    return {uniqueComputations:unique.size,groups:[...groups.values()].sort((a,b)=>b.computations-a.computations)};
  })(""", state, "));"].}
proc attemptSelectedNativeProperty(property, value: cstring): cstring =
  ## Supplementary admission check calls the installed real writer with the
  ## actual selected DOM-derived ElementRef. It is not physical input evidence
  ## or an alternative compiler path; the GUI source edits prove those paths.
  var reply = %*{"completed": false}
  editor.inspectorSourceCommit(editor.inspector.selectedElement.val, $property,
    $value, sskLocalInstance, proc(ok: bool; diagnostic: string) =
      reply = %*{"completed": true, "ok": ok, "diagnostic": diagnostic})
  cstring($reply)
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
    "stage": $editor.workspaceEditStage.val, "story": editor.selectedStory.val.group & " / " & editor.selectedStory.val.name,
    "reactiveObservers": {"selected": editor.inspector.selectedElement.observers.len,
      "preview": editor.preview.current.signal.observers.len,
      "reload": editor.livePreviewReloadGeneration.observers.len},
    "sourcePlans": editor.inspector.pendingSourceEdits.val.len, "undoCount": editor.inspector.undoStack.val.len, "redoCount": editor.inspector.redoStack.val.len,
    "sourceInFlight": editor.sourceProjectBuildInFlight, "sourceOperationSerial": editor.sourceProjectOperationSerial,
    "sourceMappingObservers": (if editor.sourceProjectMappings != nil: editor.sourceProjectMappings.observers.len else: 0),
    "sourceGeneration": editor.preview.sourceGeneration.val, "properties": properties}))
{.emit: ["window.__popupAcceptance = {attemptSelectedNativeProperty:", attemptSelectedNativeProperty, ",catalogOnlyAttempt:", catalogOnlyAttempt, ", observerDetails:", observerDetails, ", openStory:", openStory, ", history:", history, ", clear:", clear, ", activeView:", activeView, ", unmount:", unmount, ", remount:", remount, ", sameClient:", sameClient, ", readOnly:", readOnly, ", tokens:", tokens, ", select:", select, ", snapshot:", snapshot, "};"].}
