## hydration_client.nim
##
## The browser side of the SSR -> hydrate -> interact round trip
## (hydration_app.nim; tests/browser/specs/ssr-hydration.spec.ts): builds the
## task manager with the `ui(r):` DSL over the web renderer and hands it to
## `hydrate`, which makes the renderer adopt the server-rendered elements
## instead of creating new ones. Built to www/hydrate.js by build_fixture.sh.
##
## The tree must be the server's, element for element (see
## hydration_app.nim). What differs is only how the dynamic parts update:
## the list is a `forEachKeyed` over task ids and "Clear completed" a `show`,
## both of which create their initial elements while `hydrate` runs, in
## document order, and so adopt them too.

when not defined(js):
  {.error: "hydration_client.nim requires the JS backend (nim js)".}

import isonim/web/[dom_api, web_renderer, hydration]
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import hydration_store

proc inputValue(el: Element): cstring {.importjs: "#.value".}
proc clearValue(el: Element) {.importjs: "#.value = ''".}
proc setChecked(el: Element; on: bool) {.importjs: "#.checked = #".}
proc preventDefault(ev: Event) {.importjs: "#.preventDefault()".}

proc taskItem(r: WebRenderer; store: TaskStore; id: int): Element =
  var checkbox: Element
  result = ui(r):
    li(class = (if store.task(id).done: "completed" else: "")):
      input(`type` = "checkbox", ref = checkbox,
            onclick = proc() = store.toggleTask(id))
      span: text store.task(id).text
      button(class = "remove", onclick = proc() = store.removeTask(id)):
        text "\xC3\x97"
  let cb = checkbox
  createRenderEffect proc() =
    cb.setChecked(store.task(id).done)

proc filterButton(r: WebRenderer; store: TaskStore; filter: Filter): Element =
  ui(r):
    button(class = (if store.filter.val == filter: "selected" else: ""),
           onclick = proc() = store.filter.val = filter):
      text $filter

proc taskApp(r: WebRenderer; store: TaskStore): Element =
  var list, footerEl, textInput: Element
  let visibleIds = proc(): seq[int] =
    for t in store.visibleTasks:
      result.add t.id
  ui(r):
    tdiv(class = "app"):
      header(class = "page-header"):
        h1: text "IsoNim Task Manager"
        p(class = "subtitle"):
          text "A reactive UI demo -- same code, server and client"
      section:
        header:
          h1: text "Task Manager"
          form(onsubmit = proc(ev: Event) =
                 ev.preventDefault()
                 store.addTask($textInput.inputValue)
                 textInput.clearValue()):
            input(`type` = "text", placeholder = "What needs to be done?",
                  ref = textInput)
            button(`type` = "submit"): text "Add"
        ul(class = "task-list", ref = list):
          block:
            forEachKeyed(r, list, visibleIds,
              proc(id: proc(): int; index: proc(): int): Element =
                taskItem(r, store, id()))
      footer(class = "task-footer", ref = footerEl):
        span: text store.countText
        tdiv(class = "filters"):
          for f in [fAll, fActive, fCompleted]:
            filterButton(r, store, f)
        block:
          show(r, footerEl,
            proc(): bool = store.completedCount > 0,
            proc(): Element =
              ui(r):
                button(class = "clear", onclick = proc() = store.clearCompleted()):
                  text "Clear completed")

let root = document.getElementById("root")
hydrate(proc(): Node = Node(taskApp(WebRenderer(), newSeededTaskStore())), root)
