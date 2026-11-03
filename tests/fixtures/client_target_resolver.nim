## Complete actual task app lifecycle through the explicit private facade.
## Only observation/lifetime handles are exported; no component, model,
## scheduler, native method or ordinal operation is substituted.
import std/[json, jsffi]
import isonim/components/[task_app, branded_controls]
import isonim/core/[owner, signals, computation]
import isonim/web/[web_renderer, dom_api, hydration]
import isonim/dsl/[stable_ids, ui]

when defined(isonimInternalClientRouting) and not defined(taskLifecycleOrdinaryControl):
  type TaskRenderer = InternalClientRenderer
  # One explicit namespace exists before ANY app/leaf construction. Each open
  # copies this facade; delayed show/keyed closures retain the same context.
  let taskContext = newInternalClientTargetContext()
  let sharedRenderer = newInternalClientTargetRenderer(taskContext)
  proc queryTaskElement(element: Element): cstring =
    internalClientTargetOrdinal(taskContext, element)
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
    withStableInstance($id):
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

when not defined(taskLifecycleOrdinaryControl):
  proc targetContext(): InternalClientTargetContext = newInternalClientTargetContext()
  proc targetCreate(c: InternalClientTargetContext; tag: cstring): Element =
    newInternalClientTargetRenderer(c).createElement($tag)
  proc targetResolve(c: InternalClientTargetContext; token: cstring): JsObject =
    resolveInternalClientTarget(c, token)
  proc targetQuery(c: InternalClientTargetContext; element: Element): cstring =
    internalClientTargetOrdinal(c, element)
  proc targetText(text: cstring): Node = WebRenderer().createTextNode($text)
  proc targetHydrate(c: InternalClientTargetContext; root: Element; tag: cstring): Element =
    hydrate(proc(): Node =
      result = Node(newInternalClientTargetRenderer(c).createElement($tag))
      {.emit: ["globalThis.targetAdopted=", result, ";"].}, root)
    {.emit: [result, "=globalThis.targetAdopted;"].}
  proc targetStamp(e: Element; iid: cstring) =
    when defined(isonimStableIds): noteElement(e, $iid)
  {.emit: """
globalThis.ctTarget={context:`targetContext`, create:`targetCreate`,
 resolve:`targetResolve`,query:`targetQuery`,text:`targetText`,
 hydrate:`targetHydrate`,stamp:`targetStamp`,taskContext:`taskContext`};
""".}

when not defined(taskLifecycleOrdinaryControl):
  proc targetInvalidDefault(): Element =
    default(InternalClientRenderer).createElement("div")
  proc targetMismatchedLink(): Element =
    let context = newInternalClientTargetContext()
    var r = newInternalClientTargetRenderer(context)
    # Explicit test-only field inspection constructs invalid trusted linkage.
    {.emit: [r, ".context = ", newInternalClientCreationOrdinals(), ";"].}
    r.createElement("div")
  proc targetOldCreate(): Element =
    newInternalClientRenderer(newInternalClientCreationOrdinals()).createElement("div")
  {.emit: """
Object.assign(ctTarget,{invalidDefault:`targetInvalidDefault`,
 mismatched:`targetMismatchedLink`,oldCreate:`targetOldCreate`});
""".}

when defined(targetAdmissionUnknownOwner):
  # Deliberately UNADMITTED artifact: prove that adding the legitimate new
  # projection owner did not admit an unrelated compiled native creator.
  proc unknownTargetCreator(): Element = document.createElement(cstring"div")
  discard unknownTargetCreator()

when not defined(taskLifecycleOrdinaryControl):
  proc targetMeter(enabled: bool) =
    meterEnabled = enabled
    meterCodec = false
    when defined(isonimNoBoundaryMeter): meter = default(BoundaryMeter)
    else: resetMeter()
  proc targetCount(): int = meter.ops[boCreateElement]
  proc targetHandler(c: InternalClientTargetContext; e: Element) =
    newInternalClientTargetRenderer(c).addEventListener(e, "click", proc() = discard)
  {.emit: """Object.assign(ctTarget,{meter:`targetMeter`,count:`targetCount`,handler:`targetHandler`});""".}

when not defined(taskLifecycleOrdinaryControl):
  # The unchanged branded component uses imperative inputs/handler attachment,
  # so its elements route through ordinals. Compose a REAL DSL interactive leaf
  # beside it to bind generated M6 identity to the SAME target namespace.
  var composedDslCalls = 0
  proc composedClicked() = inc composedDslCalls
  proc composedDslControl(): Element =
    ui(sharedRenderer):
      button(onclick = composedClicked): text "Resolver DSL control"
  proc composedDslCount(): int = composedDslCalls
  {.emit: """Object.assign(ctTarget,{dslControl:`composedDslControl`,dslCalls:`composedDslCount`});""".}
