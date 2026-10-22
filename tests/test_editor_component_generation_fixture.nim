## Real component preview renderers and injected selection bridge in Chromium.
## The authored preview is a deterministic workspace document; no DOM, bridge,
## source compiler or source-write outcome is mocked. Counters wrap and forward
## actual producer/restoration calls solely to observe duplicate work.
when not defined(js): {.error: "browser fixture".}
import std/dom
import isonim/core/[signals, computation, owner]
import isonim/editor/[types, viewmodels, workspace, dom_renderer]
import isonim/editor/views/[component_detail, component_edit]

{.emit: """
window.generationProbe = {panels:0, documents:0, requests:[], restores:[]};
for (const key of Object.keys(window)) {
  if (typeof window[key] !== 'function') continue;
  const original = window[key];
  if (key.startsWith('populateComponentPropertyPanel__')) {
    window[key] = function(...args) { window.generationProbe.panels++; return original.apply(this,args); };
  } else if (key.startsWith('detailPreviewDocument__') || key.startsWith('componentEditPreviewDocument__')) {
    window[key] = function(...args) { window.generationProbe.documents++; return original.apply(this,args); };
  } else if (key.startsWith('restorePreviewSelection__')) {
    window[key] = function(...args) {
      const id = Array.isArray(args[2]) ? String.fromCharCode(...args[2]) : args[2];
      if (id) {
        const version = Number(args[1].srcdoc.match(/data-version=['"]([0-9]+)/)[1]);
        window.generationProbe.requests.push({version,id});
      }
      return original.apply(this,args);
    };
  }
}
""".}
createRoot proc(dispose: proc()) =
  let version = createSignal(0)
  let story = StoryRef(group: "Fixture", name: "Default", kind: skComponent)
  let vm = createEditorVM(newEditorWorkspace(
    title = "Document generations",
    storyGroups = @[StoryGroup(name: "Fixture", kind: skComponent,
      items: @[StoryItem(group: "Fixture", name: "Default", kind: skComponent)])],
    previewHook = proc(story: StoryRef; platform: Platform): ProjectPreview =
      ProjectPreview(status: ppsRendered, story: story,
        metadata: StoryRenderMetadata(story: story, sourceFile: "fixture.nim", sourceLine: 1),
        documentHtml: "<!doctype html><html><body data-version='" & $version.val &
          "'><button data-isonim-element-id='restore-target'>Selected target</button></body></html>")))
  discard vm.selectStory(story)
  let editSurface = $window.location.search == "?surface=edit"
  vm.editMode.val = emEdit
  vm.activeView.val = if editSurface: evComponentEdit else: evComponentDetail
  vm.inspector.selectedElement.val = ElementRef(id: "restore-target", tag: "button")
  let r = DomRenderer()
  let root = if editSurface: renderComponentEditView[DomRenderer, DomElement](r, vm)
    else: renderComponentDetail[DomRenderer, DomElement](r, vm)
  document.body.appendChild(root)
  let frame = root.querySelector("iframe")
  {.emit: ["""
  (function(frame) {
    frame.addEventListener('load', function() {
      const doc = frame.contentDocument;
      const original = frame.contentWindow.__isonimRestoreSelection;
      if (typeof original !== 'function') throw new Error('real selection bridge missing');
      frame.contentWindow.__isonimRestoreSelection = function(id) {
        window.generationProbe.restores.push({version:Number(doc.body.dataset.version),id});
        return original(id);
      };
    });
  })(""", frame, ");"].}
  let next = r.createElement("button")
  r.setAttribute(next, "id", "next-document")
  r.setTextContent(next, "Next document")
  r.addEventListener(next, "click", proc() = version.update(proc(previous: int): int = previous + 1))
  document.body.appendChild(next)
