## hydration_app.nim
##
## The server side of the SSR -> hydrate -> interact round trip
## (tests/browser/specs/ssr-hydration.spec.ts, milestone IFP-M3): a task
## manager rendered with the `ui:` DSL inside the ngx-isonim module, in both
## SSR modes, and hydrated in the browser by hydration_client.nim.
##
## * `hydration`: a string renderer (`ui:` inside `renderToString`), at
##   `/ssr.html`;
## * `hydration-stream`: a streaming renderer (`uiWrite` straight into the
##   response body, inside `withHydrationKeys`), at `/ssr-stream.html`.
##
## Both write the same markup (`serverMarkup` below), and the module appends
## the `_$HY` bootstrap (`isonim_ssr_hydration`, on by default). The client
## (www/hydrate.js) is loaded with `defer`, so it runs after the bootstrap.
##
## The markup must be the one hydration_client.nim builds, element for
## element: the client adopts the n-th server element as its n-th
## `createElement` (IsoNim.md § Hydration). The two are written separately
## because the client's list and its "Clear completed" button are reactive
## (`forEachKeyed`, `show`) where the server's are a `for` and an `if`.

import std/macros
from app_registry import registerApp, registerStreamingApp, SsrRequest,
  SsrResponse, ResponseBody, write
import isonim/core/[owner, signals]
import isonim/ssr/[renderer, markers, escape]
import isonim/dsl/ui
import hydration_store

template serverMarkupBody() {.dirty.} =
  tdiv(class = "app"):
    header(class = "page-header"):
      h1: text "IsoNim Task Manager"
      p(class = "subtitle"):
        text "A reactive UI demo -- same code, server and client"
    section:
      header:
        h1: text "Task Manager"
        form:
          input(`type` = "text", placeholder = "What needs to be done?")
          button(`type` = "submit"): text "Add"
      ul(class = "task-list"):
        for t in store.visibleTasks:
          li(class = (if t.done: "completed" else: "")):
            if t.done:
              input(`type` = "checkbox", checked = "")
            else:
              input(`type` = "checkbox")
            span: text t.text
            button(class = "remove"): text "\xC3\x97"
    footer(class = "task-footer"):
      span: text store.countText
      tdiv(class = "filters"):
        for f in [fAll, fActive, fCompleted]:
          button(class = (if store.filter.val == f: "selected" else: "")):
            text $f
      if store.completedCount > 0:
        button(class = "clear"): text "Clear completed"

macro serverMarkup(call: untyped): untyped =
  ## `call` (`ui` or `uiWrite(stream)`) applied to the shared markup.
  result = if call.kind == nnkCall: copyNimTree(call) else: newCall(call)
  result.add getAst(serverMarkupBody())

const
  pageHead = "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">" &
    "<title>IsoNim SSR Hydration Test</title>" &
    "<script defer src=\"/static/hydrate.js\"></script></head><body>" &
    "<div id=\"root\">"
  pageTail = "</div></body></html>"

proc renderString(req: SsrRequest; resp: SsrResponse): string =
  let html = renderToString(proc(): string =
    let store = newSeededTaskStore()
    serverMarkup(ui))
  pageHead & html & pageTail

proc renderStream(req: SsrRequest; resp: SsrResponse; body: ResponseBody) =
  body.write(pageHead)
  withHydrationKeys(""):
    createRoot proc(dispose: proc()) =
      let store = newSeededTaskStore()
      serverMarkup(uiWrite(body))
      dispose()
  body.write(pageTail)

proc registerHydrationApps*() =
  registerApp("hydration", renderString)
  registerStreamingApp("hydration-stream", renderStream)
