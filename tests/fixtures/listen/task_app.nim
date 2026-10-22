## Real shared SSR/client task controls; browser tests use HTTP and Chromium.
import isonim/dsl/ui
import isonim/rxcore
when defined(js):
  import std/jsffi
  import isonim/web/[web_renderer, dom_api, hydration]
  import isonim/core/nondet
  import ./raw_component
  import isonim/dsl/stable_ids
  import isonim/routing/[router, navigate, match]
  proc called(ev: Event) =
    {.emit: "globalThis.callOrder.push({type:`ev`.type,iid:`ev`.currentTarget.getAttribute('data-iid')});".}
    {.emit: "globalThis.handlerCalls.push({type: `ev`.type, iid: `ev`.currentTarget.getAttribute('data-iid'), value: `ev`.target.value, textContent: `ev`.target.textContent, checked: `ev`.target.checked, key: `ev`.key, current: `ev`.currentTarget.id, target: `ev`.target.id});".}
    if ev.`type` == cstring"submit":
      {.emit: "`ev`.preventDefault();".}
  proc plain() =
    {.emit: "globalThis.plainCalls++;".}
    {.emit: "globalThis.callOrder.push({type:'click',iid:document.getElementById('plain').getAttribute('data-iid')});".}
else:
  import isonim/ssr/[renderer, escape, markers]

proc taskApp(r: auto): auto =
  isomorphicUi(r):
    tdiv(id = "tasks"):
      form(id = "task-form", onsubmit = called):
        input(id = "secret", oninput = called, onchange = called, onkeydown = called)
        input(id = "verbatim", record = true, oninput = called)
        input(id = "explicit-false", record = false, oninput = called)
        input(id = "password", `type` = "password", oninput = called)
        input(id = "check", `type` = "checkbox", onclick = called, onchange = called)
        textarea(id = "notes", oninput = called)
        tdiv(id = "editable", contenteditable = "true", oninput = called)
        tdiv(id = "opt-in-parent", record = true):
          input(id = "private-child", oninput = called)
        button(id = "submit", `type` = "submit", onclick = called): text "Add task"
      button(id = "plain", onclick = plain): text "Plain"
      button(id = "multi"): text "Multiple"
      button(id = "nested"): text "Nested"
      button(id = "raw"): text "Raw negative control"
      tdiv(id = "link-host")

when defined(js):
  {.emit: "globalThis.handlerCalls=[]; globalThis.plainCalls=0; globalThis.records=[]; globalThis.special=[]; globalThis.callOrder=[];".}
  setListenerHook(proc(record: JsObject) =
    {.emit: "globalThis.records.push(`record`);".})
  let r = WebRenderer()
  var disposeApp: proc()
  proc mountApp() =
    createRoot proc(dispose: proc()) =
      disposeApp = dispose
      hydrate(proc(): Node = Node(taskApp(r)), document.getElementById("root"))
      discard createRouter(@[RouteEntry(pattern: parsePattern("/"), component: proc() = discard), RouteEntry(pattern: parsePattern("/next"), component: proc() = discard)])
      Link(Node(document.getElementById("link-host")), "/next", "Next")
      proc linked(): Element =
        let host = ui(r): tdiv()
        Link(Node(host), "/next", "Scoped")
        host
      let scopedLinks = ui(r):
        tdiv(id = "scoped-links"):
          linked()
          linked()
      discard Node(document.getElementById("root")).appendChild(scopedLinks)
      let keyedLinks = ui(r): tdiv(id = "keyed-links")
      withStableKey("first"):
        Link(Node(keyedLinks), "/next", "First")
      withStableKey("second"):
        Link(Node(keyedLinks), "/next", "Second")
      discard Node(document.getElementById("root")).appendChild(keyedLinks)
      let multi = document.getElementById("multi")
      let nested = document.getElementById("nested")
      let special: EventHandler = proc(ev: Event) =
        {.emit: "globalThis.special.push(`ev`.currentTarget.id);".}
        {.emit: "globalThis.callOrder.push({type:`ev`.type,iid:`ev`.currentTarget.getAttribute('data-iid')});".}
      r.addEventListener(multi, "click", special)
      r.addEventListener(multi, "click", special) # native callback dedup
      r.addEventListener(multi, "click", proc(ev: Event) =
        special(ev)
        {.emit: "document.getElementById('nested').click(); `ev`.preventDefault();".})
      r.addEventListener(nested, "click", special)
      proc raw(ev: Event) =
        {.emit: "globalThis.rawCalls=(globalThis.rawCalls||0)+1;".}
      rawRegister(document.getElementById("raw"), raw)
  proc register(node: JsObject; event: cstring; cb: EventHandler; capture: bool): ListenerDisposer =
    nondet.listen(node, $event, cb, capture)
  proc registerOwned(node: JsObject; event: cstring; cb: EventHandler): ListenerDisposer =
    var release: ListenerDisposer
    createRoot proc(dispose: proc()) =
      release = dispose
      discard nondet.listen(node, $event, cb)
    release
  proc testClock() = install(newTestBackend(123))
  proc observe(hook: proc(record: JsObject)) = setListenerHook(hook)
  {.emit: "globalThis.observeListeners=`observe`;".}
  {.emit: "globalThis.registerOwnedListener=`registerOwned`; globalThis.registerListener=`register`; globalThis.selectTestClock=`testClock`;".}
  proc start() = mountApp()
  proc dispose() = disposeApp()
  {.emit: "globalThis.startApp=`start`; globalThis.disposeApp=`dispose`;".}
else:
  echo "<!doctype html><body><main id='root'>"
  echo renderToString(proc(): string = taskApp(0))
  echo "</main>"
  echo generateHydrationScript(recordingHydrationEvents)
