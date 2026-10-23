## The Effects section's shadow editor, for `box-shadow`.
##
## Editor spec "Specialized Editors": "Shadow editor -- X/Y offset via 2D
## crosshair drag or numeric inputs; blur/spread as scrub inputs; color
## picker for shadow color; inset toggle; multiple shadows with add/remove";
## "Inspector Sections": Effects covers `box-shadow`; "Section catalogue":
## Effects' drop shadow and inner shadow; "Effects section consolidates
## Transitions + Filters". The clause that says how it commits is the drafted
## "Specialized editors" clause under "Specialized Editors".
##
## The editor follows the Shadow row (`box-shadow`) behind the `Show
## advanced box-shadow controls` disclosure and edits that property through
## that row's wiring (`advanced_controls`). It reads the property as a list
## of shadows (`css_compound_values.parseCssShadowList`; `none` is no
## shadow) and writes the whole list on every edit:
##
## * the layer list selects a layer; `Add shadow layer` adds one, each
##   layer's remove button removes it;
## * the crosshair (`Edit shadow with crosshair`) moves the selected layer's
##   X/Y offset with a drag, a pixel per pixel, committed on release; the
##   arrow keys move it one pixel (Shift 10);
## * X, Y, Blur and Spread are number fields whose labels scrub;
## * the colour swatch opens the colour picker; `Toggle inset shadow`
##   switches the layer between a drop shadow and an inner shadow;
## * the presets commit a whole list; `Bind elevation token` opens the
##   variable picker for `box-shadow`, as the row's bind affordance does.
##
## A value the editor cannot change faithfully (a variable, a malformed
## list) is named; only the presets and `Add shadow layer`, which replace
## it, act. Escape, pointer cancellation or another selection end a drag
## without an edit.

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

const
  shadowProperty* = "box-shadow"
  shadowCrosshairLabel* = "Edit shadow with crosshair"
  shadowSearchText* = "Shadow box-shadow drop shadow inner shadow inset " &
    "offset blur spread elevation"
  crosshairSize* = 80.0
    ## The crosshair's side in pixels; its centre is a zero offset.
  noShadowReason* = "No shadow is set. Add a layer or apply a preset."

func shadowPresetLabel*(name: string): string =
  "Apply " & name & " shadow preset"

func shadowLayerLabel*(index: int): string =
  "Select shadow layer " & $(index + 1)

func removeShadowLayerLabel*(index: int): string =
  "Remove shadow layer " & $(index + 1)

func shadowLayerSummary*(layer: CssShadowLayer): string =
  (if layer.inset: "Inner " else: "Drop ") & serializeCssShadowLayer(layer)

func crosshairDot*(x, y: float): tuple[left, top: float] =
  ## Where the crosshair draws an offset of (``x``, ``y``) pixels: the centre
  ## plus the offset, kept inside the square.
  let half = crosshairSize / 2.0
  (left: clamp(half + x, 4.0, crosshairSize - 4.0),
   top: clamp(half + y, 4.0, crosshairSize - 4.0))

