## Phase G — Typography section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * Font family — prkText.
##   * Font weight — prkChoice.
##   * Font size — prkNumeric (px).
##   * Line height — prkNumeric (unitless).
##   * Letter spacing — prkNumeric (px).
##   * Paragraph spacing — prkNumeric (px).
##   * Text alignment — prkChoice (left / center / right / justify).
##   * Decoration — prkChoice (none / underline / line-through).
##   * Text transform — prkChoice (none / uppercase / lowercase /
##     capitalize).
##   * List style — prkChoice (none / disc / decimal).

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
  unitless = PropertyUnitOption(label: "", code: "")

const textMuted = "#6B6F80"

func isTextLikeTag*(tag: string): bool =
  ## True when the selection is a "text-bearing" tag. The Typography
  ## section is hidden for non-text selections per the spec.
  let lower = tag.toLowerAscii()
  lower in ["p", "h1", "h2", "h3", "h4", "h5", "h6",
            "span", "label", "a", "li", "small", "strong",
            "em", "blockquote", "code", "pre"]

proc mountSectionTypography*[R, E](r: R; parent: E; vm: EditorVM) =
  let fontFamily = createSignal("Inter")
  let fontWeight = createSignal("regular")
  let fontSize = createSignal(16.0)
  let lineHeight = createSignal(1.5)
  let letterSpacing = createSignal(0.0)
  let paragraphSpacing = createSignal(0.0)
  let textAlign = createSignal("left")
  let decoration = createSignal("none")
  let textTransform = createSignal("none")
  let listStyle = createSignal("none")
  let fontSizeUnit = createSignal(pxUnit)
  let lineHeightUnit = createSignal(unitless)
  let letterSpacingUnit = createSignal(pxUnit)
  let paragraphSpacingUnit = createSignal(pxUnit)

  createRenderEffect proc() =
    let props = vm.inspector.properties.val
    fontFamily.val = findPropertyValue(props, "font-family", "Inter")
    let weight = findPropertyValue(props, "font-weight", "400")
    fontWeight.val =
      case weight
      of "100", "thin": "thin"
      of "300", "light": "light"
      of "400", "normal", "regular": "regular"
      of "500", "medium": "medium"
      of "600", "semibold": "semibold"
      of "700", "bold": "bold"
      else: "regular"
    fontSize.val = parseLeadingFloat(findPropertyValue(props, "font-size",
      "16"), 16.0)
    lineHeight.val = parseLeadingFloat(findPropertyValue(props, "line-height",
      "1.5"), 1.5)
    letterSpacing.val = parseLeadingFloat(findPropertyValue(props,
      "letter-spacing", "0"), 0.0)
    paragraphSpacing.val = parseLeadingFloat(findPropertyValue(props,
      "margin-bottom", "0"), 0.0)
    textAlign.val = findPropertyValue(props, "text-align", "left")
    decoration.val = findPropertyValue(props, "text-decoration", "none")
    textTransform.val = findPropertyValue(props, "text-transform", "none")
    listStyle.val = findPropertyValue(props, "list-style-type", "none")

  # Optional empty-state host for non-text selections. The data
  # attribute is the test hook; the property rows mount unconditionally
  # so test seeding works either way.
  var headerHostEl: E
  let headerHost = ui(r):
    tdiv(ref = headerHostEl,
         `data-typography-empty` = "true",
         padding = "4px 0", font_size = "11px", color = textMuted,
         display = "none"):
      text "Selected element is not text-bearing."
  r.appendChild(parent, headerHost)
  createRenderEffect proc() =
    let tag = vm.inspector.selectedElement.val.tag
    let hide = vm.inspector.hasElement.val and not isTextLikeTag(tag)
    r.setStyle(headerHostEl, "display", if hide: "block" else: "none")

  discard r.mountPropertyRow(parent, propertyRowText(
    name = "Font family", value = fontFamily))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Font weight", value = fontWeight,
    options = @[
      (label: "Thin", value: "thin"),
      (label: "Light", value: "light"),
      (label: "Regular", value: "regular"),
      (label: "Medium", value: "medium"),
      (label: "Semibold", value: "semibold"),
      (label: "Bold", value: "bold")]))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Font size", value = fontSize, unit = fontSizeUnit,
    units = @[pxUnit], minValue = some(0.0)))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Line height", value = lineHeight, unit = lineHeightUnit,
    units = @[unitless], minValue = some(0.0)))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Letter spacing", value = letterSpacing,
    unit = letterSpacingUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(parent, propertyRowNumeric(
    name = "Paragraph spacing", value = paragraphSpacing,
    unit = paragraphSpacingUnit, units = @[pxUnit]))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Text alignment", value = textAlign,
    options = @[
      (label: "Left", value: "left"),
      (label: "Center", value: "center"),
      (label: "Right", value: "right"),
      (label: "Justify", value: "justify")]))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Decoration", value = decoration,
    options = @[
      (label: "None", value: "none"),
      (label: "Underline", value: "underline"),
      (label: "Line-through", value: "line-through")]))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "Text transform", value = textTransform,
    options = @[
      (label: "None", value: "none"),
      (label: "Uppercase", value: "uppercase"),
      (label: "Lowercase", value: "lowercase"),
      (label: "Capitalize", value: "capitalize")]))
  discard r.mountPropertyRow(parent, propertyRowChoice(
    name = "List style", value = listStyle,
    options = @[
      (label: "None", value: "none"),
      (label: "Disc", value: "disc"),
      (label: "Decimal", value: "decimal")]))
