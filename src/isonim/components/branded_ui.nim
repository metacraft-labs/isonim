## Branded task manager UI — renders identically on all platforms.
## Uses only generic RendererBackend procs (createElement, setStyle, etc.)
## with theme tokens for colors and explicit pixel values for spacing.

import isonim/components/task_manager
import isonim/theming/theme

proc renderTaskRow*[R, E](r: R; task: TaskData;
                           onToggle: proc(); onDelete: proc()): E =
  let row = r.createElement("div")
  r.setStyle(row, "flex-direction", "row")
  r.setStyle(row, "align-items", "center")
  r.setStyle(row, "padding", "12")
  r.setStyle(row, "background-color", themeColor("surface"))
  r.setStyle(row, "border-radius", "8")

  # Checkbox (styled div)
  let checkbox = r.createElement("div")
  r.setStyle(checkbox, "width", "28")
  r.setStyle(checkbox, "height", "28")
  r.setStyle(checkbox, "border-radius", "6")
  if task.completed:
    r.setStyle(checkbox, "background-color", themeColor("primary"))
    let check = r.createTextNode("\u2713")
    r.setStyle(check, "color", "#FFFFFF")
    r.setStyle(check, "font-size", "16")
    r.appendChild(checkbox, check)
  else:
    r.setStyle(checkbox, "border-color", themeColor("border"))
    # border style via background-color with transparency
    r.setStyle(checkbox, "background-color", "transparent")
  r.addEventListener(checkbox, "click", onToggle)

  # Text label
  let label = r.createElement("span")
  r.setTextContent(label, task.text)
  r.setStyle(label, "font-size", "16")
  if task.completed:
    r.setStyle(label, "color", themeColor("text-disabled"))
  else:
    r.setStyle(label, "color", themeColor("text-primary"))

  # Delete button
  let delBtn = r.createElement("div")
  r.setStyle(delBtn, "padding", "8")
  let delIcon = r.createTextNode("\u2715")
  r.setStyle(delIcon, "color", themeColor("error"))
  r.setStyle(delIcon, "font-size", "18")
  r.appendChild(delBtn, delIcon)
  r.addEventListener(delBtn, "click", onDelete)

  r.appendChild(row, checkbox)
  r.appendChild(row, label)
  r.appendChild(row, delBtn)
  row

proc makeIdCallback*(handler: proc(id: int); id: int): proc() =
  ## Factory to capture integer id correctly in closures.
  result = proc() = handler(id)

proc makeFilterCallback*(onFilter: proc(f: FilterMode); f: FilterMode): proc() =
  ## Factory to capture filter mode value correctly in closures.
  result = proc() = onFilter(f)

proc renderFilterButton*[R, E](r: R; label: string; active: bool;
                                onClick: proc()): E =
  let btn = r.createElement("div")
  r.setStyle(btn, "padding", "8")
  r.setStyle(btn, "border-radius", "16")
  if active:
    r.setStyle(btn, "background-color", themeColor("primary"))
  let text = r.createTextNode(label)
  if active:
    r.setStyle(text, "color", "#FFFFFF")
  else:
    r.setStyle(text, "color", themeColor("text-secondary"))
  r.setStyle(text, "font-size", "14")
  r.appendChild(btn, text)
  r.addEventListener(btn, "click", onClick)
  btn

proc renderTaskApp*[R, E](r: R; state: TaskAppState;
                           onAdd: proc(text: string);
                           onToggle: proc(id: int);
                           onDelete: proc(id: int);
                           onFilter: proc(f: FilterMode);
                           onClear: proc()): E =
  setTheme(isoTheme())  # Ensure branded theme is active

  let root = r.createElement("div")
  r.setStyle(root, "background-color", themeColor("background"))
  r.setStyle(root, "padding", "16")

  # Title
  let title = r.createElement("span")
  r.setTextContent(title, "Tasks")
  r.setStyle(title, "font-size", "32")
  r.setStyle(title, "color", themeColor("text-primary"))
  r.appendChild(root, title)

  # Input row
  let inputRow = r.createElement("div")
  r.setStyle(inputRow, "flex-direction", "row")
  r.setStyle(inputRow, "padding", "8")
  r.setStyle(inputRow, "gap", "8")

  let input = r.createElement("input")
  r.setAttribute(input, "placeholder", "What needs to be done?")
  r.setStyle(input, "background-color", themeColor("surface"))
  r.setStyle(input, "border-radius", "8")
  r.setStyle(input, "padding", "12")
  r.setStyle(input, "font-size", "16")
  r.setStyle(input, "color", themeColor("text-primary"))

  let addBtn = r.createElement("div")
  r.setStyle(addBtn, "background-color", themeColor("primary"))
  r.setStyle(addBtn, "border-radius", "8")
  r.setStyle(addBtn, "padding", "12")
  r.setStyle(addBtn, "width", "48")
  r.setStyle(addBtn, "height", "48")
  r.setStyle(addBtn, "align-items", "center")
  r.setStyle(addBtn, "justify-content", "center")
  let plusIcon = r.createTextNode("+")
  r.setStyle(plusIcon, "color", "#FFFFFF")
  r.setStyle(plusIcon, "font-size", "24")
  r.appendChild(addBtn, plusIcon)

  r.appendChild(inputRow, input)
  r.appendChild(inputRow, addBtn)
  r.appendChild(root, inputRow)

  # Task list
  let tasks = state.filteredTasks()
  if tasks.len == 0:
    let empty = r.createElement("div")
    r.setStyle(empty, "padding", "48")
    r.setStyle(empty, "align-items", "center")
    let emptyText = r.createElement("span")
    r.setTextContent(emptyText, "No tasks yet.\nTap + to add one.")
    r.setStyle(emptyText, "color", themeColor("text-secondary"))
    r.setStyle(emptyText, "font-size", "18")
    r.appendChild(empty, emptyText)
    r.appendChild(root, empty)
  else:
    let list = r.createElement("div")
    r.setStyle(list, "gap", "8")
    r.setStyle(list, "padding", "8")
    for task in tasks:
      let row = renderTaskRow[R, E](r, task,
        makeIdCallback(onToggle, task.id),
        makeIdCallback(onDelete, task.id))
      r.appendChild(list, row)
    r.appendChild(root, list)

  # Filter bar
  let filterBar = r.createElement("div")
  r.setStyle(filterBar, "flex-direction", "row")
  r.setStyle(filterBar, "justify-content", "center")
  r.setStyle(filterBar, "gap", "4")
  r.setStyle(filterBar, "padding", "12")

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let btn = renderFilterButton[R, E](r, label, state.filter == filt,
      makeFilterCallback(onFilter, filt))
    r.appendChild(filterBar, btn)

  r.appendChild(root, filterBar)

  # Clear completed button
  if state.completedCount() > 0:
    let clearBtn = r.createElement("div")
    r.setStyle(clearBtn, "padding", "12")
    r.setStyle(clearBtn, "align-items", "center")
    let clearText = r.createElement("span")
    r.setTextContent(clearText, "Clear Completed")
    r.setStyle(clearText, "color", themeColor("error"))
    r.setStyle(clearText, "font-size", "14")
    r.appendChild(clearBtn, clearText)
    r.addEventListener(clearBtn, "click", onClear)
    r.appendChild(root, clearBtn)

  root
