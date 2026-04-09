## Branded controls — renders task app components using styled divs and
## theme tokens for a pixel-identical appearance on all platforms.
##
## Uses the renderer's setStyle calls (which auto-register with Yoga when
## the renderer has an embedded LayoutEngine). No manual engine parameter.
##
## Reactive components use createRenderEffect for fine-grained updates.

import isonim/components/task_manager
import isonim/theming/theme
import isonim/core/[computation]

# ---------------------------------------------------------------------------
# Public component procs — branded implementations
# ---------------------------------------------------------------------------

proc initTheme*() =
  ## Activate the branded theme.
  setTheme(isoTheme())

proc createAppRoot*[R, E](r: R): E =
  let root = r.createElement("div")
  r.setStyle(root, "background-color", themeColor("background"))
  r.setStyle(root, "padding", "16")
  root

proc createTitle*[R, E](r: R; text: string): E =
  let title = r.createElement("span")
  r.setStyle(title, "font-size", "32")
  r.setStyle(title, "font-weight", "bold")
  r.setStyle(title, "height", "40")
  r.setStyle(title, "color", themeColor("text-primary"))
  r.setTextContent(title, text)
  title

proc createInputRow*[R, E](r: R; placeholder: string;
                            onAdd: proc(text: string)): E =
  let row = r.createElement("div")
  r.setStyle(row, "flex-direction", "row")
  r.setStyle(row, "padding", "8")
  r.setStyle(row, "gap", "8")

  let input = r.createElement("input")
  r.setStyle(input, "background-color", "#F1F5F9")
  r.setStyle(input, "border-radius", "8")
  r.setStyle(input, "padding", "12")
  r.setStyle(input, "font-size", "16")
  r.setStyle(input, "color", themeColor("text-primary"))
  r.setStyle(input, "flex-grow", "1")
  r.setStyle(input, "height", "48")
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = r.createElement("div")
  r.setStyle(addBtn, "background-color", themeColor("primary"))
  r.setStyle(addBtn, "border-radius", "24")
  r.setStyle(addBtn, "padding", "12")
  r.setStyle(addBtn, "width", "48")
  r.setStyle(addBtn, "height", "48")
  r.setStyle(addBtn, "align-items", "center")
  r.setStyle(addBtn, "justify-content", "center")

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
  let list = r.createElement("div")
  r.setStyle(list, "flex-grow", "1")
  r.setStyle(list, "gap", "8")
  r.setStyle(list, "padding", "8")
  r.setStyle(list, "margin-top", "4")
  list

proc createTaskRow*[R, E](r: R; task: proc(): TaskData;
                           onToggle, onDelete: proc()): E =
  let row = r.createElement("div")
  r.setStyle(row, "flex-direction", "row")
  r.setStyle(row, "align-items", "center")
  r.setStyle(row, "padding", "12")
  r.setStyle(row, "background-color", themeColor("surface"))
  r.setStyle(row, "border-radius", "12")

  # Checkbox
  let checkbox = r.createElement("div")
  r.setStyle(checkbox, "width", "24")
  r.setStyle(checkbox, "height", "24")
  r.setStyle(checkbox, "border-radius", "6")
  r.setStyle(checkbox, "align-items", "center")
  r.setStyle(checkbox, "justify-content", "center")

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
  let label = r.createElement("span")
  r.setStyle(label, "font-size", "16")
  r.setStyle(label, "flex-grow", "1")
  r.setStyle(label, "height", "20")
  r.setStyle(label, "margin-left", "12")

  createRenderEffect proc() =
    let t = task()
    r.setTextContent(label, t.text)
    if t.completed:
      r.setStyle(label, "color", themeColor("text-disabled"))
    else:
      r.setStyle(label, "color", themeColor("text-primary"))

  # Delete button
  let delBtn = r.createElement("div")
  r.setStyle(delBtn, "padding", "8")
  r.setStyle(delBtn, "align-items", "center")
  r.setStyle(delBtn, "justify-content", "center")

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
  let empty = r.createElement("div")
  r.setStyle(empty, "flex-grow", "1")
  r.setStyle(empty, "align-items", "center")
  r.setStyle(empty, "justify-content", "center")

  let emptyText = r.createElement("span")
  r.setStyle(emptyText, "color", themeColor("text-secondary"))
  r.setStyle(emptyText, "font-size", "18")
  r.setStyle(emptyText, "text-align", "center")
  r.setStyle(emptyText, "height", "52")
  r.setStyle(emptyText, "width", "300")
  r.setStyle(emptyText, "align-self", "center")
  r.setTextContent(emptyText, message)
  r.appendChild(empty, emptyText)
  empty

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  let bar = r.createElement("div")
  r.setStyle(bar, "flex-direction", "row")
  r.setStyle(bar, "justify-content", "center")
  r.setStyle(bar, "align-items", "center")
  r.setStyle(bar, "gap", "8")
  r.setStyle(bar, "padding", "12")

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let filtCapture = filt

    let btn = r.createElement("div")
    r.setStyle(btn, "padding-top", "8")
    r.setStyle(btn, "padding-bottom", "8")
    r.setStyle(btn, "padding-left", "16")
    r.setStyle(btn, "padding-right", "16")
    r.setStyle(btn, "border-radius", "16")
    r.setStyle(btn, "align-items", "center")
    r.setStyle(btn, "justify-content", "center")

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
  let clearBtn = r.createElement("div")
  r.setStyle(clearBtn, "padding", "8")
  r.setStyle(clearBtn, "align-items", "center")
  r.setStyle(clearBtn, "justify-content", "center")

  let clearText = r.createElement("span")
  r.setStyle(clearText, "font-size", "14")
  r.setStyle(clearText, "height", "18")
  r.setStyle(clearText, "width", "130")
  r.setStyle(clearText, "align-self", "center")
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
