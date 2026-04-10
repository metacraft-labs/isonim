## Native Android controls — renders task app components using Android-idiomatic
## Material Design controls for a polished native look.
##
## Selected at compile time when -d:nativeControls and -d:android are active.
## Same proc signatures as branded_controls.nim / native_ios_controls.nim.
##
## Uses the `ui` DSL macro for element creation, same as branded_controls.

import isonim/components/task_manager
import isonim/theming/theme
import isonim/core/[computation]
import isonim/dsl/ui

proc initTheme*() =
  setTheme(nativeTheme())

proc createAppRoot*[R, E](r: R): E =
  ui(r):
    tdiv(padding = "16")

proc createTitle*[R, E](r: R; text: string): E =
  let el = ui(r):
    h1(height = "40")
  r.setTextContent(el, text)
  el

proc createInputRow*[R, E](r: R; placeholder: string;
                            onAdd: proc(text: string)): E =
  let row = ui(r):
    tdiv(flex_direction = "row", padding = "8", gap = "8")

  let input = ui(r):
    input(flex_grow = "1", height = "48")
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = ui(r):
    button(width = "48", height = "48", font_size = "24")
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
  ui(r):
    tdiv(flex_grow = "1", gap = "8", padding = "8", margin_top = "4")

proc createTaskRow*[R, E](r: R; task: proc(): TaskData;
                           onToggle, onDelete: proc()): E =
  let row = ui(r):
    tdiv(flex_direction = "row", align_items = "center", padding = "12")

  let toggle = ui(r):
    switch(width = "52", height = "32")
  createRenderEffect proc() =
    r.setAttribute(toggle, "checked", $task().completed)
  r.addEventListener(toggle, "click", onToggle)

  let label = ui(r):
    span(font_size = "16", flex_grow = "1", height = "20", margin_left = "12")
  createRenderEffect proc() =
    r.setTextContent(label, task().text)

  let delBtn = ui(r):
    button(height = "36", width = "60", color = "#F44336")
  r.setTextContent(delBtn, "\u2715")
  r.addEventListener(delBtn, "click", onDelete)

  r.appendChild(row, toggle)
  r.appendChild(row, label)
  r.appendChild(row, delBtn)
  row

proc createEmptyState*[R, E](r: R; message: string): E =
  let wrapper = ui(r):
    tdiv(flex_grow = "1", align_items = "center", justify_content = "center")

  let text = ui(r):
    p(font_size = "16", height = "52", width = "300",
      align_self = "center", text_align = "center")
  r.setTextContent(text, message)
  r.appendChild(wrapper, text)
  wrapper

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  let bar = ui(r):
    segmented(flex_direction = "row", justify_content = "center",
              align_items = "center", gap = "8", height = "68", padding = "12")

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let filtCapture = filt
    let btnWidth = max(label.len * 12 + 40, 80)

    let segment = ui(r):
      button(height = "44", width = $btnWidth)
    r.setTextContent(segment, label)

    createRenderEffect proc() =
      r.setAttribute(segment, "selected", $(currentFilter() == filtCapture))

    r.addEventListener(segment, "click", proc() = onFilter(filtCapture))
    r.appendChild(bar, segment)

  bar

proc createClearButton*[R, E](r: R; hasCompleted: proc(): bool;
                               onClear: proc()): E =
  let clearBtn = ui(r):
    button(height = "44", width = "220", align_self = "center")
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
