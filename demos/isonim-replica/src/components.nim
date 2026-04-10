## Rendering components for the IsoNim demo app.
## Uses ui macro for element creation, generic control flow components.
## Works with any RendererBackend (MockRenderer for tests, browser DOM for web).

import isonim/core/[signals, computation]
import isonim/testing/mock_dom
import isonim/dsl/[html, components]
import task_store

proc renderTaskHeader*[R, N](renderer: R; parent: N; store: TaskStore) =
  ## Renders the task header with add-task form.
  let header = ui(renderer):
    header:
      h1: text "Task Manager"
      form:
        input(ttype = "text", placeholder = "What needs to be done?")
        button(ttype = "submit"):
          text "Add"
  renderer.appendChild(parent, header)

proc renderTaskItem[R, N](renderer: R; parent: N; store: TaskStore;
    item: proc(): Task; index: proc(): int) =
  ## Renders a single task list item with reactive class, text, and handlers.
  let li = renderer.createElement("li")
  createRenderEffect proc() =
    let t = item()
    if t.done:
      renderer.setAttribute(li, "class", "completed")
    else:
      renderer.setAttribute(li, "class", "")

  let checkbox = ui(renderer):
    input(ttype = "checkbox", onchange = proc() = store.toggleTask(item().id))
  renderer.appendChild(li, checkbox)

  let span = renderer.createElement("span")
  createRenderEffect proc() =
    renderer.setTextContent(span, item().text)
  renderer.addEventListener(span, "click", proc() =
    store.setSelectedId(item().id)
  )
  renderer.appendChild(li, span)

  let removeBtn = ui(renderer):
    button(class = "remove", onclick = proc() = store.removeTask(item().id)):
      text "x"
  renderer.appendChild(li, removeBtn)

  renderer.appendChild(parent, li)

proc renderTaskList*[R, N](renderer: R; parent: N; store: TaskStore) =
  ## Renders the task list with conditional rendering and keyed list.
  let section = renderer.createElement("section")
  renderer.appendChild(parent, section)

  show(renderer, section,
    proc(): bool = store.filteredTasks.val.len > 0,
    proc(): N =
      let ul = renderer.createElement("ul")
      renderer.setAttribute(ul, "class", "task-list")
      forEachKeyed(renderer, ul,
        proc(): seq[Task] = store.filteredTasks.val,
        proc(item: proc(): Task, index: proc(): int): N =
          let li = renderer.createElement("li")
          createRenderEffect proc() =
            let t = item()
            if t.done:
              renderer.setAttribute(li, "class", "completed")
            else:
              renderer.setAttribute(li, "class", "")
          let checkbox = renderer.createElement("input")
          renderer.setAttribute(checkbox, "type", "checkbox")
          renderer.addEventListener(checkbox, "change", proc() =
            store.toggleTask(item().id)
          )
          renderer.appendChild(li, checkbox)

          let span = renderer.createElement("span")
          createRenderEffect proc() =
            renderer.setTextContent(span, item().text)
          renderer.addEventListener(span, "click", proc() =
            store.setSelectedId(item().id)
          )
          renderer.appendChild(li, span)

          let removeBtn = ui(renderer):
            button(class = "remove", onclick = proc() = store.removeTask(item().id)):
              text "x"
          renderer.appendChild(li, removeBtn)
          li
      )
      ul
    ,
    proc(): N =
      ui(renderer):
        p(class = "empty"):
          text "No tasks"
  )

proc renderTaskFooter*[R, N](renderer: R; parent: N; store: TaskStore) =
  ## Renders the task footer with filter buttons and counts.
  show(renderer, parent,
    proc(): bool = store.tasks.val.len > 0,
    proc(): N =
      let footer = renderer.createElement("footer")
      renderer.setAttribute(footer, "class", "task-footer")

      let countSpan = renderer.createElement("span")
      createRenderEffect proc() =
        let ac = store.activeCount.val
        let suffix = if ac != 1: "s" else: ""
        renderer.setTextContent(countSpan, $ac & " item" & suffix & " left")
      renderer.appendChild(footer, countSpan)

      let filters = renderer.createElement("div")
      renderer.setAttribute(filters, "class", "filters")
      for f in [fAll, fActive, fCompleted]:
        let filterVal = f
        let btn = renderer.createElement("button")
        renderer.setTextContent(btn, $filterVal)
        createRenderEffect proc() =
          if store.filter.val == filterVal:
            renderer.setAttribute(btn, "class", "selected")
          else:
            renderer.setAttribute(btn, "class", "")
        renderer.addEventListener(btn, "click", proc() =
          store.setFilter(filterVal)
        )
        renderer.appendChild(filters, btn)
      renderer.appendChild(footer, filters)

      # Clear completed button
      show(renderer, footer,
        proc(): bool = store.completedCount.val > 0,
        proc(): N =
          ui(renderer):
            button(onclick = proc() = store.clearCompleted()):
              text "Clear completed"
      )
      footer
  )

proc renderEffectLog*[R, N](renderer: R; parent: N; store: TaskStore) =
  ## Renders the effect log display.
  show(renderer, parent,
    proc(): bool = store.log.val.len > 0,
    proc(): N =
      let details = renderer.createElement("details")
      renderer.setAttribute(details, "class", "effect-log")

      let summary = renderer.createElement("summary")
      createRenderEffect proc() =
        renderer.setTextContent(summary, "Effect log (" & $store.log.val.len & " entries)")
      renderer.appendChild(details, summary)

      let ul = renderer.createElement("ul")
      forEachKeyed(renderer, ul,
        proc(): seq[string] = store.log.val,
        proc(item: proc(): string, index: proc(): int): N =
          let li = renderer.createElement("li")
          createRenderEffect proc() =
            renderer.setTextContent(li, item())
          li
      )
      renderer.appendChild(details, ul)
      details
  )
