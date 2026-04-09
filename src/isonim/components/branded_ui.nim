## Branded task manager UI — renders identically on all platforms.
## Uses only generic RendererBackend procs (createElement, setStyle, etc.)
## with theme tokens for colors and explicit pixel values for spacing.
##
## When a LayoutEngine is provided, each element is also registered in a
## parallel Yoga tree so that layout can be computed after rendering.

import isonim/components/task_manager
import isonim/theming/theme
import isonim/layout/layout_engine

# ---------------------------------------------------------------------------
# Internal helpers — conditionally register with layout engine
# ---------------------------------------------------------------------------

proc mkElem[R, E](r: R; tag: string; engine: LayoutEngine;
                   styles: openArray[(string, string)]): E =
  let elem = r.createElement(tag)
  if engine != nil:
    let h = cast[int64](cast[pointer](elem))
    discard engine.registerNode(h)
    for (prop, value) in styles:
      engine.setLayoutStyle(h, prop, value)
  for (prop, value) in styles:
    r.setStyle(elem, prop, value)
  elem

proc mkText[R, E](r: R; text: string; engine: LayoutEngine;
                    styles: openArray[(string, string)]): E =
  let elem = r.createTextNode(text)
  if engine != nil:
    let h = cast[int64](cast[pointer](elem))
    discard engine.registerNode(h)
    for (prop, value) in styles:
      engine.setLayoutStyle(h, prop, value)
  for (prop, value) in styles:
    r.setStyle(elem, prop, value)
  elem

proc mkAppend[R, E](r: R; parent, child: E; engine: LayoutEngine) =
  r.appendChild(parent, child)
  if engine != nil:
    engine.addChild(cast[int64](cast[pointer](parent)),
                     cast[int64](cast[pointer](child)))

# Extra style on an already-created element
proc mkStyle[R, E](r: R; elem: E; engine: LayoutEngine;
                    prop, value: string) =
  r.setStyle(elem, prop, value)
  if engine != nil:
    engine.setLayoutStyle(cast[int64](cast[pointer](elem)), prop, value)

# ---------------------------------------------------------------------------
# Public render procs
# ---------------------------------------------------------------------------

proc renderTaskRow*[R, E](r: R; task: TaskData;
                           onToggle: proc(); onDelete: proc();
                           engine: LayoutEngine = nil): E =
  let row = mkElem[R, E](r, "div", engine, {
    "flex-direction": "row",
    "align-items": "center",
    "padding": "12",
    "background-color": themeColor("surface"),
    "border-radius": "12"})

  # Checkbox (styled div)
  let checkbox = mkElem[R, E](r, "div", engine, {
    "width": "24",
    "height": "24",
    "border-radius": "6",
    "align-items": "center",
    "justify-content": "center"})
  if task.completed:
    mkStyle[R, E](r, checkbox, engine, "background-color", themeColor("primary"))
    let check = mkText[R, E](r, "\u2713", engine, {
      "color": "#FFFFFF",
      "font-size": "14",
      "text-align": "center",
      "height": "18",
      "width": "18"})
    mkAppend[R, E](r, checkbox, check, engine)
  else:
    mkStyle[R, E](r, checkbox, engine, "border-color", themeColor("border"))
    mkStyle[R, E](r, checkbox, engine, "border-width", "2")
    mkStyle[R, E](r, checkbox, engine, "background-color", "transparent")
  r.addEventListener(checkbox, "click", onToggle)

  # Text label — flex-grow so it fills remaining space
  let label = mkElem[R, E](r, "span", engine, {
    "font-size": "16",
    "flex-grow": "1",
    "height": "20",
    "margin-left": "12"})
  r.setTextContent(label, task.text)
  if task.completed:
    mkStyle[R, E](r, label, engine, "color", themeColor("text-disabled"))
  else:
    mkStyle[R, E](r, label, engine, "color", themeColor("text-primary"))

  # Delete button
  let delBtn = mkElem[R, E](r, "div", engine, {
    "padding": "8",
    "align-items": "center",
    "justify-content": "center"})
  let delIcon = mkText[R, E](r, "\u2715", engine, {
    "color": themeColor("error"),
    "font-size": "20",
    "text-align": "center",
    "height": "24",
    "width": "24"})
  mkAppend[R, E](r, delBtn, delIcon, engine)
  r.addEventListener(delBtn, "click", onDelete)

  mkAppend[R, E](r, row, checkbox, engine)
  mkAppend[R, E](r, row, label, engine)
  mkAppend[R, E](r, row, delBtn, engine)
  row

proc makeIdCallback*(handler: proc(id: int); id: int): proc() =
  ## Factory to capture integer id correctly in closures.
  result = proc() = handler(id)

proc makeFilterCallback*(onFilter: proc(f: FilterMode); f: FilterMode): proc() =
  ## Factory to capture filter mode value correctly in closures.
  result = proc() = onFilter(f)

