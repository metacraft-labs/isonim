## Shared task fixture: real SSR and browser DOM, no substitute renderer.
import isonim/dsl/ui
when defined(js):
  import isonim/web/[web_renderer, dom_api, hydration]
else:
  import isonim/ssr/[renderer, escape, markers]

var calls = 0
proc clicked() = inc calls
proc rawHandler(onclick: string) = discard

proc taskApp(r: auto): auto =
  isomorphicUi(r):
    tdiv(class = "task-app"):
      h1: text "Tasks"
      form(onsubmit = proc() =
        clicked()
        rawHandler(onclick = "handler-only")):
        input(key = "task-input", placeholder = "Add a task")
        button(key = "add", onclick = clicked): text "Add"
      ul:
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 0"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 1"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 2"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 3"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 4"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 5"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 6"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 7"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 8"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 9"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 10"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 11"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 12"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 13"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 14"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 15"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 16"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 17"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 18"
        li:
          input(`type` = "checkbox", onclick = clicked)
          button(onclick = clicked): text "Task 19"
      button(key = "fixed", onclick = clicked): text "Clear completed"

when defined(js):
  proc inspect() {.importjs: "globalThis.iidClaims = [...document.querySelectorAll('[data-iid]')].map(el=>({iid:el.getAttribute('data-iid'),same:globalThis.__isonimIids.get(el.getAttribute('data-iid')).deref()===el}));".}
  let mount = document.getElementById("root")
  hydrate(proc(): Node = Node(taskApp(WebRenderer())), mount)
  when defined(isonimStableIds): inspect()
else:
  echo renderToString(proc(): string = taskApp(0))
  echo generateHydrationScript()
