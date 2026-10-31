## Mounted real prototype workspace; no renderer/source/compiler substitutes.
## The driver only calls production story/selection/history commands and reads
## their state. The owning test compiles this with the disposable producer copy.
import std/[json, options]
import isonim/editor/[browser, source_browser, viewmodels, types]
import isonim/core/signals
import mount as source_workspace
# This composition mounts only the owned disposable GRIP copy. The live
# prototype remains read-only; explicitly opt this source-persistence fixture in.
var project = newGripEditorWorkspace()
project.permissions.writeSource = true
let editor = mountEditor(project)
editor.attachSourceProject(project)
proc openStory(group, name: cstring): bool =
  for entry in project.storyGroups:
    for index, story in entry.items:
      if story.group == $group and story.name == $name:
        return editor.selectStory(StoryRef(group: story.group, name: story.name, kind: story.kind, index: index))
proc select(id: cstring): bool = editor.selectInspectorElementById($id)
proc history(redo: bool) = discard editor.runEditorCommand(if redo: eckRedo else: eckUndo)
proc snapshot(): cstring =
  var properties = newJArray()
  for property in editor.inspector.selectedElement.val.properties:
    properties.add %*{"name": property.name, "value": property.value, "authoredValue": property.authoredValue,
      "shared":property.nativeSourceShared,"count":property.sharedCount,"schemaKey":property.schemaKey}
  cstring($(%*{"ready":editor.sourceAdapterReady.val,"selected":editor.inspector.selectedElement.val.id,
    "stage": $editor.workspaceEditStage.val,"undoCount":editor.inspector.undoStack.val.len,
    "view": $editor.activeView.val,"mode": $editor.editMode.val,"section": $editor.inspector.activeSection.val,
    "story":editor.selectedStory.val.group & " / " & editor.selectedStory.val.name,"properties":properties}))
{.emit: ["window.__sourceStyleAcceptance = {openStory:",openStory,",select:",select,",history:",history,",snapshot:",snapshot,"};"].}
