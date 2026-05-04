## Browser runtime helpers for embedding the IsoNim Editor.
##
## Project entry points can import this module, construct an EditorWorkspace,
## and mount it into any DOM element.

when not defined(js):
  {.error: "isonim/editor/browser must be compiled with `nim js`".}

import std/[dom, strutils]

import isonim/core/[computation, owner, signals]
import isonim/editor/dom_renderer
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/workspace
import isonim/editor/views/shell

proc injectEditorStyles*() =
  ## Inject base responsive styles required by the editor shell.
  let style = document.createElement("style")
  style.textContent = cstring"""
    .editor-tabbar::-webkit-scrollbar { display: none; }
    @media (max-width: 768px) {
      .editor-sidebar { width: 100% !important; min-width: 100% !important; }
      .editor-preview { display: none !important; }
      .editor-inspector { display: none !important; }
      .editor-chat { display: none !important; }
      .editor-mobile-toggle { display: flex !important; }
    }
    .editor-mobile-toggle { display: none; }
    @media (max-width: 1024px) and (min-width: 769px) {
      .editor-sidebar { width: 220px !important; min-width: 220px !important; }
      .editor-inspector { width: 260px !important; min-width: 260px !important; }
      .editor-tabbar > div { padding: 0 6px !important; font-size: 10px !important; }
    }
    .editor-input::placeholder { color: #475569; }
    .editor-input:focus { border-color: #3B82F6 !important; }
  """
  document.head.appendChild(style)

proc hashEditorView*(): EditorView =
  ## Read URL hash to choose an initial screenshot/deep-link view.
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "component-detail" in h:
    evComponentDetail
  elif "component-edit" in h:
    evComponentEdit
  elif "page-preview" in h:
    evPagePreview
  elif "vector-editor" in h:
    evVectorEditor
  else:
    evStoryboard

proc hasEditorRouteOverride*(): bool =
  ## Only override workspace initial state when the URL explicitly asks for a
  ## view. A bare mount should honor the consumer workspace defaults.
  var hash: cstring
  var search: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  {.emit: [search, " = window.location.search || ''"].}
  ($hash).len > 0 or "view=" in $search

proc hashInspectorSection*(): InspectorSection =
  ## Read URL hash for inspector section deep links.
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "layout" in h:
    isLayout
  elif "fill" in h:
    isFill
  elif "effects" in h:
    isEffects
  elif "stroke" in h:
    isStroke
  elif "transitions" in h:
    isTransitions
  else:
    isSpacing

proc mountEditor*(workspace: EditorWorkspace;
                  root: Element = document.body;
                  useHashRoute = true;
                  injectStyles = true): EditorVM =
  ## Mount the editor shell into a DOM element and return the live VM.
  ##
  ## The returned VM is useful for tests and host-app integrations that need to
  ## drive the editor after mount.
  if injectStyles:
    injectEditorStyles()

  var mounted: EditorVM
  createRoot proc(dispose: proc()) =
    let vm = createEditorVM(workspace)
    mounted = vm
    if useHashRoute and hasEditorRouteOverride():
      vm.activeView.val = hashEditorView()
      vm.inspector.activeSection.val = hashInspectorSection()

    let r = DomRenderer()
    let shell = renderEditorShell[DomRenderer, DomElement](r, vm)
    {.emit: [shell, ".style.position='fixed'"].}
    {.emit: [shell, ".style.inset='0'"].}
    {.emit: [shell, ".style.overflow='hidden'"].}
    root.appendChild(shell)
  mounted
