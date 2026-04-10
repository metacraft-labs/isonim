## IsoNim Editor — browser entry point.
## Compiles to JS via `nim js`, renders the editor shell into the DOM.

when not defined(js):
  {.error: "The editor must be compiled with `nim js`".}

import std/dom
import isonim/core/[signals, computation, owner]
import isonim/editor/dom_renderer
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/stories
import isonim/editor/views/shell

proc main() =
  createRoot proc(dispose: proc()) =
    let vm = createEditorVM()
    vm.sidebar.groups.val = buildStoryboard()

    let r = DomRenderer()
    let shell = renderEditorShell[DomRenderer, DomElement](r, vm)

    # Full viewport
    {.emit: [shell, ".style.position='fixed'"].}
    {.emit: [shell, ".style.inset='0'"].}
    {.emit: [shell, ".style.overflow='hidden'"].}

    document.body.appendChild(shell)

main()
