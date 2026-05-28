## Phase G — Selection colors section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   Auto-aggregated list of unique colours present in the current
##   selection. Each row: swatch + hex + opacity % + bind affordance.
##   Read-only for Phase G except the bind affordance (placeholder).
##
## "Unique colours" come from walking ``vm.inspector.properties.val``
## and pulling values from any property whose name is colour-flavoured
## (``background-color``, ``color``, ``border-color`` and ``box-shadow``
## first-token best-effort).

import std/[options, sets, strutils, sequtils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  bgInput = "#1A1B22"

const colorPropertyNames = [
  "background-color", "color", "border-color", "outline-color",
  "border-top-color", "border-right-color",
  "border-bottom-color", "border-left-color"]

func looksLikeColor*(value: string): bool =
  ## Coarse predicate: ``#xxx``, ``#xxxxxx``, ``rgb(...)`` or
  ## ``rgba(...)`` shaped string. The auto-aggregation skips literals
  ## that don't look like a colour so a ``box-shadow: none`` doesn't
  ## land in the list.
  let trimmed = value.strip()
  if trimmed.len == 0: return false
  if trimmed.startsWith("#") and (trimmed.len == 4 or trimmed.len == 7):
    return true
  if trimmed.startsWith("rgb(") or trimmed.startsWith("rgba("):
    return true
  false

proc collectSelectionColors*(properties: seq[PropertyInfo]): seq[string] =
  ## Walks ``properties`` and returns the de-duplicated colour values
  ## present on the selection. Order matches first appearance so the
  ## list reads in CSS-cascade order.
  var seen = initHashSet[string]()
  for prop in properties:
    if prop.name notin colorPropertyNames:
      continue
    let v = prop.value.strip()
    if not looksLikeColor(v):
      continue
    if v in seen: continue
    seen.incl v
    result.add v

proc mountSectionSelectionColors*[R, E](r: R; parent: E; vm: EditorVM) =
  var listEl: E
  var emptyEl: E

  let body = ui(r):
    tdiv(`data-selection-colors-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "4px", padding = "4px 0"):
      tdiv(ref = listEl,
            `data-selection-colors-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-selection-colors-empty` = "true",
            padding = "8px 0", font_size = "11px", color = textMuted):
        text "No colors in selection"
  r.appendChild(parent, body)

  proc rebuildList() =
    r.clearChildren(listEl)
    let colors = collectSelectionColors(vm.inspector.properties.val)
    for i, color in colors:
      let idx = i
      let value = color
      let row = ui(r):
        tdiv(`data-selection-color-row` = $idx,
              display = "flex", flex_direction = "row",
              align_items = "center", gap = "6px",
              padding = "4px 6px",
              border = "1px solid " & border, border_radius = "4px"):
          tdiv(`data-selection-color-swatch` = $idx,
                width = "16px", height = "16px",
                border = "1px solid rgba(255, 255, 255, 0.12)",
                border_radius = "3px",
                background_color = value,
                flex_shrink = "0")
          span(`data-selection-color-hex` = $idx,
                flex = "1", min_width = "0",
                color = textPrimary, font_size = "11px",
                font_family = "monospace",
                overflow = "hidden", text_overflow = "ellipsis",
                white_space = "nowrap"):
            text value
          span(`data-selection-color-opacity` = $idx,
                color = textSecondary, font_size = "11px"):
            text "100%"
          tdiv(role = "button", tabindex = "0",
                `data-selection-color-bind` = $idx,
                `aria-label` = "Bind selection color to variable",
                width = "20px", height = "20px",
                display = "flex", align_items = "center",
                justify_content = "center",
                color = textMuted, font_size = "12px",
                cursor = "pointer"):
            text "\xE2\x97\x87"
      r.appendChild(listEl, row)

  createRenderEffect proc() =
    rebuildList()
    let count = collectSelectionColors(vm.inspector.properties.val).len
    r.setStyle(emptyEl, "display",
      if count == 0: "block" else: "none")