proc renderFilterButton*[R, E](r: R; label: string; active: bool;
                                onClick: proc();
                                engine: LayoutEngine = nil): E =
  ## Each filter pill gets explicit directional padding so the text has room.
  let btn = mkElem[R, E](r, "div", engine, {
    "padding-top": "8",
    "padding-bottom": "8",
    "padding-left": "16",
    "padding-right": "16",
    "border-radius": "16",
    "align-items": "center",
    "justify-content": "center"})
  if active:
    mkStyle[R, E](r, btn, engine, "background-color", themeColor("primary"))
  # Give text node explicit width based on character count (~9px per char at font-size 14)
  let textWidth = max(label.len * 9, 30)
  let text = mkText[R, E](r, label, engine, {
    "font-size": "14",
    "height": "18",
    "width": $textWidth})
  if active:
    mkStyle[R, E](r, text, engine, "color", "#FFFFFF")
  else:
    mkStyle[R, E](r, text, engine, "color", themeColor("text-secondary"))
  mkAppend[R, E](r, btn, text, engine)
  r.addEventListener(btn, "click", onClick)
  btn

proc renderTaskApp*[R, E](r: R; state: TaskAppState;
                           onAdd: proc(text: string);
                           onToggle: proc(id: int);
                           onDelete: proc(id: int);
                           onFilter: proc(f: FilterMode);
                           onClear: proc();
                           engine: LayoutEngine = nil): E =
  setTheme(isoTheme())  # Ensure branded theme is active

  let root = mkElem[R, E](r, "div", engine, {
    "background-color": themeColor("background"),
    "padding": "16"})

  # Title
  let title = mkElem[R, E](r, "span", engine, {
    "font-size": "32",
    "font-weight": "bold",
    "height": "40"})
  r.setTextContent(title, "Tasks")
  mkStyle[R, E](r, title, engine, "color", themeColor("text-primary"))
  mkAppend[R, E](r, root, title, engine)

  # Input row
  let inputRow = mkElem[R, E](r, "div", engine, {
    "flex-direction": "row",
    "padding": "8",
    "gap": "8"})

  let input = mkElem[R, E](r, "input", engine, {
    "background-color": "#F1F5F9",
    "border-radius": "8",
    "padding": "12",
    "font-size": "16",
    "color": themeColor("text-primary"),
    "flex-grow": "1",
    "height": "48"})
  r.setAttribute(input, "placeholder", "What needs to be done?")

  let addBtn = mkElem[R, E](r, "div", engine, {
    "background-color": themeColor("primary"),
    "border-radius": "24",
    "padding": "12",
    "width": "48",
    "height": "48",
    "align-items": "center",
    "justify-content": "center"})
  let plusIcon = mkText[R, E](r, "+", engine, {
    "color": "#FFFFFF",
    "font-size": "24",
    "text-align": "center",
    "height": "28",
    "width": "28"})
  mkAppend[R, E](r, addBtn, plusIcon, engine)

  # Wire add button: read input text, call onAdd, clear input
  r.addEventListener(addBtn, "click", proc() =
    let text = r.textContent(input)
    if text.len > 0:
      onAdd(text)
      r.setTextContent(input, "")
  )

  mkAppend[R, E](r, inputRow, input, engine)
  mkAppend[R, E](r, inputRow, addBtn, engine)
  mkAppend[R, E](r, root, inputRow, engine)

  # Task list — flex-grow to fill available space, pushing filter bar to bottom
  let tasks = state.filteredTasks()
  if tasks.len == 0:
    let empty = mkElem[R, E](r, "div", engine, {
      "flex-grow": "1",
      "align-items": "center",
      "justify-content": "center"})
    let emptyText = mkElem[R, E](r, "span", engine, {
      "color": themeColor("text-secondary"),
      "font-size": "18",
      "text-align": "center",
      "height": "52",
      "width": "300",
      "align-self": "center"})
    r.setTextContent(emptyText, "No tasks yet.\nTap + to add one.")
    mkAppend[R, E](r, empty, emptyText, engine)
    mkAppend[R, E](r, root, empty, engine)
  else:
    let list = mkElem[R, E](r, "div", engine, {
      "flex-grow": "1",
      "gap": "8",
      "padding": "8",
      "margin-top": "4"})
    for task in tasks:
      let row = renderTaskRow[R, E](r, task,
        makeIdCallback(onToggle, task.id),
        makeIdCallback(onDelete, task.id),
        engine)
      mkAppend[R, E](r, list, row, engine)
    mkAppend[R, E](r, root, list, engine)

  # Filter bar — pinned to bottom via flex layout
  let filterBar = mkElem[R, E](r, "div", engine, {
    "flex-direction": "row",
    "justify-content": "center",
    "align-items": "center",
    "gap": "8",
    "padding": "12"})

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let btn = renderFilterButton[R, E](r, label, state.filter == filt,
      makeFilterCallback(onFilter, filt), engine)
    mkAppend[R, E](r, filterBar, btn, engine)

  mkAppend[R, E](r, root, filterBar, engine)

  # Clear completed button
  let clearBtn = mkElem[R, E](r, "div", engine, {
    "padding": "8",
    "align-items": "center",
    "justify-content": "center"})
  let clearText = mkElem[R, E](r, "span", engine, {
    "font-size": "14",
    "height": "18",
    "width": "130",
    "align-self": "center"})
  if state.completedCount() > 0:
    mkStyle[R, E](r, clearText, engine, "color", themeColor("error"))
    r.setTextContent(clearText, "Clear Completed")
    r.addEventListener(clearBtn, "click", onClear)
  else:
    mkStyle[R, E](r, clearText, engine, "color", themeColor("text-disabled"))
    r.setTextContent(clearText, "Clear Completed")
  mkAppend[R, E](r, clearBtn, clearText, engine)
  mkAppend[R, E](r, root, clearBtn, engine)

  root
