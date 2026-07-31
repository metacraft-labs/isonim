## Phase G — Appearance section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * Opacity — numeric with ``%`` unit, 0-100 range.
##   * Corner radius — numeric with ``px`` unit.
##   * Blend mode — choice (normal / multiply / screen / overlay / …).
##   * Individual corner radii toggle — when on, four numeric inputs.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_position

const
  pctUnit = PropertyUnitOption(label: "%", code: "%")
  pxUnit = PropertyUnitOption(label: "px", code: "px")

proc mountSectionAppearance*[R, E](r: R; parent: E; vm: EditorVM) =
  let opacity = createSignal(100.0)
  let radius = createSignal(0.0)
  let blend = createSignal("normal")
  let perCorner = createSignal(false)
  let radiusTL = createSignal(0.0)
  let radiusTR = createSignal(0.0)
  let radiusBR = createSignal(0.0)
  let radiusBL = createSignal(0.0)
  let opacityUnit = createSignal(pctUnit)
  let radiusUnit = createSignal(pxUnit)

  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    let raw = findPropertyValue(props, "opacity", "1")
    let parsed = parseLeadingFloat(raw, 1.0)
    # ``opacity: 1`` is shown as 100 % on the unit-chip row; we keep the
    # ratio→percentage conversion local to the section so the inspector
    # signal speaks user units.
    opacity.val = parsed * 100.0
    radius.val = parseLeadingFloat(findPropertyValue(props, "border-radius", "0"), 0.0)
    blend.val = findPropertyValue(props, "mix-blend-mode", "normal")
    radiusTL.val = parseLeadingFloat(findPropertyValue(props,
      "border-top-left-radius", $radius.val), radius.val)
    radiusTR.val = parseLeadingFloat(findPropertyValue(props,
      "border-top-right-radius", $radius.val), radius.val)
    radiusBR.val = parseLeadingFloat(findPropertyValue(props,
      "border-bottom-right-radius", $radius.val), radius.val)
    radiusBL.val = parseLeadingFloat(findPropertyValue(props,
      "border-bottom-left-radius", $radius.val), radius.val)

  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Opacity", value = opacity, unit = opacityUnit,
    units = @[pctUnit],
    minValue = some(0.0), maxValue = some(100.0), step = 1.0,
    bindingReactive = vm.inspectorBindingThunk("opacity"),
    onBindRequest = vm.inspectorBindRequestHandler("opacity"),
    onDetachRequest = vm.inspectorDetachRequestHandler("opacity")))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Corner radius", value = radius, unit = radiusUnit,
    units = @[pxUnit], minValue = some(0.0),
    bindingReactive = vm.inspectorBindingThunk("border-radius"),
    onBindRequest = vm.inspectorBindRequestHandler("border-radius"),
    onDetachRequest = vm.inspectorDetachRequestHandler("border-radius")))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Blend mode", value = blend,
    options = @[
      (label: "Normal", value: "normal"),
      (label: "Multiply", value: "multiply"),
      (label: "Screen", value: "screen"),
      (label: "Overlay", value: "overlay"),
      (label: "Darken", value: "darken"),
      (label: "Lighten", value: "lighten")],
    bindingReactive = vm.inspectorBindingThunk("mix-blend-mode"),
    onBindRequest = vm.inspectorBindRequestHandler("mix-blend-mode"),
    onDetachRequest = vm.inspectorDetachRequestHandler("mix-blend-mode")))
  discard r.mountPropertyRow(parent, propertyRowBoolean(
    name = "Per-corner", value = perCorner))

  var perCornerHostEl: E
  let perCornerHost = ui(r):
    tdiv(ref = perCornerHostEl,
         `data-appearance-percorner-host` = "true",
         display = "none", flex_direction = "column")
  r.appendChild(parent, perCornerHost)
  discard r.mountPropertyRow(perCornerHostEl, propertyRowNumeric(
    name = "TL", value = radiusTL, unit = radiusUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("border-top-left-radius"),
    onBindRequest = vm.inspectorBindRequestHandler("border-top-left-radius"),
    onDetachRequest = vm.inspectorDetachRequestHandler("border-top-left-radius")))
  discard r.mountPropertyRow(perCornerHostEl, propertyRowNumeric(
    name = "TR", value = radiusTR, unit = radiusUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("border-top-right-radius"),
    onBindRequest = vm.inspectorBindRequestHandler("border-top-right-radius"),
    onDetachRequest = vm.inspectorDetachRequestHandler("border-top-right-radius")))
  discard r.mountPropertyRow(perCornerHostEl, propertyRowNumeric(
    name = "BR", value = radiusBR, unit = radiusUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("border-bottom-right-radius"),
    onBindRequest =
      vm.inspectorBindRequestHandler("border-bottom-right-radius"),
    onDetachRequest = vm.inspectorDetachRequestHandler("border-bottom-right-radius")))
  discard r.mountPropertyRow(perCornerHostEl, propertyRowNumeric(
    name = "BL", value = radiusBL, unit = radiusUnit, units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("border-bottom-left-radius"),
    onBindRequest =
      vm.inspectorBindRequestHandler("border-bottom-left-radius"),
    onDetachRequest = vm.inspectorDetachRequestHandler("border-bottom-left-radius")))
  createRenderEffect proc() =
    r.setStyle(perCornerHostEl, "display",
      if perCorner.val: "flex" else: "none")
