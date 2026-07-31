## Phase G — Position section body widget.
##
## Renders the Position section's property rows inside the empty body
## slot the Phase B section frame leaves in
## ``shell.nim::renderSectionFrame``. The catalogue (see
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md`` § "Section
## catalogue") prescribes:
##
##   * Horizontal align — 3-button row (left / center / right).
##   * Vertical align   — 3-button row (top / middle / bottom).
##   * Distribute       — 1 button (spacing distribution placeholder).
##   * X / Y            — numeric inputs.
##   * Rotation         — numeric input with ``°`` unit.
##   * Flip horizontal / vertical — 2 buttons.
##
## Source-of-truth: the X / Y / rotation inputs reactively follow the
## current selection's ``left`` / ``top`` / ``transform`` CSS properties
## via ``vm.inspector.properties`` (the memo exposed in
## ``viewmodels.nim``). Editing a row's value writes back to the local
## signal; Phase G+1 will plumb the writeback through the source-edit
## pipeline. For now the widget keeps section autonomy: the section
## owns small local Signal[T] state seeded from the selection.
##
## Empty-state contract: when no element is selected the section
## renders a single ``textMuted`` placeholder ("Select an element");
## the property rows do not mount until ``hasElement`` flips true. A
## reactive effect tears down + remounts on selection change so the
## seed values stay aligned with the new properties.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_row

# --------------------------------------------------------------------------- #
#  Local theme tokens — mirrored from ``shell.nim``. Kept inline so the
#  widget compiles without a circular dependency on the shell.
# --------------------------------------------------------------------------- #
const
  textMuted = "#6B6F80"
  textDim   = "#4A4D5C"
  textPrimary = "#ECEDF3"
  border    = "#2A2C3A"

# --------------------------------------------------------------------------- #
#  Property lookup helpers — small enough to inline per section so each
#  module stays self-contained (no shared utility module to drift).
# --------------------------------------------------------------------------- #

proc findPropertyValue*(properties: seq[PropertyInfo]; name,
    fallback: string): string =
  ## Returns the value of ``name`` in ``properties`` or ``fallback`` when
  ## absent. Exported so the per-section tests can compute expected
  ## seeds without recreating the lookup.
  for prop in properties:
    if prop.name == name:
      return prop.value
  fallback

proc parseLeadingFloat*(raw: string; fallback: float): float =
  ## Parse the leading numeric prefix of ``raw`` (drops a trailing unit
  ## suffix like ``"px"`` / ``"%"`` / ``"deg"``). Used to seed
  ## ``Signal[float]`` from a CSS-string property.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return fallback
  var i = 0
  if i < trimmed.len and trimmed[i] in {'+', '-'}:
    inc i
  let numStart = i
  while i < trimmed.len and trimmed[i] in {'0'..'9', '.'}:
    inc i
  if i == numStart:
    return fallback
  try:
    return parseFloat(trimmed[0 ..< i])
  except ValueError:
    return fallback

# --------------------------------------------------------------------------- #
#  Unit option constants — shared between the four numeric rows so the
#  unit chip displays the right glyph on the first paint.
# --------------------------------------------------------------------------- #
const
  pxUnit = PropertyUnitOption(label: "px", code: "px")
  degUnit = PropertyUnitOption(label: "\xC2\xB0", code: "deg")

# --------------------------------------------------------------------------- #
#  Mount.
# --------------------------------------------------------------------------- #

