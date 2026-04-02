## Hydration entry point for SSR E2E tests.
##
## Compiled as JS target, loaded by the SSR HTML page.
## Hydrates the server-rendered DOM and makes it interactive.
##
## The DOM structure here MUST match renderFullPageSsr() in shared_components:
##   div.app
##     header.page-header > h1 + p.subtitle
##     section > header > (h1 + form) + ul.task-list
##     footer.task-footer > span + div.filters + button?

when not defined(js):
  {.error: "hydrate_entry.nim requires the JS backend (nim js)".}

import isonim/web/dom_api
import isonim/web/hydration
import isonim/web/events
import isonim/rxcore
import isonim/core/[signals, computation]
import task_store

# Delegate the same events used in the SSR hydration script
delegateEvents(["click", "input", "change", "submit"])

proc createApp(): Node =
  ## Rebuilds the app component tree for hydration.
  ## During hydration, getNextElement reuses existing DOM nodes
  ## instead of creating new ones.
  let store = createTaskStore()
  provideTaskStore(store)

  # Seed the store with the same data as the SSR generator
  store.addTask("Buy groceries")
  store.addTask("Write tests")
  store.addTask("Deploy app")
  # Mark the third task as completed (same as SSR)
  let tasks = store.tasks.val
  store.toggleTask(tasks[2].id)

  # App container
  let appDiv = document.createElement("div")
  appDiv.className = "app"

  # ---- Page Header (matches SSR's pageHeaderHtml) ----
  let pageHeader = document.createElement("header")
  pageHeader.className = "page-header"
  appDiv.appendChild(pageHeader)

  let pageH1 = document.createElement("h1")
  pageH1.textContent = "IsoNim Task Manager"
  pageHeader.appendChild(pageH1)

  let subtitle = document.createElement("p")
  subtitle.className = "subtitle"
  subtitle.textContent = "A reactive UI demo -- same code, server and client"
  pageHeader.appendChild(subtitle)

  # ---- Section (wraps task header + task list, matches SSR) ----
  let section = document.createElement("section")
  appDiv.appendChild(section)

  # Task header (inside section)
  let taskHeader = document.createElement("header")
  section.appendChild(taskHeader)

  let h1 = document.createElement("h1")
  h1.textContent = "Task Manager"
  taskHeader.appendChild(h1)

  let form = document.createElement("form")
  taskHeader.appendChild(form)

  let inputField = document.createElement("input")
  inputField.setAttribute("type", "text")
  inputField.setAttribute("placeholder", "What needs to be done?")
  form.appendChild(inputField)

  let addBtn = document.createElement("button")
  addBtn.setAttribute("type", "submit")
  addBtn.textContent = "Add"
  form.appendChild(addBtn)

  # Handle form submit
  form.Node.addEventListener("submit", proc(ev: Event) =
    {.emit: [ev, ".preventDefault();"].}
    var inputVal: cstring
    {.emit: [inputVal, " = ", inputField, ".value;"].}
    store.addTask($inputVal)
    {.emit: [inputField, ".value = '';"].}
  )

  # ---- Task List (inside section) ----
  let emptyMsg = document.createElement("p")
  emptyMsg.className = "empty"
  emptyMsg.textContent = "No tasks"

  # Reactive list rendering
  createRenderEffect proc() =
    # Clear section and re-add task header + new list
    section.innerHTML = ""
    section.appendChild(taskHeader)
    let currentTasks = store.filteredTasks.val
    if currentTasks.len == 0:
      section.appendChild(emptyMsg.Node.cloneNode(true))
    else:
      let ul = document.createElement("ul")
      ul.className = "task-list"
      for t in currentTasks:
        let task = t
        let li = document.createElement("li")
        if task.done:
          li.className = "completed"

        let checkbox = document.createElement("input")
        checkbox.setAttribute("type", "checkbox")
        if task.done:
          checkbox.setAttribute("checked", "")
        checkbox.Node.addEventListener("change", proc(ev: Event) =
          store.toggleTask(task.id)
        )
        li.appendChild(checkbox)

        let span = document.createElement("span")
        span.textContent = cstring(task.text)
        span.Node.addEventListener("click", proc(ev: Event) =
          store.setSelectedId(task.id)
        )
        li.appendChild(span)

        let removeBtn = document.createElement("button")
        removeBtn.className = "remove"
        removeBtn.textContent = cstring("\xC3\x97")  # multiplication sign
        removeBtn.Node.addEventListener("click", proc(ev: Event) =
          store.removeTask(task.id)
        )
        li.appendChild(removeBtn)
        ul.appendChild(li)
      section.appendChild(ul)

  # ---- Footer (matches SSR's footerHtml) ----
  # SSR uses <footer> directly, not wrapped in a div
  let footerContainer = document.createElement("div")
  appDiv.appendChild(footerContainer)

  createRenderEffect proc() =
    footerContainer.innerHTML = ""
    if store.tasks.val.len > 0:
      let footer = document.createElement("footer")
      footer.className = "task-footer"

      let countSpan = document.createElement("span")
      let ac = store.activeCount.val
      let suffix = if ac != 1: "s" else: ""
      countSpan.textContent = cstring($ac & " item" & suffix & " left")
      footer.appendChild(countSpan)

      let filtersDiv = document.createElement("div")
      filtersDiv.className = "filters"
      for f in [fAll, fActive, fCompleted]:
        let filterVal = f
        let btn = document.createElement("button")
        btn.textContent = cstring($filterVal)
        if store.filter.val == filterVal:
          btn.className = "selected"
        btn.Node.addEventListener("click", proc(ev: Event) =
          store.setFilter(filterVal)
        )
        filtersDiv.appendChild(btn)
      footer.appendChild(filtersDiv)

      if store.completedCount.val > 0:
        let clearBtn = document.createElement("button")
        clearBtn.textContent = "Clear completed"
        clearBtn.Node.addEventListener("click", proc(ev: Event) =
          store.clearCompleted()
        )
        footer.appendChild(clearBtn)

      footerContainer.appendChild(footer)

  return appDiv.Node

# ---- Hydrate ----
let rootEl = document.getElementById("root")
hydrate(createApp, rootEl)
