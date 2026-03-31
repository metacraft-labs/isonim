## Rendering components for the IsoNim demo app.
## Uses MockRenderer for testing. Browser rendering is in main.nim.

import std/strutils
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/dsl/components
import task_store

proc renderTaskHeader*(renderer: MockRenderer; parent: MockNode; store: TaskStore) =
  ## Renders the task header with add-task form.
  let header = renderer.createElement("header")
  renderer.appendChild(parent, header)

  let h1 = renderer.createElement("h1")
  let h1Text = renderer.createTextNode("Task Manager")
  renderer.appendChild(h1, h1Text)
  renderer.appendChild(header, h1)

  let form = renderer.createElement("form")
  renderer.appendChild(header, form)

  let input = renderer.createElement("input")
  renderer.setAttribute(input, "type", "text")
  renderer.setAttribute(input, "placeholder", "What needs to be done?")
  renderer.appendChild(form, input)

  let btn = renderer.createElement("button")
  renderer.setAttribute(btn, "type", "submit")
  let btnText = renderer.createTextNode("Add")
  renderer.appendChild(btn, btnText)
  renderer.appendChild(form, btn)

proc renderTaskList*(renderer: MockRenderer; parent: MockNode; store: TaskStore) =
  ## Renders the task list with conditional rendering and keyed list.
  let section = renderer.createElement("section")
  renderer.appendChild(parent, section)

  show(renderer, section,
    proc(): bool = store.filteredTasks.val.len > 0,
    proc(): MockNode =
      let ul = renderer.createElement("ul")
      renderer.setAttribute(ul, "class", "task-list")
      forEachKeyed[Task](renderer, ul,
        proc(): seq[Task] = store.filteredTasks.val,
        proc(item: proc(): Task, index: proc(): int): MockNode =
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

          let removeBtn = renderer.createElement("button")
          renderer.setAttribute(removeBtn, "class", "remove")
          renderer.setTextContent(removeBtn, "x")
          renderer.addEventListener(removeBtn, "click", proc() =
            store.removeTask(item().id)
          )
          renderer.appendChild(li, removeBtn)
          li
      )
      ul
    ,
    proc(): MockNode =
      let p = renderer.createElement("p")
      renderer.setAttribute(p, "class", "empty")
      let txt = renderer.createTextNode("No tasks")
      renderer.appendChild(p, txt)
      p
  )

proc renderTaskFooter*(renderer: MockRenderer; parent: MockNode; store: TaskStore) =
  ## Renders the task footer with filter buttons and counts.
  show(renderer, parent,
    proc(): bool = store.tasks.val.len > 0,
    proc(): MockNode =
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
        proc(): MockNode =
          let clearBtn = renderer.createElement("button")
          renderer.setTextContent(clearBtn, "Clear completed")
          renderer.addEventListener(clearBtn, "click", proc() =
            store.clearCompleted()
          )
          clearBtn
      )
      footer
  )

proc renderEffectLog*(renderer: MockRenderer; parent: MockNode; store: TaskStore) =
  ## Renders the effect log display.
  show(renderer, parent,
    proc(): bool = store.log.val.len > 0,
    proc(): MockNode =
      let details = renderer.createElement("details")
      renderer.setAttribute(details, "class", "effect-log")

      let summary = renderer.createElement("summary")
      createRenderEffect proc() =
        renderer.setTextContent(summary, "Effect log (" & $store.log.val.len & " entries)")
      renderer.appendChild(details, summary)

      let ul = renderer.createElement("ul")
      forEachKeyed[string](renderer, ul,
        proc(): seq[string] = store.log.val,
        proc(item: proc(): string, index: proc(): int): MockNode =
          let li = renderer.createElement("li")
          createRenderEffect proc() =
            renderer.setTextContent(li, item())
          li
      )
      renderer.appendChild(details, ul)
      details
  )
