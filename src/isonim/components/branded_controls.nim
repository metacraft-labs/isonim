## Branded controls — renders task app components using Tailwind CSS utility
## classes for a pixel-identical appearance on all platforms.
##
## On native platforms (iOS/Android/Freya), the ui macro expands
## Tailwind classes to setStyle calls at compile time. On web, classes are
## passed through to the browser's Tailwind CSS engine.
##
## Reactive components use createRenderEffect for fine-grained updates.

import isonim/components/task_manager
import isonim/theming/theme
import isonim/core/[computation]
import isonim/dsl/ui

# ---------------------------------------------------------------------------
# Public component procs — branded implementations using Tailwind
# ---------------------------------------------------------------------------

proc initTheme*() =
  setTheme(isoTheme())

proc createAppRoot*[R, E](r: R): E =
  ui(r):
    tdiv(class = "p-4 bg-slate-50")

proc createTitle*[R, E](r: R; text: string): E =
  let el = ui(r):
    span(class = "text-4xl font-bold h-10")
  r.setTextContent(el, text)
  r.setStyle(el, "color", themeColor("text-primary"))
  el

proc createInputRow*[R, E](r: R; placeholder: string;
                            onAdd: proc(text: string)): E =
  let row = ui(r):
    tdiv(class = "flex flex-row p-2 gap-2")

  let input = r.createElement("input")
  r.setStyle(input, "background-color", "#F1F5F9")
  r.setStyle(input, "border-radius", "8")
  r.setStyle(input, "padding", "12")
  r.setStyle(input, "font-size", "16")
  r.setStyle(input, "flex-grow", "1")
  r.setStyle(input, "height", "48")
  r.setStyle(input, "color", themeColor("text-primary"))
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = ui(r):
    tdiv(class = "w-12 h-12 rounded-full items-center justify-center")
  r.setStyle(addBtn, "background-color", themeColor("primary"))

  let plusIcon = r.createTextNode("+")
  r.setStyle(plusIcon, "color", "#FFFFFF")
  r.setStyle(plusIcon, "font-size", "24")
  r.setStyle(plusIcon, "text-align", "center")
  r.setStyle(plusIcon, "height", "28")
  r.setStyle(plusIcon, "width", "28")
  r.appendChild(addBtn, plusIcon)

  r.addEventListener(addBtn, "click", proc() =
    let text = r.textContent(input)
    if text.len > 0:
      onAdd(text)
      r.setTextContent(input, "")
  )

  r.appendChild(row, input)
  r.appendChild(row, addBtn)
  row

proc createTaskList*[R, E](r: R): E =
  ui(r):
    tdiv(class = "grow gap-2 p-2 mt-1")

proc createTaskRow*[R, E](r: R; task: proc(): TaskData;
                           onToggle, onDelete: proc()): E =
  let row = ui(r):
    tdiv(class = "flex flex-row items-center p-3 rounded-xl")
  r.setStyle(row, "background-color", themeColor("surface"))

  # Checkbox
  let checkbox = ui(r):
    tdiv(class = "w-6 h-6 rounded-md items-center justify-center")

  let check = r.createTextNode("\u2713")
  r.setStyle(check, "color", "#FFFFFF")
  r.setStyle(check, "font-size", "14")
  r.setStyle(check, "text-align", "center")
  r.setStyle(check, "height", "18")
  r.setStyle(check, "width", "18")
  r.appendChild(checkbox, check)

  createRenderEffect proc() =
    let t = task()
    if t.completed:
      r.setStyle(checkbox, "background-color", themeColor("primary"))
      r.setStyle(checkbox, "border-color", "transparent")
      r.setStyle(checkbox, "border-width", "0")
      r.setStyle(check, "display", "flex")
    else:
      r.setStyle(checkbox, "background-color", "transparent")
      r.setStyle(checkbox, "border-color", themeColor("border"))
      r.setStyle(checkbox, "border-width", "2")
      r.setStyle(check, "display", "none")

  r.addEventListener(checkbox, "click", onToggle)

  # Text label
  let label = ui(r):
    span(class = "text-base grow h-5 ml-3")

  createRenderEffect proc() =
    let t = task()
    r.setTextContent(label, t.text)
    if t.completed:
      r.setStyle(label, "color", themeColor("text-disabled"))
    else:
      r.setStyle(label, "color", themeColor("text-primary"))

  # Delete button
  let delBtn = ui(r):
    tdiv(class = "p-2 items-center justify-center")

  let delIcon = r.createTextNode("\u2715")
  r.setStyle(delIcon, "color", themeColor("error"))
  r.setStyle(delIcon, "font-size", "20")
  r.setStyle(delIcon, "text-align", "center")
  r.setStyle(delIcon, "height", "24")
  r.setStyle(delIcon, "width", "24")
  r.appendChild(delBtn, delIcon)
  r.addEventListener(delBtn, "click", onDelete)

  r.appendChild(row, checkbox)
  r.appendChild(row, label)
  r.appendChild(row, delBtn)
  row

proc createEmptyState*[R, E](r: R; message: string): E =
  let empty = ui(r):
    tdiv(class = "grow items-center justify-center")

  let emptyText = ui(r):
    span(class = "text-lg text-center h-14 self-center")
  r.setStyle(emptyText, "width", "300")
  r.setStyle(emptyText, "color", themeColor("text-secondary"))
  r.setTextContent(emptyText, message)
  r.appendChild(empty, emptyText)
  empty

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  let bar = ui(r):
    tdiv(class = "flex flex-row justify-center items-center gap-2 p-3")

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let filtCapture = filt

    let btn = ui(r):
      tdiv(class = "py-2 px-4 rounded-2xl items-center justify-center")

    let textWidth = max(label.len * 9, 30)
    let text = r.createTextNode(label)
    r.setStyle(text, "font-size", "14")
    r.setStyle(text, "height", "18")
    r.setStyle(text, "width", $textWidth)
    r.appendChild(btn, text)

    createRenderEffect proc() =
      let active = currentFilter() == filtCapture
      if active:
        r.setStyle(btn, "background-color", themeColor("primary"))
        r.setStyle(text, "color", "#FFFFFF")
      else:
        r.setStyle(btn, "background-color", "transparent")
        r.setStyle(text, "color", themeColor("text-secondary"))

    r.addEventListener(btn, "click", proc() = onFilter(filtCapture))
    r.appendChild(bar, btn)

  bar

proc createClearButton*[R, E](r: R; hasCompleted: proc(): bool;
                               onClear: proc()): E =
  let clearBtn = ui(r):
    tdiv(class = "p-2 items-center justify-center")

  let clearText = ui(r):
    span(class = "text-sm h-5 self-center")
  r.setStyle(clearText, "width", "130")
  r.setTextContent(clearText, "Clear Completed")
  r.appendChild(clearBtn, clearText)

  createRenderEffect proc() =
    if hasCompleted():
      r.setStyle(clearText, "color", themeColor("error"))
    else:
      r.setStyle(clearText, "color", themeColor("text-disabled"))

  r.addEventListener(clearBtn, "click", proc() =
    if hasCompleted():
      onClear()
  )

  clearBtn
