## IsoNim Editor — Views for simulated user project (task manager).
##
## Maps user project ViewModels to visual output via the `ui` DSL.
## These are the components displayed inside the editor's preview pane.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/user_project_vms
import isonim/editor/types
import isonim/components/task_manager
import isonim/theming/theme

proc renderTaskRow*[R, E](r: R; vm: TaskRowVM;
                           onToggle, onDelete: proc()): E =
  let row = ui(r):
    tdiv(class = "flex flex-row items-center p-3 rounded-xl")

  # Map display state to visual properties
  createRenderEffect proc() =
    case vm.displayState.val
    of tdsActive:
      r.setStyle(row, "opacity", "1")
      r.setStyle(row, "background-color", themeColor("surface"))
    of tdsCompleted:
      r.setStyle(row, "opacity", "0.6")
      r.setStyle(row, "background-color", themeColor("surface"))
    of tdsEditing:
      r.setStyle(row, "background-color", "#1E3A5F")
    of tdsSaving:
      r.setStyle(row, "opacity", "0.4")
      r.setStyle(row, "background-color", themeColor("surface"))
    of tdsError:
      r.setStyle(row, "background-color", themeColor("surface"))
      r.setStyle(row, "border-color", themeColor("error"))
      r.setStyle(row, "border-width", "2")

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
    if vm.isCompleted.val:
      r.setStyle(checkbox, "background-color", themeColor("primary"))
      r.setStyle(check, "display", "flex")
    else:
      r.setStyle(checkbox, "background-color", "transparent")
      r.setStyle(checkbox, "border-color", themeColor("border"))
      r.setStyle(checkbox, "border-width", "2")
      r.setStyle(check, "display", "none")

  r.addEventListener(checkbox, "click", onToggle)

  # Label
  let label = ui(r):
    span(class = "text-base grow h-5 ml-3")

  createRenderEffect proc() =
    r.setTextContent(label, vm.task.val.text)
    if vm.isCompleted.val:
      r.setStyle(label, "text-decoration", "line-through")
      r.setStyle(label, "color", themeColor("text-disabled"))
    else:
      r.setStyle(label, "text-decoration", "none")
      r.setStyle(label, "color", themeColor("text-primary"))

  # Delete button
  let delBtn = ui(r):
    tdiv(class = "p-2 items-center justify-center")
  let delIcon = r.createTextNode("\u2715")
  r.setStyle(delIcon, "color", themeColor("error"))
  r.setStyle(delIcon, "font-size", "20")
  r.setStyle(delIcon, "text-align", "center")
  r.appendChild(delBtn, delIcon)
  r.addEventListener(delBtn, "click", onDelete)

  r.appendChild(row, checkbox)
  r.appendChild(row, label)
  r.appendChild(row, delBtn)
  row

proc renderTaskApp*[R, E](r: R; vm: TaskAppVM): E =
  ## Renders the full task app from TaskAppVM.
  setTheme(isoTheme())

  let root = ui(r):
    tdiv(class = "p-4 bg-slate-50")

  # Title
  let title = ui(r):
    span(class = "text-4xl font-bold h-10")
  r.setTextContent(title, "Tasks")
  r.setStyle(title, "color", themeColor("text-primary"))
  r.appendChild(root, title)

  # Input row
  let inputRow = ui(r):
    tdiv(class = "flex flex-row p-2 gap-2")

  let input = r.createElement("input")
  r.setStyle(input, "background-color", "#F1F5F9")
  r.setStyle(input, "border-radius", "8")
  r.setStyle(input, "padding", "12")
  r.setStyle(input, "font-size", "16")
  r.setStyle(input, "flex-grow", "1")
  r.setStyle(input, "height", "48")
  r.setAttribute(input, "placeholder", vm.input.placeholder)

  let addBtn = ui(r):
    tdiv(class = "w-12 h-12 rounded-full items-center justify-center")
  r.setStyle(addBtn, "background-color", themeColor("primary"))
  let plusIcon = r.createTextNode("+")
  r.setStyle(plusIcon, "color", "#FFFFFF")
  r.setStyle(plusIcon, "font-size", "24")
  r.setStyle(plusIcon, "text-align", "center")
  r.appendChild(addBtn, plusIcon)

  r.appendChild(inputRow, input)
  r.appendChild(inputRow, addBtn)
  r.appendChild(root, inputRow)

  # Task list / empty state
  show(r, root,
    proc(): bool = vm.hasTasks.val,
    proc(): E =
      let list = ui(r):
        tdiv(class = "grow gap-2 p-2 mt-1")
      forEachKeyed(r, list,
        proc(): seq[TaskData] = vm.store.filteredTasks.val,
        proc(item: proc(): TaskData, index: proc(): int): E =
          let taskVM = createTaskRowVM(item())
          renderTaskRow[R, E](r, taskVM,
            onToggle = proc() = vm.store.toggleTask(item().id),
            onDelete = proc() = vm.store.deleteTask(item().id))
      )
      list
    ,
    proc(): E =
      let empty = ui(r):
        tdiv(class = "grow items-center justify-center")
      let emptyText = ui(r):
        span(class = "text-lg text-center self-center")
      r.setStyle(emptyText, "color", themeColor("text-secondary"))
      r.setStyle(emptyText, "width", "300")
      r.setStyle(emptyText, "height", "52")
      r.setTextContent(emptyText, "No tasks yet.\nTap + to add one.")
      r.appendChild(empty, emptyText)
      empty
  )

  # Filter bar
  let filterBar = ui(r):
    tdiv(class = "flex flex-row justify-center items-center gap-2 p-3")

  createRenderEffect proc() =
    let options = vm.filterBar.options.val
    # Reactive filter pill styling handled by effect

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let filtCapture = filt

    let btn = ui(r):
      tdiv(class = "py-2 px-4 rounded-2xl items-center justify-center")

    let text = r.createTextNode(label)
    r.setStyle(text, "font-size", "14")
    r.appendChild(btn, text)

    createRenderEffect proc() =
      if vm.filterBar.currentFilter.val == filtCapture:
        r.setStyle(btn, "background-color", themeColor("primary"))
        r.setStyle(text, "color", "#FFFFFF")
      else:
        r.setStyle(btn, "background-color", "transparent")
        r.setStyle(text, "color", themeColor("text-secondary"))

    r.addEventListener(btn, "click", proc() = vm.store.setFilter(filtCapture))
    r.appendChild(filterBar, btn)

  r.appendChild(root, filterBar)

  # Clear completed
  let clearBtn = ui(r):
    tdiv(class = "p-2 items-center justify-center")
  let clearText = ui(r):
    span(class = "text-sm self-center")
  r.setStyle(clearText, "width", "130")
  r.setTextContent(clearText, "Clear Completed")
  r.appendChild(clearBtn, clearText)

  createRenderEffect proc() =
    if vm.hasCompletedTasks.val:
      r.setStyle(clearText, "color", themeColor("error"))
    else:
      r.setStyle(clearText, "color", themeColor("text-disabled"))

  r.addEventListener(clearBtn, "click", proc() =
    if vm.hasCompletedTasks.val:
      vm.store.clearCompleted()
  )

  r.appendChild(root, clearBtn)
  root
