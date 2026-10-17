## Real DOMRenderer full-shell browser-hook controls. The project preview hook
## supplies an explicitly declared HTML fixture to the normal preview pipeline;
## it is not a compiler/filesystem/Harbor result. Browser events, iframe selection,
## production normalizer, canvas navigation and VM controls are genuine.
import std/[dom,json]
import isonim/editor/[browser,dom_renderer,viewmodels,types,stories]
import isonim/core/[signals,computation,owner]
import isonim/editor/views/shell
import isonim/editor/views/spec_editor_toolbar
import isonim/editor/vendor/tiptap
let vm=createEditorVM()
let toolbar=createSpecEditorToolbarVM()
var mounts=0;var unmounts=0
vm.sidebar.groups.val=buildStoryboard()
vm.preview.hook=proc(story:StoryRef;platform:Platform):ProjectPreview =
  ProjectPreview(status:ppsRendered,story:story,title:story.name,
    documentHtml: (if story.kind in {skComponent,skPattern,skGuideline}: "<!doctype html><html><body></body></html>" else: "<!doctype html><html><body><button id='fixture-action' style='width:160px;height:60px'>Fixture action</button></body></html>"),
    metadata:StoryRenderMetadata(story:story,sourceFile:"declared-browser-fixture.nim",sourceLine:1))
vm.preview.sourceGeneration.val=vm.preview.sourceGeneration.val+1
vm.previewMount=proc(story:StoryRef;host:PreviewMountHost) =
  inc mounts
  let button=host.ownerDocument.createElement("button")
  button.setAttribute("id","fixture-action")
  button.setAttribute("style","width:160px;height:60px")
  button.textContent="Fixture action"
  host.appendChild(button)
  onCleanup proc() = inc unmounts
# Preselect declared metadata before mounting the shell; the browser test waits
# for its initial child documents to load before opening this prepared story.
vm.selectedStory.val=StoryRef(group:"TaskRow",name:"Active task",kind:skComponent)
vm.setEditMode(emEdit)
injectEditorStyles()
createRoot do(dispose:proc()):
  document.body.appendChild(renderEditorShell[DomRenderer,Element](DomRenderer(),vm))
  let toolbarHost=document.createElement("div")
  toolbarHost.setAttribute("data-browser-boundary-toolbar","true")
  toolbarHost.setAttribute("style","position:fixed;bottom:0;left:340px;width:700px;z-index:9999")
  document.body.appendChild(toolbarHost)
  mountSpecEditorToolbar[DomRenderer,Element](DomRenderer(),toolbarHost,toolbar,proc():TipTapEditor=nil)
proc stage(kind:int):bool =
  let wanted=case kind
    of 0:skComponent
    of 1:skPage
    else:skFoundation
  for group in vm.sidebar.groups.val:
    for index,story in group.items:
      if story.kind==wanted:
        if kind==0 and story.name!="Active task":continue
        return vm.selectStory(StoryRef(group:story.group,name:story.name,kind:story.kind,index:index))
proc state():cstring =
  $(%*{"panX":vm.storyboard.panX.val,"panY":vm.storyboard.panY.val,
    "zoom":vm.storyboard.zoom.val,"view": $vm.activeView.val,
    "selectedId":vm.inspector.selectedElement.val.id,
    "tag":vm.inspector.selectedElement.val.tag,"mode": $vm.editMode.val,
    "visible":vm.inspector.selectionVisible.val,"pending":vm.inspector.pendingSourceEdits.val.len,
    "messages":vm.chat.messages.val.len,"hasMount":vm.previewMount!=nil,"platform": $vm.platform.val,"mounts":mounts,"unmounts":unmounts,"linkOpen":toolbar.linkDraftOpen.val})
proc reloadFixture() = vm.livePreviewReloadGeneration.val=vm.livePreviewReloadGeneration.val+1
let reloadFn=reloadFixture
let stageFn=stage;let stateFn=state
{.emit:["window.__rendererBoundary={stage:",stageFn,",state:",stateFn,",reload:",reloadFn,"};"].}
