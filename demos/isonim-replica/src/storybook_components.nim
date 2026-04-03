## Storybook-compatible component exports for the IsoNim demo app.
## Each proc takes a container DOM element, mounts a reactive component,
## and returns a dispose/cleanup function.
##
## Compiled with: nim js -o:storybook/dist/components.js src/storybook_components.nim
## Then imported from Storybook stories.

when not defined(js):
  {.error: "storybook_components.nim requires the JS backend (nim js)".}

import isonim/web/dom_api
import isonim/web/events
import isonim/rxcore
import isonim/core/[signals, computation]
import task_store

# Delegate common events once at module init
delegateEvents(["click", "input", "change", "submit"])

type DisposeProc = proc()

# ---- Counter Component ----

proc mountCounter*(container: Element): DisposeProc {.exportc.} =
  ## Mounts a simple counter component into the given container.
  ## Returns a dispose function that cleans up the reactive tree.
  var disposer: proc()

  createRoot proc(dispose: proc()) =
    disposer = dispose

    let count = createSignal(0)

    let wrapper = document.createElement("div")
    wrapper.className = "counter"

    let display = document.createElement("span")
    display.className = "count-display"
    createRenderEffect proc() =
      display.textContent = cstring($count.val)
    wrapper.appendChild(display.Node)

    let decBtn = document.createElement("button")
    decBtn.className = "dec-btn"
    decBtn.textContent = "-"
    decBtn.Node.addEventListener("click", proc(ev: Event) =
      count.update proc(prev: int): int = prev - 1
    )
    wrapper.appendChild(decBtn.Node)

    let incBtn = document.createElement("button")
    incBtn.className = "inc-btn"
    incBtn.textContent = "+"
    incBtn.Node.addEventListener("click", proc(ev: Event) =
      count.update proc(prev: int): int = prev + 1
    )
    wrapper.appendChild(incBtn.Node)

    container.Node.appendChild(wrapper.Node)

  return proc() =
    if disposer != nil:
      disposer()
    container.innerHTML = ""

# ---- Task Item Component ----

proc mountTaskItem*(container: Element, text: cstring, done: bool = false): DisposeProc {.exportc.} =
  ## Mounts a single task item into the given container.
  ## Returns a dispose function.
  var disposer: proc()

  createRoot proc(dispose: proc()) =
    disposer = dispose

    let isDone = createSignal(done)

    let li = document.createElement("li")
    createRenderEffect proc() =
      if isDone.val:
        li.className = "completed"
      else:
        li.className = ""

    let checkbox = document.createElement("input")
    checkbox.setAttribute("type", "checkbox")
    createRenderEffect proc() =
      if isDone.val:
        checkbox.setAttribute("checked", "")
      else:
        checkbox.removeAttribute("checked")
    checkbox.Node.addEventListener("change", proc(ev: Event) =
      isDone.val = not isDone.val
    )
    li.appendChild(checkbox.Node)

    let span = document.createElement("span")
    span.textContent = text
    li.appendChild(span.Node)

    let removeBtn = document.createElement("button")
    removeBtn.className = "remove"
    removeBtn.textContent = cstring("\xC3\x97")
    li.appendChild(removeBtn.Node)

    container.Node.appendChild(li.Node)

  return proc() =
    if disposer != nil:
      disposer()
    container.innerHTML = ""

# ---- Task Manager Component ----

proc mountTaskManager*(container: Element, initialTasks: seq[cstring] = @[]): DisposeProc {.exportc.} =
  ## Mounts a full task manager with optional initial tasks.
  ## Returns a dispose function.
  var disposer: proc()

  createRoot proc(dispose: proc()) =
    disposer = dispose

    let store = createTaskStore()

    # Add initial tasks
    for t in initialTasks:
      store.addTask($t)

    # App container
    let appDiv = document.createElement("div")
    appDiv.className = "app"

    # ---- Header ----
    let header = document.createElement("header")
    appDiv.appendChild(header.Node)

    let h1 = document.createElement("h1")
    h1.textContent = "Task Manager"
    header.appendChild(h1.Node)

    let form = document.createElement("form")
    header.appendChild(form.Node)

    let inputField = document.createElement("input")
    inputField.setAttribute("type", "text")
    inputField.setAttribute("placeholder", "What needs to be done?")
    form.appendChild(inputField.Node)

    let addBtn = document.createElement("button")
    addBtn.setAttribute("type", "submit")
    addBtn.textContent = "Add"
    form.appendChild(addBtn.Node)

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
    appDiv.appendChild(section.Node)

    let emptyMsg = document.createElement("p")
    emptyMsg.className = "empty"
    emptyMsg.textContent = "No tasks"

    # Reactive list rendering
    createRenderEffect proc() =
      let tasks = store.filteredTasks.val
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
          li.appendChild(checkbox.Node)

          let span = document.createElement("span")
          span.textContent = cstring(task.text)
          li.appendChild(span.Node)

          let removeBtn = document.createElement("button")
          removeBtn.className = "remove"
          removeBtn.textContent = cstring("\xC3\x97")
          removeBtn.Node.addEventListener("click", proc(ev: Event) =
            store.removeTask(task.id)
          )
          li.appendChild(removeBtn.Node)
          ul.appendChild(li.Node)
        section.appendChild(ul.Node)

    # ---- Footer ----
    let footerContainer = document.createElement("div")
    appDiv.appendChild(footerContainer.Node)

    createRenderEffect proc() =
      footerContainer.innerHTML = ""
      if store.tasks.val.len > 0:
        let footer = document.createElement("footer")
        footer.className = "task-footer"

        let countSpan = document.createElement("span")
        countSpan.className = "count"
        let ac = store.activeCount.val
        let suffix = if ac != 1: "s" else: ""
        countSpan.textContent = cstring($ac & " item" & suffix & " left")
        footer.appendChild(countSpan.Node)

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
          filtersDiv.appendChild(btn.Node)
        footer.appendChild(filtersDiv.Node)

        if store.completedCount.val > 0:
          let clearBtn = document.createElement("button")
          clearBtn.className = "clear-completed"
          clearBtn.textContent = "Clear completed"
          clearBtn.Node.addEventListener("click", proc(ev: Event) =
            store.clearCompleted()
          )
          footer.appendChild(clearBtn.Node)

        footerContainer.appendChild(footer.Node)

    container.Node.appendChild(appDiv.Node)

  return proc() =
    if disposer != nil:
      disposer()
    container.innerHTML = ""

