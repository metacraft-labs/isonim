## Phase G — Selection colors section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   Auto-aggregated list of unique colours present in the current
##   selection. Each row: swatch + hex + opacity % + bind affordance.
##   Literal values inspect document CSS; unique editable owners use the
##   existing workspace variable binding and detach machinery.
##
## "Unique colours" come from walking ``vm.inspector.properties.val``
## and pulling values from any property whose name is colour-flavoured
## (background, text, border and outline colour properties).

import std/[options, sets, strutils, math]

import isonim/core/owner
import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/css_color_literal
import isonim/editor/views/widgets/[property_commit, property_row, anchored_popover, variable_chip]

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
  literalColorChannels(value).valid

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
    let channels = literalColorChannels(v)
    let key = $channels
    if key in seen: continue
    seen.incl key
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

  # Stable wiring is owned by the section, not recreated by row render effects.
  var wirings: array[colorPropertyNames.len, InspectorRowWiring]
  for i, property in colorPropertyNames:
    wirings[i] = vm.inspectorRowWiring(property)
  var disposeRows: proc()
  onCleanup(proc() =
    if disposeRows != nil: disposeRows())

  proc mountRow(idx: int; value, property, reason: string;
      binding: Option[VariableBinding]) =
    let channels = literalColorChannels(value)
    let target = vm.inspectorBindingKeyFor(property)
    let story = vm.selectedStory.val
    var active = true
    onCleanup(proc() = active = false)
    proc currentTarget(): bool =
      let now = vm.selectedStory.val
      active and vm.inspectorBindingKeyFor(property) == target and
        now.group == story.group and now.name == story.name and now.kind == story.kind
    var bindEl, chipHost: E
    let row = ui(r):
      tdiv(`data-selection-color-row` = $idx,
            `data-inspector-search-label` = "Selection color",
            `data-selection-color-property` = property,
            display = "flex", flex_direction = "column", gap = "4px",
            padding = "4px 6px", border = "1px solid " & border,
            border_radius = "4px"):
        tdiv(display = "flex", align_items = "center", gap = "6px"):
          tdiv(`data-selection-color-swatch` = $idx,
                width = "16px", height = "16px",
                border = "1px solid rgba(255, 255, 255, 0.12)",
                border_radius = "3px", background_color = value, flex_shrink = "0")
          span(`data-selection-color-hex` = $idx,
                flex = "1", min_width = "0", color = textPrimary,
                font_size = "11px", font_family = "monospace"):
            text "#" & toHex(channels.red, 2) & toHex(channels.green, 2) & toHex(channels.blue, 2)
          span(`data-selection-color-opacity` = $idx,
                color = textSecondary, font_size = "11px"):
            text $int(round(channels.alpha.float * 100 / 255)) & "%"
          tdiv(ref = chipHost, `data-selection-color-chip-host` = $idx,
                `aria-disabled` = (if reason.len > 0: "true" else: "false"),
                title = reason)
          tdiv(ref = bindEl, role = "button", tabindex = "0",
                `data-selection-color-bind` = $idx,
                `aria-label` = "Bind selection color to variable",
                `aria-disabled` = (if reason.len > 0: "true" else: "false"),
                title = reason, width = "20px", height = "20px",
                display = (if binding.isSome: "none" else: "flex"),
                align_items = "center", justify_content = "center",
                color = textMuted, font_size = "12px",
                cursor = (if reason.len > 0: "default" else: "pointer")):
            text "\xE2\x97\x87"
        if reason.len > 0:
          span(`data-selection-color-reason` = $idx, role = "note",
                color = textMuted, font_size = "10px"):
            text reason
    r.appendChild(listEl, row)
    proc openPicker(anchor: E) =
      if not currentTarget() or reason.len > 0: return
      let rc = measureAnchorRect(anchor)
      vm.requestInspectorVariablePicker(property, rc.x, rc.y, rc.w, rc.h)
    if binding.isSome:
      var chip: E
      chip = r.mountVariableChip(chipHost, variableChipConfig(
        binding = binding.get,
        onChevronClick = (if reason.len == 0: (proc() = openPicker(chip)) else: nil),
        onDetach = (if reason.len == 0: (proc() =
          if currentTarget(): vm.inspectorDetachRequestHandler(property)()) else: nil),
        unavailableReason = (if reason.len > 0: reason else: "Variable name editing is unavailable in Selection Colors."),
        extraRootAttr = "data-selection-color-linked-chip=true"))
    else:
      installPopoverTrigger(bindEl)
      r.addEventListener(bindEl, "click", proc() = openPicker(bindEl))

  createRenderEffect proc() =
    if disposeRows != nil: disposeRows()
    r.clearChildren(listEl)
    let properties = vm.inspector.properties.val
    let colors = collectSelectionColors(properties)
    # Resolve every owner before mounting isolated row scopes. Equal RGBA values
    # from several properties cannot silently choose one source target.
    var rows: seq[tuple[value, property, reason: string, binding: Option[VariableBinding]]]
    for value in colors:
      var owners: seq[PropertyInfo]
      for prop in properties:
        if prop.name in colorPropertyNames and
            literalColorChannels(prop.value) == literalColorChannels(value):
          owners.add prop
      var property = ""
      var reason = ""
      if owners.len != 1:
        reason = "This color belongs to multiple properties. Bind each property in its own section."
      else:
        property = owners[0].name
        for i, name in colorPropertyNames:
          if name == property: reason = wirings[i].readOnlyReason()
        if reason.len == 0:
          var editable = false
          for choice in vm.sourceScopeChoices(owners[0]):
            if choice.editable: editable = true
          if not editable:
            reason = "Read-only: this color has no editable source owner."
      let binding = if property.len > 0: vm.inspectorBindingFor(property)
                    else: none(VariableBinding)
      rows.add (value, property, reason, binding)
    createRoot do (dispose: proc()):
      disposeRows = dispose
      for i, row in rows:
        mountRow(i, row.value, row.property, row.reason, row.binding)
    r.setStyle(emptyEl, "display", if colors.len == 0: "block" else: "none")