proc mountSectionPosition*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Populate ``parent`` (a Phase B section body slot) with the Position
  ## section's controls. The widget consumes ``vm.inspector`` reactive
  ## state and renders the alignment buttons + X / Y / rotation rows +
  ## flip buttons described in the spec.
  ##
  ## Mount steps:
  ##   1. Render an alignment + distribute row strip.
  ##   2. Render X, Y, rotation rows via ``mountPropertyRow``.
  ##   3. Render a flip horizontal / flip vertical button row.
  ##   4. Append a "Select an element" empty-state when no selection
  ##      is active.

  # Local signals — seeded from the current selection. A render effect
  # keeps them in sync when the selection changes upstream so the user
  # sees the new element's values on the same widget instance.
  let xValue = createSignal(0.0)
  let yValue = createSignal(0.0)
  let rotationValue = createSignal(0.0)
  let xUnit = createSignal(pxUnit)
  let yUnit = createSignal(pxUnit)
  let rotUnit = createSignal(degUnit)
  let hAlign = createSignal("left")
  let vAlign = createSignal("top")

  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    xValue.val = parseLeadingFloat(findPropertyValue(props, "left", "0"), 0.0)
    yValue.val = parseLeadingFloat(findPropertyValue(props, "top", "0"), 0.0)
    # Pull a ``rotate(Ndeg)`` style hint out of ``transform`` — best-
    # effort; users with arbitrary transform strings see 0 until they
    # commit a rotation.
    let raw = findPropertyValue(props, "transform", "")
    var rot = 0.0
    let idx = raw.find("rotate(")
    if idx >= 0:
      let inner = raw.substr(idx + len("rotate("))
      rot = parseLeadingFloat(inner, 0.0)
    rotationValue.val = rot
    let justify = findPropertyValue(props, "justify-self",
      findPropertyValue(props, "text-align", "left"))
    hAlign.val = justify
    let align = findPropertyValue(props, "align-self", "top")
    vAlign.val = align

  # ----- Alignment + distribute strip ------------------------------ #
  # Phase G renders the strip as three clusters: horizontal-align (3
  # buttons), vertical-align (3 buttons), distribute (1 button). The
  # active button reads ``data-position-align-active="true"`` so the
  # per-section test can pin selection without coupling to colours.
  #
  # Phase H (2026-05-28): each cluster reads as a tight segmented
  # icon group on a quiet input-coloured trough — borderless inside
  # but the trough surface gives the cluster a single rounded pill.
  # Mirrors Figma's tightly-packed alignment-button row.
  let alignmentRow = ui(r):
    tdiv(`data-position-alignment-row` = "true",
         display = "flex", flex_direction = "row", align_items = "center",
         gap = "4px", padding = "2px 0"):
      tdiv(`data-position-alignment-cluster` = "horizontal",
            display = "flex",
            background_color = "#1A1B22",
            border_radius = "4px",
            padding = "1px"):
        for slug in ["left", "center", "right"]:
          tdiv(role = "button", tabindex = "0",
                `data-position-align` = slug,
                `aria-label` = "Align " & slug,
                display = "flex", align_items = "center",
                justify_content = "center",
                width = "26px", height = "22px",
                border_radius = "3px",
                color = textMuted,
                font_size = "12px",
                cursor = "pointer"):
            text (if slug == "left": "\xE2\x86\xA4"
                  elif slug == "center": "\xE2\x86\x94"
                  else: "\xE2\x86\xA6")
      tdiv(`data-position-alignment-cluster` = "vertical",
            display = "flex",
            background_color = "#1A1B22",
            border_radius = "4px",
            padding = "1px"):
        for slug in ["top", "middle", "bottom"]:
          tdiv(role = "button", tabindex = "0",
                `data-position-valign` = slug,
                `aria-label` = "Vertical align " & slug,
                display = "flex", align_items = "center",
                justify_content = "center",
                width = "26px", height = "22px",
                border_radius = "3px",
                color = textMuted,
                font_size = "12px",
                cursor = "pointer"):
            text (if slug == "top": "\xE2\x86\xA5"
                  elif slug == "middle": "\xE2\x86\x95"
                  else: "\xE2\x86\xA7")
      tdiv(`data-position-alignment-cluster` = "distribute",
            display = "flex",
            background_color = "#1A1B22",
            border_radius = "4px",
            padding = "1px",
            margin_left = "auto"):
        tdiv(role = "button", tabindex = "0",
              `data-position-distribute` = "spacing",
              `aria-label` = "Distribute spacing",
              display = "flex", align_items = "center",
              justify_content = "center",
              width = "26px", height = "22px",
              border_radius = "3px",
              color = textMuted,
              font_size = "12px",
              cursor = "pointer"):
          text "\xE2\x87\x84"
  r.appendChild(parent, alignmentRow)

  # ----- X / Y / rotation property rows ---------------------------- #
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "X", value = xValue, unit = xUnit,
    units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("left"),
    onBindRequest = vm.inspectorBindRequestHandler("left"),
    onDetachRequest = vm.inspectorDetachRequestHandler("left")))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Y", value = yValue, unit = yUnit,
    units = @[pxUnit],
    bindingReactive = vm.inspectorBindingThunk("top"),
    onBindRequest = vm.inspectorBindRequestHandler("top"),
    onDetachRequest = vm.inspectorDetachRequestHandler("top")))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Rotation", value = rotationValue, unit = rotUnit,
    units = @[degUnit],
    bindingReactive = vm.inspectorBindingThunk("transform"),
    onBindRequest = vm.inspectorBindRequestHandler("transform"),
    onDetachRequest = vm.inspectorDetachRequestHandler("transform")))

  # ----- Flip buttons ---------------------------------------------- #
  # Phase H (2026-05-28): flip controls render as compact icon
  # buttons inside a quiet pill row matching the Figma reference's
  # rotation/flip cluster. The pill carries the same input-trough
  # background as the alignment clusters above so the rhythm is
  # consistent across all section button rows.
  let flipRow = ui(r):
    tdiv(`data-position-flip-row` = "true",
         display = "flex", flex_direction = "row",
         align_items = "center", gap = "4px",
         padding = "2px 0"):
      tdiv(display = "flex",
            background_color = "#1A1B22",
            border_radius = "4px",
            padding = "1px",
            margin_left = "auto"):
        tdiv(role = "button", tabindex = "0",
              `data-position-flip` = "horizontal",
              `aria-label` = "Flip horizontally",
              display = "flex", align_items = "center",
              justify_content = "center",
              width = "26px", height = "22px",
              border_radius = "3px",
              color = textMuted, font_size = "13px",
              cursor = "pointer"):
          text "\xE2\x96\xB7\xE2\x97\x81"  # ▷◁
        tdiv(role = "button", tabindex = "0",
              `data-position-flip` = "vertical",
              `aria-label` = "Flip vertically",
              display = "flex", align_items = "center",
              justify_content = "center",
              width = "26px", height = "22px",
              border_radius = "3px",
              color = textMuted, font_size = "13px",
              cursor = "pointer"):
          text "\xE2\x96\xBD\xE2\x96\xB3"  # ▽△
  r.appendChild(parent, flipRow)

  # ----- Empty-state shadow ---------------------------------------- #
  # When no element is selected the section reads "Select an element"
  # below the rows. We keep the rows mounted (so a future selection
  # transitions in place) and hide the empty-state otherwise.
  var emptyEl: E
  let empty = ui(r):
    tdiv(ref = emptyEl,
         `data-position-empty` = "true",
         padding = "2px 0 0 0",
         font_size = "11px",
         color = textDim):
      text "Select an element"
  r.appendChild(parent, empty)
  createRenderEffect proc() =
    r.setAttribute(emptyEl, "data-position-empty-visible",
      if vm.inspector.hasElement.val: "false" else: "true")
    r.setStyle(emptyEl, "display",
      if vm.inspector.hasElement.val: "none" else: "block")
