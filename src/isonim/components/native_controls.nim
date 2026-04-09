## Native controls — renders task app components using platform-native tags.
##
## This module is the native half of the compile-time control switch.
## It exports the same proc signatures as branded_controls.nim so that
## task_app.nim can import either one transparently.
##
## Instead of styled divs with theme colors, this module emits semantic
## tags (switch, segmented, button, input, h1, p) that the platform
## renderer maps to native controls (UISwitch, UISegmentedControl on iOS;
## Switch, MaterialButton on Android). Styling is kept minimal so the
## platform defaults show through.

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

proc mkAppend[R, E](r: R; parent, child: E; engine: LayoutEngine) =
  r.appendChild(parent, child)
  if engine != nil:
    engine.addChild(cast[int64](cast[pointer](parent)),
                     cast[int64](cast[pointer](child)))

# ---------------------------------------------------------------------------
# Public component procs — native implementations
# ---------------------------------------------------------------------------

proc initTheme*() =
  ## Activate the native theme (platform defaults, no color overrides).
  setTheme(nativeTheme())

proc createAppRoot*[R, E](r: R; engine: LayoutEngine): E =
  ## Transparent root container — the platform provides the background.
  mkElem[R, E](r, "div", engine, {
    "padding": "16"})

proc createTitle*[R, E](r: R; text: string; engine: LayoutEngine): E =
  ## Native heading element — the platform determines font and weight.
  let title = mkElem[R, E](r, "h1", engine, {
    "height": "40"})
  r.setTextContent(title, text)
  title

proc createInputRow*[R, E](r: R; placeholder: string;
                            onAdd: proc(text: string);
                            engine: LayoutEngine): E =
  let row = mkElem[R, E](r, "div", engine, {
    "flex-direction": "row",
    "padding": "8",
    "gap": "8"})

  ## Native input — no custom background or border-radius.
  let input = mkElem[R, E](r, "input", engine, {
    "flex-grow": "1",
    "height": "48"})
  r.setAttribute(input, "placeholder", placeholder)

  ## Native button for adding tasks.
  let addBtn = mkElem[R, E](r, "button", engine, {
    "width": "48",
    "height": "48",
    "font-size": "24"})
  r.setTextContent(addBtn, "+")

  r.addEventListener(addBtn, "click", proc() =
    let text = r.textContent(input)
    if text.len > 0:
      onAdd(text)
      r.setTextContent(input, "")
  )

  mkAppend[R, E](r, row, input, engine)
  mkAppend[R, E](r, row, addBtn, engine)
  row

proc createTaskList*[R, E](r: R; engine: LayoutEngine): E =
  mkElem[R, E](r, "div", engine, {
    "flex-grow": "1",
    "gap": "8",
    "padding": "8",
    "margin-top": "4"})

proc createTaskRow*[R, E](r: R; task: TaskData;
                           onToggle, onDelete: proc();
                           engine: LayoutEngine): E =
  let row = mkElem[R, E](r, "div", engine, {
    "flex-direction": "row",
    "align-items": "center",
    "padding": "12"})

  ## Native toggle/switch — maps to UISwitch on iOS, Switch on Android.
  let toggle = mkElem[R, E](r, "switch", engine, {
    "width": "51",
    "height": "31"})
  r.setAttribute(toggle, "checked", $task.completed)
  r.addEventListener(toggle, "click", onToggle)

  ## Text label — plain span, platform provides font.
  let label = mkElem[R, E](r, "span", engine, {
    "flex-grow": "1",
    "height": "20",
    "margin-left": "12"})
  r.setTextContent(label, task.text)

  ## Native delete button.
  let delBtn = mkElem[R, E](r, "button", engine, {
    "height": "32",
    "padding-left": "8",
    "padding-right": "8"})
  r.setTextContent(delBtn, "Delete")
  r.addEventListener(delBtn, "click", onDelete)

  mkAppend[R, E](r, row, toggle, engine)
  mkAppend[R, E](r, row, label, engine)
  mkAppend[R, E](r, row, delBtn, engine)
  row

proc createEmptyState*[R, E](r: R; message: string;
                              engine: LayoutEngine): E =
  ## Native paragraph for the empty state message.
  let wrapper = mkElem[R, E](r, "div", engine, {
    "flex-grow": "1",
    "align-items": "center",
    "justify-content": "center"})
  let text = mkElem[R, E](r, "p", engine, {
    "height": "52",
    "width": "300",
    "align-self": "center",
    "text-align": "center"})
  r.setTextContent(text, message)
  mkAppend[R, E](r, wrapper, text, engine)
  wrapper

proc createFilterBar*[R, E](r: R; current: FilterMode;
                             onFilter: proc(f: FilterMode);
                             engine: LayoutEngine): E =
  ## Native segmented control — maps to UISegmentedControl on iOS,
  ## ToggleGroup on Android.
  let bar = mkElem[R, E](r, "segmented", engine, {
    "flex-direction": "row",
    "justify-content": "center",
    "align-items": "center",
    "gap": "8",
    "height": "60",
    "padding": "12"})

  for filt in [fmAll, fmActive, fmCompleted]:
    let label = case filt
      of fmAll: "All"
      of fmActive: "Active"
      of fmCompleted: "Completed"
    let active = current == filt
    # Width based on label length (~10px per char at default font + 32px padding)
    let btnWidth = max(label.len * 10 + 32, 60)

    let segment = mkElem[R, E](r, "button", engine, {
      "height": "36",
      "width": $btnWidth})
    r.setTextContent(segment, label)
    r.setAttribute(segment, "selected", $active)

    let filtCapture = filt
    r.addEventListener(segment, "click", proc() = onFilter(filtCapture))
    mkAppend[R, E](r, bar, segment, engine)

  bar

proc createClearButton*[R, E](r: R; enabled: bool;
                               onClear: proc();
                               engine: LayoutEngine): E =
  ## Native button for clearing completed tasks.
  let clearBtn = mkElem[R, E](r, "button", engine, {
    "height": "36",
    "width": "180",
    "align-self": "center"})
  r.setTextContent(clearBtn, "Clear Completed")
  if enabled:
    r.addEventListener(clearBtn, "click", onClear)
  else:
    r.setAttribute(clearBtn, "enabled", "false")
  clearBtn