proc mountShadowContents*[R, E](r: R; panel: E; vm: EditorVM;
    wiring: InspectorRowWiring) =
  let status = newCompoundEditorStatus()
  let draft = createSignal(none(seq[CssShadowLayer]))
  let selected = createSignal(0)
  var alive = true
  onCleanup(proc() = alive = false)

  proc parsed(): CssShadowParse =
    let value = vm.compoundValue(shadowProperty)
    parseCssShadowList(if value.isSome: value.get else: "")
  proc base(): seq[CssShadowLayer] =
    let p = parsed()
    if p.ok: p.layers else: @[]
  proc shown(): seq[CssShadowLayer] =
    let d = draft.val
    if d.isSome: d.get else: base()
  proc refusal(): string = vm.compoundRefusal(shadowProperty, wiring)
  proc listRefusal(): string =
    ## Why the layers cannot be edited: the property's refusal, or a value
    ## the editor does not change (which a preset or a new layer replaces).
    result = refusal()
    if result.len > 0: return
    let p = parsed()
    if not p.ok:
      return "The shadow editor cannot change this " & shadowProperty & ": " &
        p.reason & "."
  proc layerRefusal(): string =
    result = listRefusal()
    if result.len == 0 and base().len == 0: result = noShadowReason
  proc layerIndex(): int =
    min(selected.val, max(0, base().len - 1))

  proc commitLayers(next: seq[CssShadowLayer]; label: string;
      after: proc(ok: bool) {.closure.} = nil): bool {.discardable.} =
    draft.val = none(seq[CssShadowLayer])
    commitThrough(vm, shadowProperty, wiring, status, label,
      serializeCssShadowList(next), after)
  proc reject(reason: string) =
    status.failed.val = true
    status.message.val = reason
  proc withLayer(layer: CssShadowLayer): seq[CssShadowLayer] =
    result = untrack(base)
    let i = untrack(layerIndex)
    if i < result.len: result[i] = layer

  let epoch = createSignal(0)
  watchSelection(vm, proc() =
    epoch.val = epoch.val + 1
    draft.val = none(seq[CssShadowLayer])
    selected.val = 0
    status.message.val = "")

  var layerList, addButton, bindButton, pad, dot, fields, colorRow: E
  var swatch, insetButton, presets, note: E
  let editor = ui(r):
    tdiv(`data-shadow-editor` = "true", role = "group",
         `aria-label` = "Shadow editor",
         display = "flex", flex_direction = "column", gap = "6px",
         padding = "6px", border = "1px solid " & advBorder,
         border_radius = "6px", min_width = "0"):
      tdiv(ref = layerList, `data-shadow-layers` = "true",
           display = "flex", flex_direction = "column", gap = "2px", min_width = "0")
      tdiv(display = "flex", gap = "4px"):
        button(ref = addButton, `type` = "button", `data-shadow-add` = "true",
               `aria-label` = "Add shadow layer",
               height = "22px", padding = "0 8px",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = "transparent", color = advTextPrimary,
               font_family = "inherit", font_size = "11px", cursor = "pointer"):
          text "+ Layer"
        button(ref = bindButton, `type` = "button", `data-shadow-bind` = "true",
               `aria-label` = "Bind elevation token",
               height = "22px", padding = "0 8px",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = "transparent", color = advTextPrimary,
               font_family = "inherit", font_size = "11px", cursor = "pointer"):
          text "\xE2\x97\x87 Token"
      tdiv(display = "flex", gap = "8px", align_items = "flex-start", min_width = "0"):
        tdiv(ref = pad, `data-shadow-crosshair` = "true", role = "group",
             tabindex = "0",
             position = "relative", width = "80px", height = "80px",
             flex_shrink = "0", border = "1px solid " & advBorder,
             border_radius = "4px", background_color = advTrough,
             cursor = "crosshair", touch_action = "none", outline = "none"):
          tdiv(`aria-hidden` = "true", position = "absolute", left = "50%",
               top = "0", width = "1px", height = "100%",
               background_color = advBorder)
          tdiv(`aria-hidden` = "true", position = "absolute", top = "50%",
               left = "0", height = "1px", width = "100%",
               background_color = advBorder)
          tdiv(ref = dot, `data-shadow-crosshair-dot` = "true",
               `aria-hidden` = "true", position = "absolute",
               width = "8px", height = "8px", border_radius = "50%",
               background_color = advAccent, border = "1px solid #FFFFFF",
               transform = "translate(-50%, -50%)", pointer_events = "none")
        tdiv(ref = fields, display = "flex", flex_direction = "column",
             gap = "3px", flex = "1", min_width = "0")
      tdiv(ref = colorRow, display = "flex", align_items = "center", gap = "6px"):
        button(ref = swatch, `type` = "button", `data-shadow-color` = "true",
               `aria-label` = "Edit shadow layer color",
               width = "20px", height = "20px", padding = "0", flex_shrink = "0",
               border = "1px solid rgba(255, 255, 255, 0.34)",
               border_radius = "3px", cursor = "pointer")
        button(ref = insetButton, `type` = "button", `data-shadow-inset` = "true",
               `aria-label` = "Toggle inset shadow", `aria-pressed` = "false",
               height = "22px", padding = "0 8px",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = "transparent", color = advTextPrimary,
               font_family = "inherit", font_size = "11px", cursor = "pointer"):
          text "Inset"
      tdiv(ref = presets, `data-shadow-presets` = "true",
           display = "grid", grid_template_columns = "repeat(3, minmax(0, 1fr))",
           gap = "2px")
      tdiv(ref = note, `data-shadow-note` = "true", role = "note",
           font_size = "10px", color = advTextMuted, overflow_wrap = "anywhere")
  r.setAttribute(pad, "aria-label", shadowCrosshairLabel)
  r.appendChild(panel, editor)

  # ----- Layers ------------------------------------------------------------ #
  proc mountLayer(index: int) =
    var choose, remove: E
    let el = ui(r):
      tdiv(`data-shadow-layer` = $index, display = "flex", gap = "2px",
           min_width = "0"):
        button(ref = choose, `type` = "button", `aria-pressed` = "false",
               flex = "1", min_width = "0", height = "22px", padding = "0 6px",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = "transparent", color = advTextPrimary,
               font_family = "inherit", font_size = "10px", text_align = "left",
               white_space = "nowrap", overflow = "hidden",
               text_overflow = "ellipsis", cursor = "pointer"):
          text ""
        button(ref = remove, `type` = "button",
               width = "22px", height = "22px", padding = "0",
               border = "1px solid " & advBorder, border_radius = "4px",
               background_color = "transparent", color = advTextPrimary,
               font_family = "inherit", font_size = "11px", cursor = "pointer"):
          text "\xC3\x97"
    r.setAttribute(choose, "aria-label", shadowLayerLabel(index))
    r.setAttribute(remove, "aria-label", removeShadowLayerLabel(index))
    r.appendChild(layerList, el)
    createRenderEffect proc() =
      let layers = shown()
      if index >= layers.len: return
      r.setTextContent(choose, shadowLayerSummary(layers[index]))
      let isSelected = layerIndex() == index
      r.setAttribute(choose, "aria-pressed", if isSelected: "true" else: "false")
      r.setStyle(choose, "background-color",
        if isSelected: advPressed else: "transparent")
      setButtonAvailability(r, remove, listRefusal(), "Remove this layer")
    r.addEventListener(choose, "click", proc() = selected.val = index)
    r.addEventListener(remove, "click", proc() =
      if not alive: return
      let reason = untrack(listRefusal)
      if reason.len > 0:
        reject(reason)
        return
      var next = untrack(base)
      if index >= next.len: return
      next.delete(index)
      if commitLayers(next, "Remove layer"): selected.val = max(0, index - 1))
    stopAdvActivationKeys(r, choose)
    stopAdvActivationKeys(r, remove)
  let layersKey = createMemo(proc(): tuple[count: int; key: string] =
    (count: base().len, key: vm.compoundSelectionKey()))
  createRenderEffect proc() =
    let count = layersKey.val.count
    untrack(proc() =
      r.clearChildren(layerList)
      for i in 0 ..< count: mountLayer(i))

  createRenderEffect proc() =
    setButtonAvailability(r, addButton, refusal(), "Add a shadow layer")
    setButtonAvailability(r, bindButton, refusal(),
      "Bind box-shadow to an elevation variable")
  r.addEventListener(addButton, "click", proc() =
    if not alive: return
    let reason = untrack(refusal)
    if reason.len > 0:
      reject(reason)
      return
    # A list the editor cannot change is replaced by the new layer.
    var next = untrack(base)
    next.add newShadowLayer
    if commitLayers(next, "Add layer"): selected.val = next.len - 1)
  r.addEventListener(bindButton, "click", proc() =
    if not alive: return
    let reason = untrack(refusal)
    if reason.len > 0:
      reject(reason)
      return
    let rc = measureAnchorRect(bindButton)
    vm.inspectorBindRequestHandler(shadowProperty)(rc.x, rc.y, rc.w, rc.h))
  stopAdvActivationKeys(r, addButton)
  stopAdvActivationKeys(r, bindButton)

  # ----- Crosshair --------------------------------------------------------- #
  proc layerNow(): CssShadowLayer =
    let layers = shown()
    let i = layerIndex()
    if i < layers.len: layers[i] else: CssShadowLayer()
  createRenderEffect proc() =
    let layer = layerNow()
    let x = shadowLengthPixels(layer.x)
    let y = shadowLengthPixels(layer.y)
    let place = crosshairDot(if x.isNaN: 0.0 else: x, if y.isNaN: 0.0 else: y)
    r.setStyle(dot, "left", compoundNumber(place.left, 1) & "px")
    r.setStyle(dot, "top", compoundNumber(place.top, 1) & "px")
    let reason = layerRefusal()
    r.setStyle(dot, "display", if reason.len > 0: "none" else: "block")
    r.setAttribute(pad, "aria-disabled", if reason.len > 0: "true" else: "false")
    r.setAttribute(pad, "title",
      if reason.len > 0: reason
      else: "Drag to move the shadow's X/Y offset; arrow keys move it by 1px (Shift 10px)")
    r.setAttribute(pad, "aria-valuetext", "X " & layer.x & ", Y " & layer.y)
  proc padRefusal(): string =
    result = layerRefusal()
    if result.len > 0: return
    let layer = layerNow()
    if shadowLengthPixels(layer.x).isNaN or shadowLengthPixels(layer.y).isNaN:
      result = "Type pixel offsets in X and Y to move the shadow with the crosshair."
  var padPressed = false
  var padEpoch = 0
  var padDragging = false
  var padStartX, padStartY, padOffsetX, padOffsetY = 0.0
  proc padCancel() =
    if padPressed and padDragging: draft.val = none(seq[CssShadowLayer])
    padPressed = false
    padDragging = false
  when isDomViewHost(E):
    r.addEventListener(pad, "pointerdown", proc(ev: auto) =
      if advButton(ev) == 0:
        captureAdvPointer(pad, ev)
        r.focus(pad))
  r.addPointerListener(pad, "pointerdown", proc(x, y: float; shift, alt: bool) =
    let reason = untrack(padRefusal)
    if reason.len > 0:
      reject(reason)
      return
    padPressed = true
    padDragging = false
    padEpoch = untrack(proc(): int = epoch.val)
    padStartX = x
    padStartY = y
    let layer = untrack(layerNow)
    padOffsetX = shadowLengthPixels(layer.x)
    padOffsetY = shadowLengthPixels(layer.y))
  r.addPointerListener(pad, "pointermove", proc(x, y: float; shift, alt: bool) =
    if not padPressed: return
    if untrack(proc(): int = epoch.val) != padEpoch:
      padPressed = false
      return
    if not padDragging:
      if abs(x - padStartX) + abs(y - padStartY) < scrubThreshold: return
      padDragging = true
    let layer = untrack(layerNow)
    draft.val = some(withLayer(layer.shadowLayerWithOffset(
      padOffsetX + (x - padStartX), padOffsetY + (y - padStartY)))))
  r.addPointerListener(pad, "pointerup", proc(x, y: float; shift, alt: bool) =
    if not padPressed: return
    padPressed = false
    if not padDragging: return
    padDragging = false
    if untrack(proc(): int = epoch.val) != padEpoch: return
    let layers = untrack(base)
    let i = untrack(layerIndex)
    if i >= layers.len:
      # The list lost its layers during the drag (an undo, say): there is
      # nothing left to move.
      draft.val = none(seq[CssShadowLayer])
      return
    let next = withLayer(layers[i].shadowLayerWithOffset(
      padOffsetX + (x - padStartX), padOffsetY + (y - padStartY)))
    if serializeCssShadowList(next) == serializeCssShadowList(layers):
      draft.val = none(seq[CssShadowLayer])
      return
    commitLayers(next, "Offset"))
  r.addEventListener(pad, "pointercancel", proc() = padCancel())
  r.addEventListener(pad, "lostpointercapture", proc() = padCancel())
  r.addEventListener(pad, "keydown", proc(ev: auto) =
    let key = advKey(ev)
    if key == "Escape" and padPressed:
      stopAdvPropagation(ev)
      padCancel()
      return
    if key notin ["ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown"]: return
    preventAdvDefault(ev)
    stopAdvPropagation(ev)
    let reason = untrack(padRefusal)
    if reason.len > 0:
      reject(reason)
      return
    let size = if advShift(ev): 10.0 else: 1.0
    let layer = untrack(base)[untrack(layerIndex)]
    var x = shadowLengthPixels(layer.x)
    var y = shadowLengthPixels(layer.y)
    case key
    of "ArrowLeft": x -= size
    of "ArrowRight": x += size
    of "ArrowUp": y -= size
    else: y += size
    commitLayers(withLayer(layer.shadowLayerWithOffset(x, y)), "Offset"))
  onCleanup(proc() = padCancel())

  # ----- Fields ------------------------------------------------------------ #
  proc mountLength(label, ariaLabel: string; minimum: Option[float];
      get: proc(layer: CssShadowLayer): string {.closure.};
      put: proc(layer: var CssShadowLayer; value: string) {.closure.}) =
    discard mountCompoundNumberField[R, E](r, fields, CompoundNumberField(
      label: label, ariaLabel: ariaLabel, unit: "px", step: 1.0,
      minimum: minimum,
      shown: proc(): string =
        if layerRefusal().len > 0 and base().len == 0: ""
        else: get(layerNow()),
      commit: proc(text: string): bool =
        var layer = untrack(base)[untrack(layerIndex)]
        put(layer, text)
        # The field takes a length; what is not one is refused here rather
        # than written into the list as a colour.
        let checked = parseCssShadowList(serializeCssShadowLayer(layer))
        if not checked.ok or checked.layers.len != 1 or
            checked.layers[0].color != layer.color:
          reject(label & ": type a length (" & text & ").")
          return false
        commitLayers(withLayer(layer), label),
      draft: proc(text: string) =
        let layers = untrack(base)
        let i = untrack(layerIndex)
        if text.len == 0 or i >= layers.len:
          draft.val = none(seq[CssShadowLayer])
          return
        var layer = layers[i]
        put(layer, text)
        draft.val = some(withLayer(layer)),
      reason: layerRefusal,
      generation: proc(): int = epoch.val))
  mountLength("X", "Shadow X offset", none(float),
    proc(l: CssShadowLayer): string = l.x,
    proc(l: var CssShadowLayer; v: string) = l.x = v)
  mountLength("Y", "Shadow Y offset", none(float),
    proc(l: CssShadowLayer): string = l.y,
    proc(l: var CssShadowLayer; v: string) = l.y = v)
  # A negative blur is invalid CSS
  # (https://www.w3.org/TR/css-backgrounds-3/#shadow-blur-radius).
  mountLength("Blur", "Shadow blur", some(0.0),
    proc(l: CssShadowLayer): string = (if l.blur.len > 0: l.blur else: "0"),
    proc(l: var CssShadowLayer; v: string) = l.blur = v)
  mountLength("Spread", "Shadow spread", none(float),
    proc(l: CssShadowLayer): string = (if l.spread.len > 0: l.spread else: "0"),
    proc(l: var CssShadowLayer; v: string) = l.spread = v)

  # ----- Colour and inset -------------------------------------------------- #
  createRenderEffect proc() =
    let layer = layerNow()
    let reason = layerRefusal()
    r.setStyle(swatch, "background-color",
      if layer.color.len > 0: layer.color else: "currentcolor")
    setButtonAvailability(r, swatch, reason, "Edit the layer's colour")
    setButtonAvailability(r, insetButton, reason,
      "Switch between a drop shadow and an inner shadow")
    r.setAttribute(insetButton, "aria-pressed", if layer.inset: "true" else: "false")
    r.setStyle(insetButton, "background-color",
      if layer.inset: advPressed else: "transparent")
  r.addEventListener(insetButton, "click", proc() =
    if not alive: return
    let reason = untrack(layerRefusal)
    if reason.len > 0:
      reject(reason)
      return
    var layer = untrack(base)[untrack(layerIndex)]
    layer.inset = not layer.inset
    commitLayers(withLayer(layer), "Inset"))
  stopAdvActivationKeys(r, insetButton)
  let colorState = createColorPopoverState()
  discard mountColorPopover(r, colorRow, swatch, colorState,
    proc(): string = layerNow().color,
    proc(value: string): bool =
      let reason = untrack(layerRefusal)
      if reason.len > 0:
        colorState.diagnostic.val = reason
        return false
      let closeOnSuccess = colorState.commitCloses
      var layer = untrack(base)[untrack(layerIndex)]
      layer.color = value.strip()
      colorState.pending.val = true
      var completed = false
      var accepted = false
      commitLayers(withLayer(layer), "Colour", proc(ok: bool) =
        completed = true
        accepted = ok
        if not alive: return
        colorState.pending.val = false
        if ok:
          if closeOnSuccess: colorState.open.val = false
          else: colorState.markColorDraftCommitted()
        else: colorState.diagnostic.val = status.message.val)
      completed and accepted)

  # ----- Presets ----------------------------------------------------------- #
  proc mountPreset(name, value: string) =
    var node: E
    let el = ui(r):
      button(ref = node, `type` = "button", `data-shadow-preset` = name,
             height = "24px", border = "1px solid " & advBorder,
             border_radius = "4px", background_color = "transparent",
             color = advTextPrimary, font_family = "inherit",
             font_size = "10px", cursor = "pointer"):
        text name.capitalizeAscii
    r.setAttribute(node, "aria-label", shadowPresetLabel(name))
    r.appendChild(presets, el)
    createRenderEffect proc() =
      setButtonAvailability(r, node, refusal(), value)
    r.addEventListener(node, "click", proc() =
      if not alive: return
      let reason = untrack(refusal)
      if reason.len > 0:
        reject(reason)
        return
      if commitThrough(vm, shadowProperty, wiring, status,
          name.capitalizeAscii & " preset", value):
        selected.val = 0)
    stopAdvActivationKeys(r, node)
  for (name, value) in shadowPresets: mountPreset(name, value)

  createRenderEffect proc() =
    let p = parsed()
    r.setTextContent(note,
      if not p.ok: "The shadow editor cannot change this " & shadowProperty &
        ": " & p.reason & ". A preset or a new layer replaces it."
      elif p.layers.len == 0: noShadowReason
      else: "")
    r.setStyle(note, "display",
      if not p.ok or p.layers.len == 0: "block" else: "none")
  mountScopeNote(r, editor, shadowProperty, wiring, shadowProperty)
  mountEditorStatus(r, editor, status, "data-shadow-message")

proc mountShadowEditor*[R, E](r: R; parent: E; vm: EditorVM;
    wiring: InspectorRowWiring) =
  ## The disclosure, at the end of ``parent``; its contents are mounted when
  ## it is first opened. ``wiring`` is the Shadow row's.
  discard mountAdvancedDisclosure[R, E](r, parent, vm, shadowProperty,
    "Shadow layers", shadowSearchText, proc(panel: E) =
      mountShadowContents[R, E](r, panel, vm, wiring))
