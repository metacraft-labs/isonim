## IsoNim demo app — browser entry point.
## Renders the task manager app into the DOM using the web renderer.

when not defined(js):
  {.error: "main.nim requires the JS backend (nim js)".}

import isonim/web/dom_api
import isonim/web/client
import isonim/web/events
import isonim/rxcore
import isonim/core/[signals, computation]
import task_store

# Delegate common events
delegateEvents(["click", "input", "change", "submit"])

proc createApp(): Node =
  ## Builds the complete app DOM tree with reactive bindings.
  let store = createTaskStore()
  provideTaskStore(store)

  # App container
  let appDiv = document.createElement("div")
  appDiv.className = "app"

  # ---- Header ----
  let header = document.createElement("header")
  appDiv.appendChild(header)

  let h1 = document.createElement("h1")
  h1.textContent = "Task Manager"
  header.appendChild(h1)

  let form = document.createElement("form")
  header.appendChild(form)

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

  # ---- Task List ----
  let section = document.createElement("section")
  appDiv.appendChild(section)

  let emptyMsg = document.createElement("p")
  emptyMsg.className = "empty"
  emptyMsg.textContent = "No tasks"

  let taskList = document.createElement("ul")
  taskList.className = "task-list"

  # Reactive list rendering
  createRenderEffect do:
    let tasks = store.filteredTasks.val
    # Clear section
    section.innerHTML = ""
    if tasks.len == 0:
      section.appendChild(emptyMsg.Node.cloneNode(true))
    else:
      let ul = document.createElement("ul")
      ul.className = "task-list"
      for t in tasks:
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

  # ---- Footer ----
  let footerContainer = document.createElement("div")
  appDiv.appendChild(footerContainer)

  createRenderEffect do:
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

  # ---- Task Detail ----
  let detailContainer = document.createElement("div")
  appDiv.appendChild(detailContainer)

  createRenderEffect do:
    detailContainer.innerHTML = ""
    let sid = store.selectedId.val
    if sid >= 0:
      let aside = document.createElement("aside")
      aside.className = "task-detail"

      let h3 = document.createElement("h3")
      h3.textContent = "Task Details"
      aside.appendChild(h3)

      # Find the selected task
      for t in store.tasks.val:
        if t.id == sid:
          let p = document.createElement("p")
          let strong = document.createElement("strong")
          strong.textContent = cstring(t.text)
          p.appendChild(strong)
          aside.appendChild(p)

          let notesP = document.createElement("p")
          notesP.textContent = cstring("Notes for task " & $t.id)
          aside.appendChild(notesP)
          break

      detailContainer.appendChild(aside)

  # ---- Effect Log ----
  let logContainer = document.createElement("div")
  appDiv.appendChild(logContainer)

  createRenderEffect do:
    logContainer.innerHTML = ""
    let entries = store.log.val
    if entries.len > 0:
      let details = document.createElement("details")
      details.className = "effect-log"

      let summary = document.createElement("summary")
      summary.textContent = cstring("Effect log (" & $entries.len & " entries)")
      details.appendChild(summary)

      let ul = document.createElement("ul")
      for entry in entries:
        let li = document.createElement("li")
        li.textContent = cstring(entry)
        ul.appendChild(li)
      details.appendChild(ul)

      logContainer.appendChild(details)

  return appDiv.Node

# ---- Mount ----
let rootEl = document.getElementById("root")
discard render(createApp, rootEl)
