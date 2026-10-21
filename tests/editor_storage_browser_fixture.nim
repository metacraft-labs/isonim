## Actual editor VM and Real storage backend. The browser harness injects denied
## browser APIs to exercise the prior optional-persistence failure behavior.
import std/dom
import isonim/core/[nondet, signals, owner, computation]
import isonim/editor/[viewmodels, types, dom_renderer]
import isonim/editor/views/shell

install(newRealBackend(1))
createRoot proc(dispose: proc()) =
  let vm = createEditorVM()
  doAssert not vm.aiDrawerOpen.val
  hydrateInspectorExpansionFromStorage(vm)
  let panel = renderInspectorPanel[DomRenderer, DomElement](DomRenderer(), vm)
  document.body.appendChild(panel)
  vm.inspector.expandedSections.val = @[isLayout, isFill]
  vm.aiDrawerOpen.val = true
  vm.aiDrawerOpen.val = false
  dispose()
{.emit: "globalThis.__isonimStorageTestOK = true;".}