# ---- WebComponent Registrations (for G6 preview) ----

import isonim/web/custom_element

proc registerStorybookWebComponents*() {.exportc.} =
  ## Registers custom elements for use in Storybook WebComponent stories.
  ## Call once before rendering any custom element stories.

  # <isonim-counter> — a self-contained counter custom element
  registerCustomElement(
    "isonim-counter",
    [propDef("initial-count", "0")],
    proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
      var startVal: int
      {.emit: [startVal, " = parseInt(", getProp(cstring"initial-count"), ") || 0;"].}
      let count = createSignal(startVal)

      let wrapper = document.createElement("div")
      wrapper.className = "counter"

      let display = document.createElement("span")
      display.className = "count-display"
      createRenderEffect proc() =
        display.textContent = cstring($count.val)
      wrapper.appendChild(display.Node)

      let decBtn = document.createElement("button")
      decBtn.className = "dec-btn"
      decBtn.textContent = "-"
      decBtn.Node.addEventListener("click", proc(ev: Event) =
        count.update proc(prev: int): int = prev - 1
      )
      wrapper.appendChild(decBtn.Node)

      let incBtn = document.createElement("button")
      incBtn.className = "inc-btn"
      incBtn.textContent = "+"
      incBtn.Node.addEventListener("click", proc(ev: Event) =
        count.update proc(prev: int): int = prev + 1
      )
      wrapper.appendChild(incBtn.Node)

      # Add minimal styles to shadow DOM
      let style = document.createElement("style")
      style.textContent = cstring"""
        .counter { display: flex; align-items: center; gap: 12px; font-family: sans-serif; }
        .count-display { font-size: 24px; min-width: 40px; text-align: center; }
        button { padding: 8px 16px; font-size: 18px; cursor: pointer; }
      """
      ctx.renderRoot.appendChild(style.Node)
      ctx.renderRoot.appendChild(wrapper.Node)
    ,
    useShadow = true
  )

  # <isonim-task-item> — a single task item custom element
  registerCustomElement(
    "isonim-task-item",
    [propDef("text", ""), propDef("done", "false")],
    proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
      let isDone = createSignal(getProp(cstring"done") == cstring"true")
      let taskText = getProp(cstring"text")

      let li = document.createElement("li")
      createRenderEffect proc() =
        if isDone.val:
          li.className = "completed"
        else:
          li.className = ""

      let checkbox = document.createElement("input")
      checkbox.setAttribute("type", "checkbox")
      createRenderEffect proc() =
        if isDone.val:
          checkbox.setAttribute("checked", "")
        else:
          checkbox.removeAttribute("checked")
      checkbox.Node.addEventListener("change", proc(ev: Event) =
        isDone.val = not isDone.val
      )
      li.appendChild(checkbox.Node)

      let span = document.createElement("span")
      span.textContent = taskText
      li.appendChild(span.Node)

      # Add styles to shadow DOM
      let style = document.createElement("style")
      style.textContent = cstring"""
        li { list-style: none; padding: 8px 0; display: flex; align-items: center; gap: 8px; font-family: sans-serif; }
        li.completed span { text-decoration: line-through; color: #999; }
        input[type="checkbox"] { cursor: pointer; }
      """
      ctx.renderRoot.appendChild(style.Node)
      ctx.renderRoot.appendChild(li.Node)
    ,
    useShadow = true
  )
