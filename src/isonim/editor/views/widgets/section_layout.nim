## Phase G — Layout section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * Layout mode — 4-button row (none / vertical / horizontal / grid),
##     mapping to CSS ``display: block | flex-column | flex-row | grid``.
##   * W / H — numeric inputs (px unit).
##   * Constraint icon — placeholder square.
##   * Gap — numeric, visible only when flex or grid.
##   * Padding — four numeric inputs (top / right / bottom / left).
##   * Overflow — segmented choice (visible / hidden / scroll / auto).

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_row
import isonim/editor/views/widgets/section_position

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  border = "#2A2C3A"
  accent = "#7C7AED"

const
  pxUnit = PropertyUnitOption(label: "px", code: "px")

proc mountSectionLayout*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Layout section body. The widget owns its own local
  ## signals so a selection change rebinds the seeds via a render
  ## effect rather than re-mounting the DOM tree.
  let layoutMode = createSignal("block")
  let width = createSignal(0.0)
  let height = createSignal(0.0)
  let widthUnit = createSignal(pxUnit)
  let heightUnit = createSignal(pxUnit)
  let gap = createSignal(0.0)
  let gapUnit = createSignal(pxUnit)
  let padTop = createSignal(0.0)
  let padRight = createSignal(0.0)
  let padBottom = createSignal(0.0)
  let padLeft = createSignal(0.0)
  let padUnit = createSignal(pxUnit)
  let overflow = createSignal("visible")

  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    let display = findPropertyValue(props, "display", "block")
    let flexDir = findPropertyValue(props, "flex-direction", "row")
    layoutMode.val =
      if display == "grid": "grid"
      elif display == "flex" and flexDir == "column": "vertical"
      elif display == "flex": "horizontal"
      else: "none"
    width.val = parseLeadingFloat(findPropertyValue(props, "width", "0"), 0.0)
    height.val = parseLeadingFloat(findPropertyValue(props, "height", "0"), 0.0)
    gap.val = parseLeadingFloat(findPropertyValue(props, "gap", "0"), 0.0)
    padTop.val = parseLeadingFloat(findPropertyValue(props, "padding-top",
      findPropertyValue(props, "padding", "0")), 0.0)
    padRight.val = parseLeadingFloat(findPropertyValue(props, "padding-right",
      findPropertyValue(props, "padding", "0")), 0.0)
    padBottom.val = parseLeadingFloat(findPropertyValue(props, "padding-bottom",
      findPropertyValue(props, "padding", "0")), 0.0)
    padLeft.val = parseLeadingFloat(findPropertyValue(props, "padding-left",
      findPropertyValue(props, "padding", "0")), 0.0)
    overflow.val = findPropertyValue(props, "overflow", "visible")

  # ----- Layout mode button row ------------------------------------ #
  # Four icon buttons. The active one carries ``data-layout-mode-
  # active="true"`` so the per-section test can pin the choice.
  var modeButtons: array[4, E]
  let modes = ["none", "vertical", "horizontal", "grid"]
  let modeGlyphs = ["\xE2\x9A\xAC", "\xE2\x86\x95",
                    "\xE2\x86\x94", "\xE2\x96\xA6"]
  let modeRow = ui(r):
    tdiv(`data-layout-mode-row` = "true",
         display = "flex", flex_direction = "row",
         gap = "4px", padding = "4px 0"):
      for i, slug in modes:
        tdiv(ref = modeButtons[i],
              role = "button", tabindex = "0",
              `data-layout-mode` = slug,
              `aria-label` = "Set layout to " & slug,
              display = "flex", align_items = "center",
              justify_content = "center",
              width = "32px", height = "26px",
              border = "1px solid " & border, border_radius = "4px",
              color = textMuted, font_size = "12px", cursor = "pointer"):
          text modeGlyphs[i]
  r.appendChild(parent, modeRow)
  proc bindModeClick(btn: E; slug: string) =
    ## Isolating helper — closure-captures ``slug`` in a dedicated
    ## scope so each click handler binds to the right mode string. A
    ## bare ``let`` inside the ``for`` body shares its binding across
    ## the loop iterations in Nim (the closure captures the variable
    ## by reference, not by value).
    r.addEventListener(btn, "click", proc() = layoutMode.val = slug)
    r.addEventListener(btn, "keydown", proc() = layoutMode.val = slug)
  for i, slug in modes:
    bindModeClick(modeButtons[i], slug)
  createRenderEffect proc() =
    let active = layoutMode.val
    for i, slug in modes:
      let isActive = slug == active
      r.setAttribute(modeButtons[i], "data-layout-mode-active",
        if isActive: "true" else: "false")
      r.setStyle(modeButtons[i], "background-color",
        if isActive: accent else: "transparent")
      r.setStyle(modeButtons[i], "color",
        if isActive: textPrimary else: textMuted)

  # ----- W / H + constraint icon row ------------------------------- #
  # Two numeric rows + a placeholder constraint glyph. The glyph is a
  # data marker for the per-section test; Phase G+1 wires a real
  # constraint editor.
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "W", value = width, unit = widthUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "H", value = height, unit = heightUnit, units = @[pxUnit]))
  let constraintRow = ui(r):
    tdiv(`data-layout-constraint` = "true",
         display = "flex", align_items = "center", gap = "8px",
         padding = "4px 0", font_size = "11px", color = textMuted):
      tdiv(width = "24px", height = "24px",
            border = "1px solid " & border, border_radius = "4px",
            display = "flex", align_items = "center",
            justify_content = "center"):
        text "\xE2\x9F\x8B"
      text "Constraints (auto)"
  r.appendChild(parent, constraintRow)

  # ----- Gap (visible only for flex / grid) ------------------------ #
  var gapHostEl: E
  let gapHost = ui(r):
    tdiv(ref = gapHostEl,
         `data-layout-gap-host` = "true",
         display = "flex", flex_direction = "column")
  r.appendChild(parent, gapHost)
  discard r.mountPropertyRow(gapHostEl, propertyRowNumeric(
    name = "Gap", value = gap, unit = gapUnit, units = @[pxUnit]))
  createRenderEffect proc() =
    let m = layoutMode.val
    let visible = m in ["vertical", "horizontal", "grid"]
    r.setStyle(gapHostEl, "display", if visible: "flex" else: "none")

  # ----- Padding (4 sides) ----------------------------------------- #
  var padHostEl: E
  let padHost = ui(r):
    tdiv(ref = padHostEl,
         `data-layout-padding-host` = "true",
         display = "flex", flex_direction = "column")
  r.appendChild(parent, padHost)
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad top", value = padTop, unit = padUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad right", value = padRight, unit = padUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad bottom", value = padBottom, unit = padUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(padHostEl, propertyRowNumeric(
    name = "Pad left", value = padLeft, unit = padUnit, units = @[pxUnit]))
  createRenderEffect proc() =
    let m = layoutMode.val
    let visible = m in ["vertical", "horizontal", "grid"]
    r.setStyle(padHostEl, "display", if visible: "flex" else: "none")

  # ----- Overflow choice ------------------------------------------- #
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Overflow", value = overflow,
    options = @[
      (label: "Visible", value: "visible"),
      (label: "Hidden", value: "hidden"),
      (label: "Scroll", value: "scroll"),
      (label: "Auto", value: "auto")]))
