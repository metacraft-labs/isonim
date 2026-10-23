## The Fill section's advanced background-image controls: the gradient
## editor and the background position and repeat rows.
##
## Editor spec "Specialized Editors": "Gradient editor -- horizontal bar with
## color stops; drag to reposition; click to add; angle scrub-drag; type
## selector (linear/radial/conic)"; "Color Picker": "Gradient editor -- color
## stop bar with draggable stops; click bar to add stop; angle input with
## scrub-drag"; "Inspector Sections": Fill covers `background-image` and
## gradients; "Section catalogue": Fill's linear / radial / conic gradient
## fills. The clause that says how the editor commits is the drafted
## "Specialized editors" clause under "Specialized Editors".
##
## The editor follows the Background image row (`background-image`) behind
## the `Show advanced background-image controls` disclosure and edits that
## property through that row's wiring (`advanced_controls`). It reads the
## property as one gradient (`css_compound_values.parseCssGradient`); a
## property with no gradient starts from a two-stop gradient that is written
## on the first edit; a value the editor cannot change faithfully (an image,
## several layers, a hint) is named, and only the type buttons, which replace
## it, act. Every edit writes the whole gradient once:
##
## * the type buttons (`Set background-image to linear gradient`, radial,
##   conic) keep the stops;
## * the angle (`Scrub background-image gradient angle`) scrubs by drag, one
##   degree per pixel (Shift snaps to 15 degrees), committed on release;
##   pressing it without a drag turns the gradient by 45 degrees; the arrow
##   keys step one degree (Shift 15); the angle field takes typed degrees;
## * the stop bar: pressing the bar between stops adds a stop there, coloured
##   as the gradient is at that point; dragging a stop moves it, committed on
##   release; the arrow keys move the focused stop 1% (Shift 10%), Delete
##   removes it; a gradient keeps at least two stops. Stops positioned in a
##   length (`12px`) are not added or moved: where they sit depends on the
##   box (`stopPlacementRefusal`);
## * the selected stop's colour opens the colour picker, its position field
##   takes a percentage, and `Add` / `Remove` add a stop after it or remove
##   it.
##
## Escape, pointer cancellation or another selection end a drag without an
## edit. A refusal is shown under the editor and puts the editor back to the
## committed value.

import std/[math, options, strutils]

import isonim/core/[signals, computation, owner]
from isonim/core/batch import untrack
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/css_compound_values
import isonim/editor/views/view_lifecycle
import ./advanced_controls
import ./color_popover
import ./property_commit
import ./property_row
import ./section_raw_css

const
  gradientProperty* = "background-image"
  gradientEditorLabel* = "Edit gradient stops"
  gradientBarLabel* = "Gradient stop bar: press to add a stop"
  gradientSearchText* = "Gradient background-image linear radial conic " &
    "angle stops background-position background-repeat"
  nominalBarWidth* = 200.0
    ## The stop bar's width where there is no layout to measure (headless).
  angleStepDegrees* = 45.0
    ## How far pressing the angle control without a drag turns the gradient.
  radialAngleReason* = "A radial gradient has no angle."
  backgroundRepeatOptions* = @[
    (label: "Repeat", value: "repeat"), (label: "No repeat", value: "no-repeat"),
    (label: "Repeat X", value: "repeat-x"), (label: "Repeat Y", value: "repeat-y"),
    (label: "Space", value: "space"), (label: "Round", value: "round")]

func gradientTypeLabel*(kind: CssGradientKind): string =
  "Set " & gradientProperty & " to " & $kind & " gradient"

func gradientAngleScrubLabel*(): string =
  "Scrub " & gradientProperty & " gradient angle"

func gradientStopLabel*(index: int; percent: float): string =
  "Gradient stop " & $(index + 1) & " at " & stopPositionText(percent)

func steppedAngle*(degrees: float): float =
  ## The angle pressing the angle control turns ``degrees`` to.
  normalizedDegrees(degrees + angleStepDegrees)

func scrubbedAngle*(start, dx: float; snap: bool): float =
  ## The angle a horizontal drag of ``dx`` pixels from ``start`` gives: one
  ## degree per pixel, or with ``snap`` (Shift) the nearest 15 degrees.
  var value = start + round(dx)
  if snap: value = round(value / 15.0) * 15.0
  normalizedDegrees(value)

