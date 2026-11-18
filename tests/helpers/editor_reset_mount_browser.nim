## Browser host for the mounted-preview cases of
## `tests/test_editor_reset_rebuild_gui.mjs`: a preview the project MOUNTS
## (`EditorVM.previewMount`) into a document that has a `<head>`, so the edit
## document gets the editor's declaration runtime, and whose `.fixture` rule
## gives the mounted button its width.
##
## Adapted from `tests/helpers/editor_preview_mount_browser.nim` (the real
## DOMRenderer shell over a declared project shell and a real mount callback
## that appends DOM content). Nothing is mocked: the removal is made through
## the editor's own `applyPreviewStyle`, which applies it in the frame and
## keeps the record the frame reports, and the rebuild is the VM's own
## reload of the preview's document. The host has no edit adapter, so no
## write follows -- the preview's document stays the one from before the
## removal, which is the document a rebuild after a no-reload write uses.
##
## Why the mounted path needs its own case: the bridge's replay runs at the
## end of `<body>`, before the project has mounted anything, so there is no
## element for a record to resolve against; only the replay after the mount
## (`preview_mount.nim`) puts a removal back.

when not defined(js):
  {.error: "Compile with `nim js`".}

import std/[dom, json]
import isonim/editor/[browser, dom_renderer, viewmodels, types, stories]
import isonim/core/[signals, computation, owner]
import isonim/editor/views/shell
import isonim/editor/views/widgets/property_commit

let vm = createEditorVM()
var mounts = 0
vm.sidebar.groups.val = buildStoryboard()
vm.preview.hook = proc(story: StoryRef; platform: Platform): ProjectPreview =
  ProjectPreview(status: ppsRendered, story: story, title: story.name,
    documentHtml: "<!doctype html><html><head><style>" &
      ".fixture { width: 160px; } button { width: 120px; }" &
      "</style></head><body></body></html>",
    metadata: StoryRenderMetadata(story: story,
      sourceFile: "declared-preview-fixture.nim", sourceLine: 1))
vm.preview.sourceGeneration.val = vm.preview.sourceGeneration.val + 1
vm.previewMount = proc(story: StoryRef; host: PreviewMountHost) =
  inc mounts
  let button = host.ownerDocument.createElement("button")
  button.setAttribute("id", "fixture-action")
  button.setAttribute("class", "fixture")
  button.setAttribute("style", "height:60px")
  button.textContent = "Fixture action"
  host.appendChild(button)
vm.setEditMode(emEdit)
injectEditorStyles()
var disposeView: proc()
createRoot do(dispose: proc()):
  disposeView = dispose
  document.body.appendChild(renderEditorShell[DomRenderer, Element](DomRenderer(), vm))

proc selectFirstComponent(): bool =
  for group in vm.sidebar.groups.val:
    for storyIndex, story in group.items:
      if story.kind == skComponent:
        return vm.selectStory(StoryRef(group: story.group, name: story.name,
          kind: story.kind, index: storyIndex))
proc snapshot(): cstring =
  cstring($(%*{"story": vm.selectedStory.val.name, "view": $vm.activeView.val,
    "mode": $vm.editMode.val, "mounts": mounts,
    "reloadGeneration": vm.livePreviewReloadGeneration.val}))
proc reloadPreview() =
  ## The preview's document rebuilt from the same project document, with the
  ## records kept: what a rebuild after a no-reload write sees.
  vm.livePreviewReloadGeneration.val = vm.livePreviewReloadGeneration.val + 1
proc removeWidth(): bool =
  ## The removal a Reset of the button's `width` shows, through the editor's
  ## own preview path, at the shared class scope its rule is.
  applyPreviewStyle("fixture-action", "#fixture-action", "width", "",
    sskSharedClass)
let selectFn = selectFirstComponent
let snapshotFn = snapshot
let reloadFn = reloadPreview
let removeFn = removeWidth
{.emit: ["window.__resetMount={select:", selectFn, ",snapshot:", snapshotFn,
  ",reload:", reloadFn, ",removeWidth:", removeFn, "};"].}
