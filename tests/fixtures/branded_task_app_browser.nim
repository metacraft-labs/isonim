## Real production task app and input leaf; only test observation/lifetime handles
## are exposed. No component, renderer, model action or scheduler is replaced.
import std/[json, jsffi]
import isonim/components/[task_app, branded_controls]
import isonim/core/[owner, signals, computation]
import isonim/web/[web_renderer, dom_api]

proc openApp(id: cstring): JsObject =
  let r = WebRenderer()
  var store: TaskStore
  var root: Element
  var release: proc()
  var renders = 0
  createRoot(proc(dispose: proc()) =
    release = dispose
    store = createTaskStore()
    root = renderApp[WebRenderer, Element](r, store)
    r.setAttribute(root, "id", $id)
    createRenderEffect(proc() =
      discard store.tasks.val
      inc renders
    )
  )
  proc snapshot(): cstring = cstring($(%store.tasks.val))
  proc addRetainedTask(text: cstring) = store.addTask($text)
  proc count(): int = renders
  {.emit: ["document.body.appendChild(", root, ");"].}
  let snapshotFn = snapshot
  let addFn = addRetainedTask
  let countFn = count
  {.emit: [result, " = {root:", root, ",dispose:", release,
    ",snapshot:", snapshotFn, ",add:", addFn, ",renders:", countFn, "};"].}

proc throwLeafError() {.importjs: "(function(){throw globalThis.brandedLeafError;})()".}
proc openLeaf(fail: bool): JsObject =
  let r = WebRenderer()
  var root: Element
  var release: proc()
  var calls = 0
  var last = ""
  createRoot(proc(dispose: proc()) =
    release = dispose
    root = createInputRow[WebRenderer, Element](r, "Controlled input",
      proc(text: string) =
        inc calls
        last = text
        if fail: throwLeafError()
    )
  )
  proc count(): int = calls
  proc submitted(): cstring = cstring(last)
  {.emit: ["document.body.appendChild(", root, ");"].}
  let countFn = count
  let submittedFn = submitted
  {.emit: [result, " = {root:", root, ",dispose:", release,
    ",calls:", countFn, ",last:", submittedFn, "};"].}

{.emit: ["globalThis.brandedTaskApp = {open:", openApp, ",leaf:", openLeaf, "};"].}