func barPercent*(x, left, width: float): float =
  ## Where a pointer at ``x`` falls along a bar at ``left`` of ``width``.
  let span = if width > 0.0: width else: nominalBarWidth
  clamp((x - left) / span * 100.0, 0.0, 100.0)

proc mountGradientContents*[R, E](r: R; panel: E; vm: EditorVM;
    wiring, positionWiring, repeatWiring: InspectorRowWiring) =
  let status = newCompoundEditorStatus()
  let draft = createSignal(none(CssGradient))
  let selectedStop = createSignal(0)
  var alive = true
  onCleanup(proc() = alive = false)

  proc parsed(): CssGradientParse =
    let value = vm.compoundValue(gradientProperty)
    parseCssGradient(if value.isSome: value.get else: "")
  proc isNone(): bool =
    let value = vm.compoundValue(gradientProperty)
    value.isNone or value.get.len == 0 or value.get.toLowerAscii() == "none"
  proc base(): CssGradient =
    let p = parsed()
    if p.ok: p.gradient else: startingGradient()
  proc shown(): CssGradient =
    let d = draft.val
    if d.isSome: d.get else: base()
  proc refusal(): string =
    vm.compoundRefusal(gradientProperty, wiring)
  proc editRefusal(): string =
    ## Why the angle and stops cannot act: the property's refusal, or a value
    ## the editor does not change (which only the type buttons replace).
    result = refusal()
    if result.len > 0: return
    let p = parsed()
    if not p.ok and not isNone():
      return "The gradient editor cannot change this " & gradientProperty &
        ": " & p.reason & "."
  proc placeRefusal(): string =
    ## Why stops cannot be added or moved: the edit refusal, or stops the
    ## bar cannot place (`stopPlacementRefusal`).
    result = editRefusal()
    if result.len > 0: return
    let placement = base().stopPlacementRefusal
    if placement.len > 0:
      result = "The gradient editor cannot move this " & gradientProperty &
        "'s stops: " & placement & "."
  proc angleRefusal(): string =
    result = editRefusal()
    if result.len == 0 and base().kind == cgkRadial:
      result = radialAngleReason

  proc commitGradient(next: CssGradient; label: string;
      after: proc(ok: bool) {.closure.} = nil): bool {.discardable.} =
    draft.val = none(CssGradient)
    commitThrough(vm, gradientProperty, wiring, status, label,
      serializeCssGradient(next), after)

  proc reject(reason: string) =
    status.failed.val = true
    status.message.val = reason

  let epoch = createSignal(0)
  watchSelection(vm, proc() =
    epoch.val = epoch.val + 1
    draft.val = none(CssGradient)
    selectedStop.val = 0
    status.message.val = "")

  var typeRow, angleRow, angleButton, preview, bar, barStops: E
  var stopRow, swatch, addButton, removeButton, note, rows: E
  let editor = ui(r):
    tdiv(`data-gradient-editor` = "true", role = "group",
         display = "flex", flex_direction = "column", gap = "6px",
         padding = "6px", border = "1px solid " & advBorder,
         border_radius = "6px", min_width = "0"):
      tdiv(ref = typeRow, `data-gradient-types` = "true",
           display = "grid", grid_template_columns = "repeat(3, minmax(0, 1fr))",
           gap = "2px", background_color = advTrough, border_radius = "4px",
           padding = "1px")
      tdiv(ref = angleRow, `data-gradient-angle` = "true",
           display = "flex", align_items = "center", gap = "4px", min_width = "0"):
        button(ref = angleButton, `type` = "button",
               `data-gradient-angle-scrub` = "true",
               display = "flex", align_items = "center", justify_content = "center",
               width = "52px", height = "22px", flex_shrink = "0",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = advTrough, color = advTextPrimary,
               font_family = "inherit", font_size = "11px",
               cursor = "ew-resize", touch_action = "none"):
          text ""
      tdiv(ref = preview, `data-gradient-preview` = "true", `aria-hidden` = "true",
           height = "28px", border_radius = "4px",
           border = "1px solid " & advBorder)
      tdiv(ref = bar, `data-gradient-bar` = "true", role = "group",
           position = "relative", height = "16px", margin = "4px 6px",
           border_radius = "3px", border = "1px solid " & advBorder,
           cursor = "copy", touch_action = "none"):
        tdiv(ref = barStops, `data-gradient-stops` = "true")
      tdiv(ref = stopRow, `data-gradient-stop-editor` = "true",
           display = "flex", align_items = "center", gap = "4px", min_width = "0"):
        button(ref = swatch, `type` = "button",
               `data-gradient-stop-swatch` = "true",
               `aria-label` = "Edit gradient stop color",
               width = "20px", height = "20px", flex_shrink = "0",
               border = "1px solid rgba(255, 255, 255, 0.34)",
               border_radius = "3px", cursor = "pointer", padding = "0")
      tdiv(ref = note, `data-gradient-note` = "true", role = "note",
           font_size = "10px", color = advTextMuted, overflow_wrap = "anywhere")
      tdiv(ref = rows, `data-gradient-rows` = "true",
           display = "flex", flex_direction = "column", min_width = "0")
  r.setAttribute(editor, "aria-label", gradientEditorLabel)
  r.setAttribute(bar, "aria-label", gradientBarLabel)
  r.setAttribute(angleButton, "aria-label", gradientAngleScrubLabel())
  r.appendChild(panel, editor)

  # ----- Type ------------------------------------------------------------- #
  proc mountType(kind: CssGradientKind) =
    var node: E
    let el = ui(r):
      button(ref = node, `type` = "button", `data-gradient-type` = $kind,
             `aria-pressed` = "false",
             height = "22px", border = "none", border_radius = "3px",
             background_color = "transparent", color = advTextMuted,
             font_family = "inherit", font_size = "11px", cursor = "pointer"):
        text ($kind).capitalizeAscii
    r.setAttribute(node, "aria-label", gradientTypeLabel(kind))
    r.appendChild(typeRow, el)
    createRenderEffect proc() =
      let pressed = parsed().ok and base().kind == kind
      let reason = refusal()
      r.setAttribute(node, "aria-pressed", if pressed: "true" else: "false")
      setButtonAvailability(r, node, reason,
        if parsed().ok or isNone(): "Make the background-image a " & $kind & " gradient"
        else: "Replace the background-image with a " & $kind & " gradient")
      r.setStyle(node, "background-color", if pressed: advPressed else: "transparent")
      if reason.len == 0:
        r.setStyle(node, "color", if pressed: advTextPrimary else: advTextMuted)
    r.addEventListener(node, "click", proc() =
      if not alive: return
      let reason = untrack(refusal)
      if reason.len > 0:
        reject(reason)
        return
      let current = untrack(base)
      commitGradient(current.gradientWithKind(kind), ($kind).capitalizeAscii))
    stopAdvActivationKeys(r, node)
  for kind in CssGradientKind: mountType(kind)

  # ----- Angle ------------------------------------------------------------ #
  createRenderEffect proc() =
    let g = shown()
    r.setTextContent(angleButton,
      if g.kind == cgkRadial: "\xE2\x80\x94" else: compoundNumber(g.angle, 1) & "\xC2\xB0")
    setButtonAvailability(r, angleButton, angleRefusal(),
      "Drag to turn the gradient (Shift snaps to 15\xC2\xB0); press to turn it by 45\xC2\xB0")
  var anglePressed = false
  var angleEpoch = 0
  var angleDragging = false
  var angleStartX = 0.0
  var angleStart = 0.0
  var suppressAngleClick = false
  proc angleCancel() =
    if anglePressed and angleDragging: draft.val = none(CssGradient)
    anglePressed = false
    angleDragging = false
  when isDomViewHost(E):
    r.addEventListener(angleButton, "pointerdown", proc(ev: auto) =
      if advButton(ev) == 0: captureAdvPointer(angleButton, ev))
  r.addPointerListener(angleButton, "pointerdown", proc(x, y: float; shift, alt: bool) =
    suppressAngleClick = false
    if untrack(angleRefusal).len > 0: return
    anglePressed = true
    angleDragging = false
    angleEpoch = untrack(proc(): int = epoch.val)
    angleStartX = x
    angleStart = untrack(base).angle)
  r.addPointerListener(angleButton, "pointermove", proc(x, y: float; shift, alt: bool) =
    if not anglePressed: return
    if untrack(proc(): int = epoch.val) != angleEpoch:
      anglePressed = false
      return
    if not angleDragging:
      if abs(x - angleStartX) < scrubThreshold: return
      angleDragging = true
    draft.val = some(untrack(base).gradientWithAngle(
      scrubbedAngle(angleStart, x - angleStartX, shift))))
  r.addPointerListener(angleButton, "pointerup", proc(x, y: float; shift, alt: bool) =
    if not anglePressed: return
    anglePressed = false
    if not angleDragging: return
    angleDragging = false
    suppressAngleClick = true
    if untrack(proc(): int = epoch.val) != angleEpoch: return
    let next = draft.val
    if next.isNone: return
    if next.get.angle == untrack(base).angle:
      draft.val = none(CssGradient)
      return
    commitGradient(next.get, "Angle"))
  r.addEventListener(angleButton, "pointercancel", proc() = angleCancel())
  r.addEventListener(angleButton, "lostpointercapture", proc() = angleCancel())
  r.addEventListener(angleButton, "click", proc() =
    # Pressing without a drag (or Enter / Space) turns the gradient.
    if suppressAngleClick:
      suppressAngleClick = false
      return
    if not alive: return
    let reason = untrack(angleRefusal)
    if reason.len > 0:
      reject(reason)
      return
    let current = untrack(base)
    commitGradient(current.gradientWithAngle(steppedAngle(current.angle)), "Angle"))
  r.addEventListener(angleButton, "keydown", proc(ev: auto) =
    let key = advKey(ev)
    if key in ["Enter", " "]:
      stopAdvPropagation(ev)
    elif key == "Escape" and anglePressed:
      stopAdvPropagation(ev)
      angleCancel()
      # The press still ends in a click; it belongs to the cancelled drag.
      suppressAngleClick = true
    elif key in ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]:
      preventAdvDefault(ev)
      stopAdvPropagation(ev)
      let reason = untrack(angleRefusal)
      if reason.len > 0:
        reject(reason)
        return
      let size = if advShift(ev): 15.0 else: 1.0
      let current = untrack(base)
      commitGradient(current.gradientWithAngle(current.angle +
        (if key in ["ArrowRight", "ArrowUp"]: size else: -size)), "Angle"))
  onCleanup(proc() = angleCancel())
  discard mountCompoundNumberField[R, E](r, angleRow, CompoundNumberField(
    label: "Angle", ariaLabel: "Edit " & gradientProperty & " gradient angle",
    unit: "deg", step: 1.0,
    shown: proc(): string =
      let g = shown()
      if g.kind == cgkRadial: "" else: compoundNumber(g.angle) & "deg",
    commit: proc(text: string): bool =
      var degrees = 0.0
      if not cssAngleDegrees(text, degrees):
        reject("Angle: type an angle in degrees (" & text & ").")
        return false
      commitGradient(untrack(base).gradientWithAngle(degrees), "Angle"),
    draft: proc(text: string) =
      var degrees = 0.0
      if text.len > 0 and cssAngleDegrees(text, degrees):
        draft.val = some(untrack(base).gradientWithAngle(degrees))
      else: draft.val = none(CssGradient),
    reason: angleRefusal,
    generation: proc(): int = epoch.val))

  # ----- Preview and bar -------------------------------------------------- #
  createRenderEffect proc() =
    let g = shown()
    r.setStyle(preview, "background-image", serializeCssGradient(g))
    r.setStyle(bar, "background-image", gradientBarImage(g))
    r.setStyle(bar, "cursor", if placeRefusal().len > 0: "not-allowed" else: "copy")

  var handleGesture = false
  r.addPointerListener(bar, "pointerdown", proc(x, y: float; shift, alt: bool) =
    # A press on a stop is the stop's; a press on the bar between stops adds
    # one there.
    if handleGesture:
      handleGesture = false
      return
    if not alive: return
    let reason = untrack(placeRefusal)
    if reason.len > 0:
      reject(reason)
      return
    let rect = nodeRect(bar)
    var index = 0
    let current = untrack(base)
    let next = current.gradientWithStopAdded(barPercent(x, rect.x, rect.w), index)
    if commitGradient(next, "Add stop"): selectedStop.val = index)

  proc mountStop(index: int) =
    var handle: E
    let el = ui(r):
      button(ref = handle, `type` = "button", `data-gradient-stop` = $index,
             position = "absolute", top = "50%", width = "12px", height = "20px",
             padding = "0", border = "2px solid #FFFFFF", border_radius = "4px",
             box_shadow = "0 0 0 1px rgba(0, 0, 0, 0.6)",
             transform = "translate(-50%, -50%)", cursor = "grab",
             touch_action = "none")
    r.appendChild(barStops, el)
    var pressed = false
    var dragging = false
    var pressEpoch = 0
    var startX = 0.0
    var startPercent = 0.0
    var width = nominalBarWidth
    createRenderEffect proc() =
      let g = shown()
      if index >= g.stops.len: return
      let percent = g.stopPercent(index)
      r.setStyle(handle, "left", stopPositionText(percent))
      r.setStyle(handle, "background-color", g.stops[index].color)
      r.setAttribute(handle, "aria-label", gradientStopLabel(index, percent))
      let selected = selectedStop.val == index
      r.setAttribute(handle, "aria-pressed", if selected: "true" else: "false")
      r.setStyle(handle, "outline", if selected: "2px solid " & advAccent else: "none")
    proc cancel() =
      if pressed and dragging: draft.val = none(CssGradient)
      pressed = false
      dragging = false
    when isDomViewHost(E):
      r.addEventListener(handle, "pointerdown", proc(ev: auto) =
        if advButton(ev) == 0: captureAdvPointer(handle, ev))
    r.addPointerListener(handle, "pointerdown", proc(x, y: float; shift, alt: bool) =
      handleGesture = true
      selectedStop.val = index
      let reason = untrack(placeRefusal)
      if reason.len > 0:
        reject(reason)
        return
      pressed = true
      dragging = false
      pressEpoch = untrack(proc(): int = epoch.val)
      startX = x
      startPercent = untrack(base).stopPercent(index)
      let rect = nodeRect(bar)
      width = if rect.w > 0: rect.w else: nominalBarWidth)
    r.addPointerListener(handle, "pointermove", proc(x, y: float; shift, alt: bool) =
      if not pressed: return
      if untrack(proc(): int = epoch.val) != pressEpoch:
        pressed = false
        return
      if not dragging:
        if abs(x - startX) < scrubThreshold: return
        dragging = true
      draft.val = some(untrack(base).gradientWithStopMoved(index,
        startPercent + (x - startX) / width * 100.0)))
    r.addPointerListener(handle, "pointerup", proc(x, y: float; shift, alt: bool) =
      handleGesture = false
      if not pressed: return
      pressed = false
      if not dragging: return
      dragging = false
      if untrack(proc(): int = epoch.val) != pressEpoch: return
      var moved = index
      let current = untrack(base)
      let next = current.gradientWithStopMoved(index,
        startPercent + (x - startX) / width * 100.0, moved)
      if serializeCssGradient(next) == serializeCssGradient(current):
        draft.val = none(CssGradient)
        return
      if commitGradient(next, "Move stop"): selectedStop.val = moved)
    r.addEventListener(handle, "pointercancel", proc() = cancel())
    r.addEventListener(handle, "lostpointercapture", proc() = cancel())
    r.addEventListener(handle, "focus", proc() = selectedStop.val = index)
    r.addEventListener(handle, "keydown", proc(ev: auto) =
      let key = advKey(ev)
      if key == "Escape" and pressed:
        stopAdvPropagation(ev)
        cancel()
        return
      if key notin ["ArrowLeft", "ArrowRight", "Delete", "Backspace"]: return
      preventAdvDefault(ev)
      stopAdvPropagation(ev)
      let reason = untrack(if key in ["Delete", "Backspace"]: editRefusal
        else: placeRefusal)
      if reason.len > 0:
        reject(reason)
        return
      let current = untrack(base)
      if key in ["Delete", "Backspace"]:
        if current.stops.len <= 2:
          reject("Remove stop: a gradient keeps at least two stops.")
          return
        if commitGradient(current.gradientWithStopRemoved(index), "Remove stop"):
          selectedStop.val = max(0, index - 1)
        return
      let size = if advShift(ev): 10.0 else: 1.0
      var moved = index
      let next = current.gradientWithStopMoved(index, current.stopPercent(index) +
        (if key == "ArrowRight": size else: -size), moved)
      if commitGradient(next, "Move stop"): selectedStop.val = moved)
    onCleanup(proc() = cancel())

  # Handles are rebuilt when the number of stops or the selection changes;
  # positions and colours follow the shown gradient in place, so a drag keeps
  # its handle.
  let stopsKey = createMemo(proc(): tuple[count: int; key: string] =
    (count: base().stops.len, key: vm.compoundSelectionKey()))
  createRenderEffect proc() =
    let count = stopsKey.val.count
    untrack(proc() =
      r.clearChildren(barStops)
      if selectedStop.val >= count: selectedStop.val = max(0, count - 1)
      for i in 0 ..< count: mountStop(i))

  # ----- The selected stop ------------------------------------------------ #
  proc stopColor(): string =
    let g = shown()
    let i = selectedStop.val
    if i < g.stops.len: g.stops[i].color else: ""
  createRenderEffect proc() =
    r.setStyle(swatch, "background-color", stopColor())
    setButtonAvailability(r, swatch, editRefusal(), "Edit the selected stop's colour")
  discard mountCompoundNumberField[R, E](r, stopRow, CompoundNumberField(
    label: "Stop", ariaLabel: "Gradient stop position",
    unit: "%", step: 1.0, minimum: some(0.0), maximum: some(100.0),
    shown: proc(): string =
      let g = shown()
      let i = selectedStop.val
      if i < g.stops.len: stopPositionText(g.stopPercent(i)) else: "",
    commit: proc(text: string): bool =
      var number = 0.0
      var unit = ""
      if not splitDimension(text, number, unit) or unit != "%":
        reject("Stop position: type a percentage (" & text & ").")
        return false
      let i = untrack(proc(): int = selectedStop.val)
      var moved = i
      let next = untrack(base).gradientWithStopMoved(i, number, moved)
      result = commitGradient(next, "Stop position")
      if result: selectedStop.val = moved,
    reason: placeRefusal,
    generation: proc(): int = epoch.val))
  let colorState = createColorPopoverState()
  discard mountColorPopover(r, stopRow, swatch, colorState,
    proc(): string = stopColor(),
    proc(value: string): bool =
      let reason = untrack(editRefusal)
      if reason.len > 0:
        colorState.diagnostic.val = reason
        return false
      let closeOnSuccess = colorState.commitCloses
      let i = untrack(proc(): int = selectedStop.val)
      colorState.pending.val = true
      var completed = false
      var accepted = false
      commitGradient(untrack(base).gradientWithStopColor(i, value), "Stop colour",
        proc(ok: bool) =
          completed = true
          accepted = ok
          if not alive: return
          colorState.pending.val = false
          if ok:
            if closeOnSuccess: colorState.open.val = false
            else: colorState.markColorDraftCommitted()
          else: colorState.diagnostic.val = status.message.val)
      completed and accepted)
  let addRemove = ui(r):
    tdiv(display = "flex", gap = "2px", flex_shrink = "0"):
      button(ref = addButton, `type` = "button",
             `data-gradient-add-stop` = "true",
             height = "22px", padding = "0 6px",
             border = "1px solid " & advBorder, border_radius = "4px",
             background_color = "transparent", color = advTextPrimary,
             font_family = "inherit", font_size = "11px", cursor = "pointer"):
        text "+"
      button(ref = removeButton, `type` = "button",
             `data-gradient-remove-stop` = "true",
             height = "22px", padding = "0 6px",
             border = "1px solid " & advBorder, border_radius = "4px",
             background_color = "transparent", color = advTextPrimary,
             font_family = "inherit", font_size = "11px", cursor = "pointer"):
        text "\xE2\x88\x92"
  r.setAttribute(addButton, "aria-label", "Add " & gradientProperty & " gradient stop")
  r.setAttribute(removeButton, "aria-label", "Remove " & gradientProperty & " gradient stop")
  r.appendChild(stopRow, addRemove)
  proc removeRefusal(): string =
    result = editRefusal()
    if result.len == 0 and base().stops.len <= 2:
      result = "A gradient keeps at least two stops."
  createRenderEffect proc() =
    setButtonAvailability(r, addButton, placeRefusal(),
      "Add a stop after the selected one")
    setButtonAvailability(r, removeButton, removeRefusal(),
      "Remove the selected stop")
  r.addEventListener(addButton, "click", proc() =
    if not alive: return
    let reason = untrack(placeRefusal)
    if reason.len > 0:
      reject(reason)
      return
    let current = untrack(base)
    let i = min(untrack(proc(): int = selectedStop.val), current.stops.len - 1)
    let here = current.stopPercent(i)
    let there = if i + 1 < current.stops.len: current.stopPercent(i + 1) else: 100.0
    var index = 0
    let next = current.gradientWithStopAdded(
      if there > here: (here + there) / 2.0 else: here, index)
    if commitGradient(next, "Add stop"): selectedStop.val = index)
  r.addEventListener(removeButton, "click", proc() =
    if not alive: return
    let reason = untrack(removeRefusal)
    if reason.len > 0:
      reject("Remove stop: " & reason)
      return
    let i = untrack(proc(): int = selectedStop.val)
    if commitGradient(untrack(base).gradientWithStopRemoved(i), "Remove stop"):
      selectedStop.val = max(0, i - 1))
  stopAdvActivationKeys(r, addButton)
  stopAdvActivationKeys(r, removeButton)

  # ----- What the editor is showing ----------------------------------------#
  createRenderEffect proc() =
    let p = parsed()
    r.setTextContent(note,
      if p.ok: ""
      elif isNone(): "No gradient is set: this is a starting gradient, " &
        "written on your first edit."
      else: "The gradient editor cannot change this " & gradientProperty &
        ": " & p.reason & ". A type button replaces it.")
    r.setStyle(note, "display", if p.ok: "none" else: "block")
  mountScopeNote(r, editor, gradientProperty, wiring, gradientProperty)
  mountEditorStatus(r, editor, status, "data-gradient-message")

  # ----- Position and repeat rows ----------------------------------------- #
  proc rowValue(property: string): Signal[string] =
    result = createSignal("")
    let captured = result
    createRenderEffect proc() =
      let value = vm.compoundValue(property)
      captured.val = if value.isSome: value.get else: ""
  proc rowHost(property: string): E =
    result = r.createElement("div")
    r.setAttribute(result, "data-gradient-row-property", property)
    r.setStyle(result, "flex-direction", "column")
    r.appendChild(rows, result)
    let captured = result
    createRenderEffect proc() =
      r.setStyle(captured, "display",
        if vm.inspectorProperty(property).isSome: "flex" else: "none")
  discard r.mountPropertyRow(rowHost("background-position"), propertyRowText(
    name = "background-position", value = rowValue("background-position"),
    bindingReactive = vm.inspectorBindingThunk("background-position"),
    onBindRequest = vm.inspectorBindRequestHandler("background-position"),
    onDetachRequest = vm.inspectorDetachRequestHandler("background-position"),
    wiring = positionWiring))
  discard r.mountPropertyRow(rowHost("background-repeat"), propertyRowChoice(
    name = "background-repeat", value = rowValue("background-repeat"),
    options = backgroundRepeatOptions,
    bindingReactive = vm.inspectorBindingThunk("background-repeat"),
    onBindRequest = vm.inspectorBindRequestHandler("background-repeat"),
    onDetachRequest = vm.inspectorDetachRequestHandler("background-repeat"),
    wiring = repeatWiring))

proc mountGradientEditor*[R, E](r: R; parent: E; vm: EditorVM;
    wiring: InspectorRowWiring) =
  ## The disclosure, at the end of ``parent``; its contents are mounted when
  ## it is first opened. ``wiring`` is the Background image row's.
  let positionWiring = vm.inspectorRowWiring("background-position")
  let repeatWiring = vm.inspectorRowWiring("background-repeat")
  # Part of Fill's raw CSS from the start, though the rows mount on opening.
  registerSectionCssRow(positionWiring)
  registerSectionCssRow(repeatWiring)
  discard mountAdvancedDisclosure[R, E](r, parent, vm, gradientProperty,
    "Gradient, position, repeat", gradientSearchText, proc(panel: E) =
      mountGradientContents[R, E](r, panel, vm, wiring, positionWiring,
        repeatWiring))
