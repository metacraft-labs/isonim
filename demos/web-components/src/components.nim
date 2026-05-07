## Standalone WebComponents demo for IsoNim.
## Registers several reusable custom elements that work in plain HTML.
##
## Compile with: nim js -o:demos/web-components/dist/components.js demos/web-components/src/components.nim

when not defined(js):
  {.error: "components.nim requires the JS backend (nim js)".}

import std/[jsffi]
import isonim/web/dom_api
import isonim/web/custom_element
import isonim/rxcore
import isonim/core/[signals, computation]

# ---------------------------------------------------------------------------
# Helper: dispatch a CustomEvent with a detail object
# ---------------------------------------------------------------------------

proc dispatchCustomEvent(el: Element, name: cstring, detail: JsObject) =
  ## Dispatches a CustomEvent on the given element with the given detail.
  {.emit: ["""
    var ev = new CustomEvent(""", name, """, {
      bubbles: true,
      composed: true,
      detail: """, detail, """
    });
    """, el, """.dispatchEvent(ev);
  """].}

# ---------------------------------------------------------------------------
# <isonim-counter>
# ---------------------------------------------------------------------------

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
    createRenderEffect do:
      display.textContent = cstring($count.val)
    wrapper.appendChild(display.Node)

    let decBtn = document.createElement("button")
    decBtn.className = "dec-btn"
    decBtn.textContent = "-"
    decBtn.Node.addEventListener("click", proc(ev: Event) =
      count.update proc(prev: int): int = prev - 1
      let detail = newJsObject()
      detail["count"] = toJs(count.val)
      dispatchCustomEvent(ctx.element, "count-changed", detail)
    )
    wrapper.appendChild(decBtn.Node)

    let incBtn = document.createElement("button")
    incBtn.className = "inc-btn"
    incBtn.textContent = "+"
    incBtn.Node.addEventListener("click", proc(ev: Event) =
      count.update proc(prev: int): int = prev + 1
      let detail = newJsObject()
      detail["count"] = toJs(count.val)
      dispatchCustomEvent(ctx.element, "count-changed", detail)
    )
    wrapper.appendChild(incBtn.Node)

    # Register attribute change signal for initial-count
    let countSetter = proc(v: cstring) =
      var parsed: int
      {.emit: [parsed, " = parseInt(", v, ") || 0;"].}
      count.val = parsed
      let detail = newJsObject()
      detail["count"] = toJs(parsed)
      dispatchCustomEvent(ctx.element, "count-changed", detail)
    {.emit: [ctx.element, "._propSignals['initial-count'] = ", countSetter, ";"].}

    # Shadow DOM styles
    let style = document.createElement("style")
    style.textContent = cstring"""
      :host { display: inline-block; }
      .counter { display: flex; align-items: center; gap: 12px; font-family: system-ui, sans-serif; }
      .count-display { font-size: 2rem; font-weight: 700; min-width: 3ch; text-align: center; }
      button {
        padding: 8px 18px; font-size: 1.25rem; cursor: pointer; border: 1px solid #ccc;
        border-radius: 6px; background: #f5f5f5; transition: background 0.15s;
      }
      button:hover { background: #e0e0e0; }
      button:active { background: #d0d0d0; }
    """
    ctx.renderRoot.appendChild(style.Node)
    ctx.renderRoot.appendChild(wrapper.Node)
  ,
  useShadow = true
)

# ---------------------------------------------------------------------------
# <isonim-toggle>
# ---------------------------------------------------------------------------

