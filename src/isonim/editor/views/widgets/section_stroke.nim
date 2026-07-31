## Phase G — Stroke section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * Stroke color (prkColor).
##   * Stroke width (prkNumeric, px).
##   * Stroke style (prkChoice: solid / dashed / dotted).
##   * Stroke position (prkChoice: inside / center / outside).
##   * Dash pattern (prkText, visible only when style != solid).

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_position

const
  pxUnit = PropertyUnitOption(label: "px", code: "px")

proc mountSectionStroke*[R, E](r: R; parent: E; vm: EditorVM) =
  let strokeColor = createSignal("#000000")
  let strokeAlpha = createSignal(1.0)
  let strokeWidth = createSignal(0.0)
  let strokeWidthUnit = createSignal(pxUnit)
  let strokeStyle = createSignal("solid")
  let strokePosition = createSignal("center")
  let dashPattern = createSignal("")

  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    strokeColor.val = findPropertyValue(props, "border-color", "#000000")
    strokeWidth.val = parseLeadingFloat(findPropertyValue(props,
      "border-width", "0"), 0.0)
    strokeStyle.val = findPropertyValue(props, "border-style", "solid")
    # CSS has no native "stroke position" — surface a UI-only signal
    # seeded to ``center``; Phase G+1 maps to a CSS-shadow-based
    # outside/inside trick.

  discard r.mountPropertyRow(parent, propertyRowColor(
    name = "Color", value = strokeColor, alpha = strokeAlpha,
    binding = vm.inspectorBindingFor("border-color")))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Width", value = strokeWidth, unit = strokeWidthUnit,
    units = @[pxUnit], minValue = some(0.0),
    binding = vm.inspectorBindingFor("border-width")))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Style", value = strokeStyle,
    options = @[
      (label: "Solid", value: "solid"),
      (label: "Dashed", value: "dashed"),
      (label: "Dotted", value: "dotted")],
    binding = vm.inspectorBindingFor("border-style")))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Position", value = strokePosition,
    options = @[
      (label: "Inside", value: "inside"),
      (label: "Center", value: "center"),
      (label: "Outside", value: "outside")]))

  var dashHostEl: E
  let dashHost = ui(r):
    tdiv(ref = dashHostEl,
         `data-stroke-dash-host` = "true",
         display = "none", flex_direction = "column")
  r.appendChild(parent, dashHost)
  discard r.mountPropertyRow(dashHostEl, propertyRowText(
    name = "Dash pattern", value = dashPattern))
  createRenderEffect proc() =
    let solid = strokeStyle.val == "solid"
    r.setStyle(dashHostEl, "display", if solid: "none" else: "flex")
