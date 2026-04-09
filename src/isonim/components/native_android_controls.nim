## Native Android controls — renders task app components using Android-idiomatic
## Material Design controls for a polished native look.
##
## Selected at compile time when -d:nativeControls and -d:android are active.
## Same proc signatures as branded_controls.nim / native_ios_controls.nim.
##
## Control choices:
##   - MaterialButton for filter segments
##   - Switch for task toggle
##   - MaterialButton for add/delete/clear actions

import isonim/components/task_manager
import isonim/theming/theme
import isonim/core/[computation]

proc initTheme*() =
  setTheme(nativeTheme())

proc createAppRoot*[R, E](r: R): E =
  let root = r.createElement("div")
  r.setStyle(root, "padding", "16")
  root

proc createTitle*[R, E](r: R; text: string): E =
  let title = r.createElement("h1")
  r.setStyle(title, "height", "40")
  r.setTextContent(title, text)
  title

proc createInputRow*[R, E](r: R; placeholder: string;
                            onAdd: proc(text: string)): E =
  let row = r.createElement("div")
  r.setStyle(row, "flex-direction", "row")
  r.setStyle(row, "padding", "8")
  r.setStyle(row, "gap", "8")

  let input = r.createElement("input")
  r.setStyle(input, "flex-grow", "1")
  r.setStyle(input, "height", "48")
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = r.createElement("button")
  r.setStyle(addBtn, "width", "48")
  r.setStyle(addBtn, "height", "48")
  r.setStyle(addBtn, "font-size", "24")
  r.setTextContent(addBtn, "+")

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

  let toggle = r.createElement("switch")
  r.setStyle(toggle, "width", "52")
  r.setStyle(toggle, "height", "32")
  createRenderEffect proc() =
    r.setAttribute(toggle, "checked", $task().completed)
  r.addEventListener(toggle, "click", onToggle)

  let label = r.createElement("span")
  r.setStyle(label, "font-size", "16")
  r.setStyle(label, "flex-grow", "1")
  r.setStyle(label, "height", "20")
  r.setStyle(label, "margin-left", "12")
  createRenderEffect proc() =
    r.setTextContent(label, task().text)

  let delBtn = r.createElement("button")
  r.setStyle(delBtn, "height", "36")
  r.setStyle(delBtn, "width", "60")
  r.setTextContent(delBtn, "\u2715")
  r.setStyle(delBtn, "color", "#F44336")
  r.addEventListener(delBtn, "click", onDelete)

  r.appendChild(row, toggle)
  r.appendChild(row, label)
  r.appendChild(row, delBtn)
  row

proc createEmptyState*[R, E](r: R; message: string): E =
  let wrapper = r.createElement("div")
  r.setStyle(wrapper, "flex-grow", "1")
  r.setStyle(wrapper, "align-items", "center")
  r.setStyle(wrapper, "justify-content", "center")

  let text = r.createElement("p")
  r.setStyle(text, "font-size", "16")
  r.setStyle(text, "height", "52")
  r.setStyle(text, "width", "300")
  r.setStyle(text, "align-self", "center")
  r.setStyle(text, "text-align", "center")
  r.setTextContent(text, message)
  r.appendChild(wrapper, text)
  wrapper

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  let bar = r.createElement("segmented")
  r.setStyle(bar, "flex-direction", "row")
  r.setStyle(bar, "justify-content", "center")
  r.setStyle(bar, "align-items", "center")
  r.setStyle(bar, "gap", "8")
  r.setStyle(bar, "height", "68")
  r.setStyle(bar, "padding", "12")

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let filtCapture = filt
    let btnWidth = max(label.len * 12 + 40, 80)

    let segment = r.createElement("button")
    r.setStyle(segment, "height", "44")
    r.setStyle(segment, "width", $btnWidth)
    r.setTextContent(segment, label)

    createRenderEffect proc() =
      r.setAttribute(segment, "selected", $(currentFilter() == filtCapture))

    r.addEventListener(segment, "click", proc() = onFilter(filtCapture))
    r.appendChild(bar, segment)

  bar

proc createClearButton*[R, E](r: R; hasCompleted: proc(): bool;
                               onClear: proc()): E =
  let clearBtn = r.createElement("button")
  r.setStyle(clearBtn, "height", "44")
  r.setStyle(clearBtn, "width", "220")
  r.setStyle(clearBtn, "align-self", "center")
  r.setTextContent(clearBtn, "Clear Completed")

  createRenderEffect proc() =
    if hasCompleted():
      r.setStyle(clearBtn, "color", "#F44336")
    else:
      r.setAttribute(clearBtn, "enabled", "false")

  r.addEventListener(clearBtn, "click", proc() =
    if hasCompleted():
      onClear()
  )
  clearBtn