registerCustomElement(
  "isonim-toggle",
  [propDef("checked", ""), propDef("label", "")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    let initialChecked = getProp(cstring"checked")
    # Treat the attribute as a boolean: present or "true" means checked
    var isChecked: bool
    {.emit: [isChecked, " = (", initialChecked, " !== '' && ", initialChecked, " !== 'false') || ", ctx.element, ".hasAttribute('checked');"].}
    let checked = createSignal(isChecked)

    let labelText = createSignal(getProp(cstring"label"))

    let wrapper = document.createElement("label")
    wrapper.className = "toggle-wrapper"

    let track = document.createElement("span")
    track.className = "toggle-track"

    let thumb = document.createElement("span")
    thumb.className = "toggle-thumb"
    track.appendChild(thumb.Node)

    createRenderEffect do:
      if checked.val:
        track.className = "toggle-track checked"
      else:
        track.className = "toggle-track"

    wrapper.Node.addEventListener("click", proc(ev: Event) =
      checked.val = not checked.val
      let detail = newJsObject()
      detail["checked"] = toJs(checked.val)
      dispatchCustomEvent(ctx.element, "toggle-changed", detail)
    )

    wrapper.appendChild(track.Node)

    let labelSpan = document.createElement("span")
    labelSpan.className = "toggle-label"
    createRenderEffect do:
      labelSpan.textContent = labelText.val

    wrapper.appendChild(labelSpan.Node)

    # Attribute change signals
    let checkedSetter = proc(v: cstring) =
      var b: bool
      {.emit: [b, " = (", v, " !== '' && ", v, " !== 'false') || ", v, " === null;"].}
      # If attribute is removed, that also means "present" was toggled off
      {.emit: [b, " = (", v, " !== 'false' && ", v, " !== null);"].}
      checked.val = b
    {.emit: [ctx.element, "._propSignals['checked'] = ", checkedSetter, ";"].}

    let labelSetter = proc(v: cstring) =
      labelText.val = v
    {.emit: [ctx.element, "._propSignals['label'] = ", labelSetter, ";"].}

    let style = document.createElement("style")
    style.textContent = cstring"""
      :host { display: inline-block; }
      .toggle-wrapper {
        display: inline-flex; align-items: center; gap: 10px;
        cursor: pointer; font-family: system-ui, sans-serif; user-select: none;
      }
      .toggle-track {
        position: relative; width: 44px; height: 24px;
        background: #ccc; border-radius: 12px; transition: background 0.2s;
      }
      .toggle-track.checked { background: #4caf50; }
      .toggle-thumb {
        position: absolute; top: 2px; left: 2px; width: 20px; height: 20px;
        background: #fff; border-radius: 50%; transition: transform 0.2s;
        box-shadow: 0 1px 3px rgba(0,0,0,0.3);
      }
      .toggle-track.checked .toggle-thumb { transform: translateX(20px); }
      .toggle-label { font-size: 0.95rem; color: #333; }
    """
    ctx.renderRoot.appendChild(style.Node)
    ctx.renderRoot.appendChild(wrapper.Node)
  ,
  useShadow = true
)

# ---------------------------------------------------------------------------
# <isonim-badge>
# ---------------------------------------------------------------------------

registerCustomElement(
  "isonim-badge",
  [propDef("count", "0"), propDef("variant", "info")],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    let badgeCount = createSignal(getProp(cstring"count"))
    let variant = createSignal(getProp(cstring"variant"))

    let badge = document.createElement("span")
    badge.className = "badge"

    createRenderEffect do:
      badge.textContent = badgeCount.val
      let v = variant.val
      var cls = cstring"badge"
      if v == cstring"warning":
        cls = cstring"badge warning"
      elif v == cstring"error":
        cls = cstring"badge error"
      else:
        cls = cstring"badge info"
      badge.className = cls

    # Attribute change signals
    let countSetter = proc(v: cstring) =
      badgeCount.val = v
    {.emit: [ctx.element, "._propSignals['count'] = ", countSetter, ";"].}

    let variantSetter = proc(v: cstring) =
      variant.val = v
    {.emit: [ctx.element, "._propSignals['variant'] = ", variantSetter, ";"].}

    let style = document.createElement("style")
    style.textContent = cstring"""
      :host { display: inline-block; }
      .badge {
        display: inline-flex; align-items: center; justify-content: center;
        min-width: 22px; height: 22px; padding: 0 7px;
        border-radius: 12px; font-size: 0.8rem; font-weight: 700;
        font-family: system-ui, sans-serif; color: #fff;
      }
      .badge.info { background: #2196f3; }
      .badge.warning { background: #ff9800; }
      .badge.error { background: #f44336; }
    """
    ctx.renderRoot.appendChild(style.Node)
    ctx.renderRoot.appendChild(badge.Node)
  ,
  useShadow = true
)

# ---------------------------------------------------------------------------
# <isonim-todo-list>
# ---------------------------------------------------------------------------

type
  TodoItem = object
    id: int
    text: cstring
    done: bool

registerCustomElement(
  "isonim-todo-list",
  @[],
  proc(ctx: CustomElementContext, getProp: proc(name: cstring): cstring) =
    var nextId = 0
    let tasks = createSignal(newSeq[TodoItem]())

    # Expose addTask and getTasks as methods on the element
    let addTaskMethod = proc(text: cstring) =
      var newTasks = tasks.val
      newTasks.add(TodoItem(id: nextId, text: text, done: false))
      inc nextId
      tasks.val = newTasks
      let detail = newJsObject()
      detail["text"] = toJs(text)
      dispatchCustomEvent(ctx.element, "task-added", detail)

    let getTasksMethod = proc(): JsObject =
      let arr = newJsObject()
      {.emit: [arr, " = [];"].}
      for t in tasks.val:
        let obj = newJsObject()
        obj["id"] = toJs(t.id)
        obj["text"] = toJs(t.text)
        obj["done"] = toJs(t.done)
        {.emit: [arr, ".push(", obj, ");"].}
      return arr

    {.emit: [ctx.element, ".addTask = ", addTaskMethod, ";"].}
    {.emit: [ctx.element, ".getTasks = ", getTasksMethod, ";"].}

    # --- Build UI ---

    let wrapper = document.createElement("div")
    wrapper.className = "todo-list"

    # Input form
    let form = document.createElement("form")
    form.className = "todo-form"

    let input = document.createElement("input")
    input.setAttribute("type", "text")
    input.setAttribute("placeholder", "Add a task...")
    form.appendChild(input.Node)

    let addBtn = document.createElement("button")
    addBtn.setAttribute("type", "submit")
    addBtn.textContent = "Add"
    form.appendChild(addBtn.Node)

    form.Node.addEventListener("submit", proc(ev: Event) =
      {.emit: [ev, ".preventDefault();"].}
      var inputVal: cstring
      {.emit: [inputVal, " = ", input, ".value;"].}
      if inputVal != cstring"":
        addTaskMethod(inputVal)
        {.emit: [input, ".value = '';"].}
    )
    wrapper.appendChild(form.Node)

    # Task list container
    let listContainer = document.createElement("div")
    listContainer.className = "tasks"

    createRenderEffect do:
      listContainer.innerHTML = ""
      let currentTasks = tasks.val
      if currentTasks.len == 0:
        let emptyMsg = document.createElement("p")
        emptyMsg.className = "empty"
        emptyMsg.textContent = "No tasks yet"
        listContainer.appendChild(emptyMsg.Node)
      else:
        let ul = document.createElement("ul")
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
            var updated = tasks.val
            for i in 0 ..< updated.len:
              if updated[i].id == task.id:
                updated[i].done = not updated[i].done
                tasks.val = updated
                let detail = newJsObject()
                detail["id"] = toJs(task.id)
                detail["done"] = toJs(updated[i].done)
                dispatchCustomEvent(ctx.element, "task-toggled", detail)
                break
          )
          li.appendChild(checkbox.Node)

          let span = document.createElement("span")
          span.textContent = task.text
          li.appendChild(span.Node)

          let removeBtn = document.createElement("button")
          removeBtn.className = "remove"
          removeBtn.textContent = cstring"\xC3\x97"
          removeBtn.Node.addEventListener("click", proc(ev: Event) =
            var updated: seq[TodoItem]
            for item in tasks.val:
              if item.id != task.id:
                updated.add(item)
            tasks.val = updated
            let detail = newJsObject()
            detail["id"] = toJs(task.id)
            detail["text"] = toJs(task.text)
            dispatchCustomEvent(ctx.element, "task-removed", detail)
          )
          li.appendChild(removeBtn.Node)

          ul.appendChild(li.Node)
        listContainer.appendChild(ul.Node)

    wrapper.appendChild(listContainer.Node)

    # Summary
    let summary = document.createElement("div")
    summary.className = "summary"
    createRenderEffect do:
      let total = tasks.val.len
      var doneCount = 0
      for t in tasks.val:
        if t.done: inc doneCount
      if total > 0:
        summary.textContent = cstring($doneCount & "/" & $total & " completed")
      else:
        summary.textContent = cstring""
    wrapper.appendChild(summary.Node)

    let style = document.createElement("style")
    style.textContent = cstring"""
      :host { display: block; max-width: 400px; }
      .todo-list { font-family: system-ui, sans-serif; }
      .todo-form {
        display: flex; gap: 8px; margin-bottom: 12px;
      }
      .todo-form input {
        flex: 1; padding: 8px 12px; font-size: 0.95rem;
        border: 1px solid #ccc; border-radius: 6px;
      }
      .todo-form button {
        padding: 8px 16px; font-size: 0.95rem; cursor: pointer;
        border: 1px solid #2196f3; border-radius: 6px;
        background: #2196f3; color: #fff;
      }
      .todo-form button:hover { background: #1976d2; }
      ul { list-style: none; padding: 0; margin: 0; }
      li {
        display: flex; align-items: center; gap: 8px;
        padding: 8px 0; border-bottom: 1px solid #eee;
      }
      li.completed span { text-decoration: line-through; color: #999; }
      li span { flex: 1; }
      li .remove {
        border: none; background: none; color: #f44336;
        font-size: 1.2rem; cursor: pointer; padding: 0 4px;
      }
      li .remove:hover { color: #d32f2f; }
      .empty { color: #999; font-style: italic; }
      .summary { margin-top: 8px; font-size: 0.85rem; color: #666; }
    """
    ctx.renderRoot.appendChild(style.Node)
    ctx.renderRoot.appendChild(wrapper.Node)
  ,
  useShadow = true
)
