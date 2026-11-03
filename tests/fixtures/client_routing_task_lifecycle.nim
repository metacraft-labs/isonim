## Complete actual task app lifecycle through the explicit private facade.
## Only observation/lifetime handles are exported; no component, model,
## scheduler, native method or ordinal operation is substituted.
import std/[json, jsffi]
import isonim/components/[task_app, branded_controls]
import isonim/core/[owner, signals, computation]
import isonim/web/[web_renderer, dom_api]

when defined(isonimInternalClientRouting) and not defined(taskLifecycleOrdinaryControl):
  type TaskRenderer = InternalClientRenderer
  # One explicit namespace exists before ANY app/leaf construction. Each open
  # copies this facade; delayed show/keyed closures retain the same context.
  let taskContext = newInternalClientCreationOrdinals()
  let sharedRenderer = newInternalClientRenderer(taskContext)
  proc queryTaskElement(element: Element): cstring =
    internalClientCreationOrdinal(taskContext, element)
else:
  type TaskRenderer = WebRenderer
  let sharedRenderer = WebRenderer()

proc openApp(id: cstring): JsObject =
  let r = sharedRenderer
  var store: TaskStore
  var root: Element
  var release: proc()
  var renders = 0
  createRoot(proc(dispose: proc()) =
    release = dispose
    store = createTaskStore()
    root = renderApp[TaskRenderer, Element](r, store)
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
  let r = sharedRenderer
  var root: Element
  var release: proc()
  var calls = 0
  var last = ""
  createRoot(proc(dispose: proc()) =
    release = dispose
    root = createInputRow[TaskRenderer, Element](r, "Controlled input",
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

when defined(isonimInternalClientRouting) and not defined(taskLifecycleOrdinaryControl):
  {.emit: ["globalThis.brandedTaskApp.query=", queryTaskElement, ";"].}
