## Native iOS controls — renders task app components using iOS-idiomatic UIKit
## controls for a polished native look.
##
## Selected at compile time when -d:nativeControls and -d:ios are active.
## Same proc signatures as branded_controls.nim / native_android_controls.nim.
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
  r.setStyle(input, "height", "44")
  r.setStyle(input, "border-radius", "10")
  r.setStyle(input, "border-color", "#C7C7CC")
  r.setStyle(input, "border-width", "1")
  r.setStyle(input, "font-size", "17")
  r.setStyle(input, "background-color", "#FFFFFF")
  r.setAttribute(input, "placeholder", placeholder)

  let addBtn = r.createElement("button")
  r.setStyle(addBtn, "width", "44")
  r.setStyle(addBtn, "height", "44")
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
  r.setStyle(list, "gap", "4")
  r.setStyle(list, "padding", "4")
  r.setStyle(list, "margin-top", "8")
  list

proc createTaskRow*[R, E](r: R; task: proc(): TaskData;
                           onToggle, onDelete: proc()): E =
  let row = r.createElement("div")
  r.setStyle(row, "flex-direction", "row")
  r.setStyle(row, "align-items", "center")
  r.setStyle(row, "padding", "12")
  r.setStyle(row, "background-color", "#F2F2F7")
  r.setStyle(row, "border-radius", "10")

  let toggle = r.createElement("switch")
  r.setStyle(toggle, "width", "51")
  r.setStyle(toggle, "height", "31")
  createRenderEffect proc() =
    r.setAttribute(toggle, "checked", $task().completed)
  r.addEventListener(toggle, "click", onToggle)

  let label = r.createElement("span")
  r.setStyle(label, "font-size", "17")
  r.setStyle(label, "flex-grow", "1")
  r.setStyle(label, "height", "22")
  r.setStyle(label, "margin-left", "12")
  createRenderEffect proc() =
    let t = task()
    r.setTextContent(label, t.text)
    if t.completed:
      r.setStyle(label, "color", "#8E8E93")
    else:
      r.setStyle(label, "color", "#000000")

  let delBtn = r.createElement("button")
  r.setStyle(delBtn, "height", "32")
  r.setStyle(delBtn, "width", "60")
  r.setTextContent(delBtn, "\u2715")
  r.setStyle(delBtn, "color", "#FF3B30")
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
  r.setStyle(text, "font-size", "17")
  r.setStyle(text, "color", "#8E8E93")
  r.setStyle(text, "height", "52")
  r.setStyle(text, "width", "300")
  r.setStyle(text, "align-self", "center")
  r.setStyle(text, "text-align", "center")
  r.setTextContent(text, message)
  r.appendChild(wrapper, text)
  wrapper

proc createFilterBar*[R, E](r: R; currentFilter: proc(): FilterMode;
                             onFilter: proc(f: FilterMode)): E =
  ## Single UISegmentedControl — the native iOS way to pick a filter.
  let wrapper = r.createElement("div")
  r.setStyle(wrapper, "align-items", "center")
  r.setStyle(wrapper, "padding", "8")
  r.setStyle(wrapper, "height", "52")

  let seg = r.createElement("segmented")
  r.setStyle(seg, "height", "32")
  r.setStyle(seg, "width", "280")
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
  let clearBtn = r.createElement("button")
  r.setStyle(clearBtn, "height", "36")
  r.setStyle(clearBtn, "width", "180")
  r.setStyle(clearBtn, "align-self", "center")
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
