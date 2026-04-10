## Native iOS controls — renders task app components using iOS-idiomatic UIKit
## controls for a polished native look.
##
## Selected at compile time when -d:nativeControls and -d:ios are active.
## Same proc signatures as branded_controls.nim / native_android_controls.nim.
##
## Uses the `ui` DSL macro for element creation, same as branded_controls.
##
## Control choices:
##   - UISegmentedControl for filter bar
##   - UISwitch for task toggle
##   - UIButton (system) for actions
##   - UITextField with rounded-rect border for input

import std/strutils
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
    input(flex_grow = "1", height = "44", border_radius = "10",
          border_color = "#C7C7CC", border_width = "1",
          font_size = "17", background_color = "#FFFFFF")
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = ui(r):
    button(width = "44", height = "44", font_size = "24")
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
    tdiv(flex_grow = "1", gap = "4", padding = "4", margin_top = "8")

proc createTaskRow*[R, E](r: R; task: proc(): TaskData;
                           onToggle, onDelete: proc()): E =
  let row = ui(r):
    tdiv(flex_direction = "row", align_items = "center", padding = "12",
         background_color = "#F2F2F7", border_radius = "10")

  let toggle = ui(r):
    switch(width = "51", height = "31")
  createRenderEffect proc() =
    r.setAttribute(toggle, "checked", $task().completed)
  r.addEventListener(toggle, "click", onToggle)

  let label = ui(r):
    span(font_size = "17", flex_grow = "1", height = "22", margin_left = "12")
  createRenderEffect proc() =
    let t = task()
    r.setTextContent(label, t.text)
    if t.completed:
      r.setStyle(label, "color", "#8E8E93")
    else:
      r.setStyle(label, "color", "#000000")

  let delBtn = ui(r):
    button(height = "32", width = "60", color = "#FF3B30")
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
    p(font_size = "17", color = "#8E8E93", height = "52", width = "300",
      align_self = "center", text_align = "center")
  r.setTextContent(text, message)
  r.appendChild(wrapper, text)
  wrapper

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  let wrapper = ui(r):
    tdiv(align_items = "center", padding = "8", height = "52")

  let seg = ui(r):
    segmented(height = "32", width = "280")
  r.setAttribute(seg, "segments", "All,Active,Completed")

  createRenderEffect proc() =
    let idx = case currentFilter()
      of fmAll: 0
      of fmActive: 1
      of fmCompleted: 2
    r.setAttribute(seg, "selectedIndex", $idx)

  r.addEventListener(seg, "click", proc() =
    let selIdx = r.getAttribute(seg, "selectedIndex")
    let selInt = try: parseInt(selIdx) except: 0
    let f = case selInt
      of 1: fmActive
      of 2: fmCompleted
      else: fmAll
    onFilter(f)
  )

  r.appendChild(wrapper, seg)
  wrapper

proc createClearButton*[R, E](r: R; hasCompleted: proc(): bool;
                               onClear: proc()): E =
  let clearBtn = ui(r):
    button(height = "36", width = "180", align_self = "center")
  r.setTextContent(clearBtn, "Clear Completed")

  createRenderEffect proc() =
    if hasCompleted():
      r.setStyle(clearBtn, "color", "#FF3B30")
    else:
      r.setStyle(clearBtn, "color", "#8E8E93")
      r.setAttribute(clearBtn, "enabled", "false")

  r.addEventListener(clearBtn, "click", proc() =
    if hasCompleted():
      onClear()
  )
  clearBtn
