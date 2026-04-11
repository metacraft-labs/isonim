## IsoNim Editor — browser entry point.
## Compiles to JS via `nim js`, renders the editor shell into the DOM.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import std/[dom, strutils]
import isonim/core/[signals, computation, owner]
import isonim/editor/dom_renderer
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/stories
import isonim/editor/views/shell

proc injectResponsiveStyles() =
  ## Inject a <style> tag with responsive breakpoints for mobile layout.
  let style = document.createElement("style")
  style.textContent = cstring"""
    /* Hide scrollbars on tab bars */
    .editor-tabbar::-webkit-scrollbar { display: none; }
    /* Mobile: show only sidebar, hide preview + inspector */
    @media (max-width: 768px) {
      .editor-sidebar { width: 100% !important; min-width: 100% !important; }
      .editor-preview { display: none !important; }
      .editor-inspector { display: none !important; }
      .editor-mobile-toggle { display: flex !important; }
    }
    .editor-mobile-toggle { display: none; }
    /* Tablet: shrink inspector */
    @media (max-width: 1024px) and (min-width: 769px) {
      .editor-sidebar { width: 220px !important; min-width: 220px !important; }
      .editor-inspector { width: 260px !important; min-width: 260px !important; }
      .editor-tabbar > div { padding: 0 6px !important; font-size: 10px !important; }
    }
    /* Placeholder input styling */
    .editor-input::placeholder { color: #475569; }
    .editor-input:focus { border-color: #3B82F6 !important; }
  """
  document.head.appendChild(style)

import isonim/editor/types

proc getHashView(): EditorView =
  ## Read URL hash to determine initial view for screenshot navigation.
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "component-detail" in h: evComponentDetail
  elif "component-edit" in h: evComponentEdit
  elif "vector-editor" in h: evVectorEditor
  else: evStoryboard

proc getHashInspectorSection(): InspectorSection =
  ## Read URL hash for inspector section. E.g., #component-edit-fill
  var hash: cstring
  {.emit: [hash, " = window.location.hash || ''"].}
  let h = $hash
  if "layout" in h: isLayout
  elif "fill" in h: isFill
  elif "effects" in h: isEffects
  elif "stroke" in h: isStroke
  elif "transitions" in h: isTransitions
  else: isSpacing  # default

proc main() =
  injectResponsiveStyles()
  createRoot proc(dispose: proc()) =
    let vm = createEditorVM()
    vm.sidebar.groups.val = buildStoryboard()
    vm.activeView.val = getHashView()
    vm.inspector.activeSection.val = getHashInspectorSection()

    let r = DomRenderer()
    let shell = renderEditorShell[DomRenderer, DomElement](r, vm)

    # Full viewport
    {.emit: [shell, ".style.position='fixed'"].}
    {.emit: [shell, ".style.inset='0'"].}
    {.emit: [shell, ".style.overflow='hidden'"].}

    document.body.appendChild(shell)

main()
