## Real DOMRenderer dynamic first-selection preview and root lifetime fixture.
## A declared empty project HTML shell and real mount callback are controlled
## peers, not compiler/filesystem/native ACK/Harbor outcomes. The callback really
## appends DOM content. Trace wrappers forward unchanged actual browser methods;
## they only record document/VM identity. No renderer or load result is mocked.
import std/[dom, json]
import isonim/editor/[browser, dom_renderer, viewmodels, types, stories]
import isonim/core/[signals, computation, owner]
import isonim/editor/views/shell

let vm = createEditorVM()
var mounts = 0
var unmounts = 0
var disposed = false
var disposeView: proc()
vm.sidebar.groups.val = buildStoryboard()
vm.preview.hook = proc(story: StoryRef; platform: Platform): ProjectPreview =
  ProjectPreview(status: ppsRendered, story: story, title: story.name,
    documentHtml: "<!doctype html><html><body></body></html>",
    metadata: StoryRenderMetadata(story: story, sourceFile: "declared-preview-fixture.nim", sourceLine: 1))
vm.preview.sourceGeneration.val = vm.preview.sourceGeneration.val + 1
vm.previewMount = proc(story: StoryRef; host: PreviewMountHost) =
  inc mounts
  {.emit: ["window.__recordPreviewMount?.(", host, ");"].}
  let button = host.ownerDocument.createElement("button")
  button.setAttribute("id", "fixture-action")
  button.setAttribute("style", "width:160px;height:60px")
  button.setAttribute("data-probe-story", story.name.cstring)
  button.textContent = "Fixture action"
  host.appendChild(button)
  onCleanup proc() = inc unmounts
vm.setEditMode(emEdit)
injectEditorStyles()
createRoot do(dispose: proc()):
  disposeView = dispose
  document.body.appendChild(renderEditorShell[DomRenderer, Element](DomRenderer(), vm))

proc selectComponent(index: int): bool =
  var position = 0
  for group in vm.sidebar.groups.val:
    for storyIndex, story in group.items:
      if story.kind == skComponent:
        if position == index:
          return vm.selectStory(StoryRef(group: story.group, name: story.name,
            kind: story.kind, index: storyIndex))
        inc position
proc snapshot(): cstring =
  $(%*{"story": vm.selectedStory.val.name, "view": $vm.activeView.val,
    "mode": $vm.editMode.val, "platform": $vm.platform.val,
    "mounts": mounts, "unmounts": unmounts, "disposed": disposed,
    "selectedId": vm.inspector.selectedElement.val.id,
    "selectedTag": vm.inspector.selectedElement.val.tag,
    "pending": vm.inspector.pendingSourceEdits.val.len, "messages": vm.chat.messages.val.len})
proc reloadFixture() = vm.livePreviewReloadGeneration.val = vm.livePreviewReloadGeneration.val + 1
proc showStoryboard() = vm.activeView.val = evStoryboard
proc closeView() =
  if not disposed:
    disposed = true
    disposeView()
    document.body.innerHTML = ""
let selectFn = selectComponent
let snapshotFn = snapshot
let reloadFn = reloadFixture
let disposeFn = closeView
let storyboardFn = showStoryboard
{.emit: ["window.__mountProbe={select:", selectFn, ",snapshot:", snapshotFn,
  ",reload:", reloadFn, ",dispose:", disposeFn, ",storyboard:", storyboardFn, "};"].}
