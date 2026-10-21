## Phase G — Component properties section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   When the selection is a component instance, render the component
##   schema's variant + state + slot properties as property rows. When
##   the selection is NOT a component instance, render the section's
##   empty-state placeholder ("No component schema bound to this
##   selection").
##
## Phase G surfaces a coarse view of the selection's schema-backed
## properties; generated stylesheet and token identity keys are not schemas.
## Phase G+1 wires the variant matrix + slot editors.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/core/batch
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_commit
import isonim/editor/views/widgets/property_row

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  accent = "#7C7AED"

func isComponentSchemaKey(key: string): bool =
  ## Reserved DOM fallback and native declaration identities locate CSS edits;
  ## explicit component API/schema keys retain their existing aliases. These
  ## generated identities do not declare component parameters.
  key.len > 0 and key != "dom" and not key.startsWith("dom.") and
    not key.startsWith("classes.native.") and
    not key.startsWith("tokens.native.")

func isComponentInstance*(element: ElementRef): bool =
  ## Explicit component schema identity on the element or a parameter marks
  ## an instance. Generated DOM/CSS ownership is insufficient.
  if isComponentSchemaKey(element.schemaKey):
    return true
  for prop in element.properties:
    if isComponentSchemaKey(prop.schemaKey):
      return true
  false

proc mountSectionComponentProps*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Component properties section body. The widget rebuilds
  ## its child rows on every ``vm.inspector.properties`` update so
  ## switching selection redraws the schema-backed rows.
  var listEl: E
  var emptyEl: E

  let body = ui(r):
    tdiv(`data-component-props-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "4px", padding = "4px 0"):
      tdiv(ref = listEl,
            `data-component-props-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-component-props-empty` = "true",
            padding = "8px 0", font_size = "11px", color = textMuted):
        text "No component schema bound to this selection"
  r.appendChild(parent, body)

  proc rebuildList(el: ElementRef) =
    r.clearChildren(listEl)
    if not isComponentInstance(el):
      return
    for prop in el.properties:
      if not isComponentSchemaKey(prop.schemaKey):
        continue
      let authored = if prop.authoredValue.len > 0: prop.authoredValue else: prop.value
      let value = createSignal(authored)
      var cfg = propertyRowText(name = prop.name, value = value,
        binding = vm.inspectorBindingFor(prop.name),
        onBindRequest = vm.inspectorBindRequestHandler(prop.name),
        onDetachRequest = vm.inspectorDetachRequestHandler(prop.name),
        wiring = vm.inspectorRowWiring(prop.name))
      let parsed = parseNumericInput(authored)
      # CSS aspect ratios are compound literals, not arithmetic drafts. Keep
      # "4 / 3" intact when a successful commit rebuilds this row.
      if parsed.value.isSome and prop.name != "aspect-ratio":
        let numeric = createSignal(parsed.value.get)
        let authoredUnit = PropertyUnitOption(label: parsed.unit, code: parsed.unit)
        let unit = createSignal(authoredUnit)
        var units = @[authoredUnit]
        if prop.name in ["transition-duration", "transition-delay",
            "animation-duration", "animation-delay"]:
          for code in ["ms", "s"]:
            if code != parsed.unit:
              units.add PropertyUnitOption(label: code, code: code)
        cfg = propertyRowNumeric(name = prop.name, value = numeric, unit = unit,
          units = units, binding = vm.inspectorBindingFor(prop.name),
          onBindRequest = vm.inspectorBindRequestHandler(prop.name),
          onDetachRequest = vm.inspectorDetachRequestHandler(prop.name),
          wiring = vm.inspectorRowWiring(prop.name))
      let row = r.mountPropertyRow(listEl, cfg)
      r.setAttribute(row, "data-component-prop-schema", prop.schemaKey)

  createRenderEffect proc() =
    discard vm.selectedStory.val
    let el = vm.inspector.selectedElement.val
    # Mounting reads each fresh field's initial draft. Those reads belong to
    # its own controls, not the selection effect that replaces every row.
    untrack(proc() = rebuildList(el))
    let visible = isComponentInstance(el)
    r.setStyle(emptyEl, "display",
      if visible: "none" else: "block")
