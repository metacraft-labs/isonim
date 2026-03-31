## Terminal counter demo for IsoNim.
##
## Demonstrates that the reactive core works with a terminal renderer,
## proving GUI-agnostic architecture.

import isonim/renderers/terminal
import isonim/rxcore
import isonim/core/computation

proc createCounter*[R, N](renderer: R): N =
  ## Creates a counter component using any renderer backend.
  var count = createSignal(0)

  let container = renderer.createElement("div")
  let label = renderer.createTextNode("")
  let incBtn = renderer.createElement("button")
  let decBtn = renderer.createElement("button")

  renderer.appendChild(incBtn, renderer.createTextNode("+"))
  renderer.appendChild(decBtn, renderer.createTextNode("-"))
  renderer.appendChild(container, label)
  renderer.appendChild(container, incBtn)
  renderer.appendChild(container, decBtn)

  renderer.addEventListener(incBtn, "click", proc() = count.val = count.val + 1)
  renderer.addEventListener(decBtn, "click", proc() = count.val = count.val - 1)

  createRenderEffect proc() =
    renderer.setTextContent(label, "Count: " & $count.val)

  return container

proc main() =
  let r = TerminalRenderer()
  root proc(dispose: proc()) =
    let app = createCounter[TerminalRenderer, TerminalNode](r)
    echo "=== Initial state ==="
    echo renderToText(app)

    # Simulate increment clicks
    let incBtn = app.children[1]  # label, incBtn, decBtn
    incBtn.fireEvent("click")
    echo "=== After increment ==="
    echo renderToText(app)

    incBtn.fireEvent("click")
    echo "=== After second increment ==="
    echo renderToText(app)

    # Simulate decrement
    let decBtn = app.children[2]
    decBtn.fireEvent("click")
    echo "=== After decrement ==="
    echo renderToText(app)

    dispose()

main()
