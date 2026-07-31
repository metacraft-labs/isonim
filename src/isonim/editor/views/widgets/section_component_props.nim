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
## properties (each ``PropertyInfo`` whose ``schemaKey`` is non-empty).
## Phase G+1 wires the variant matrix + slot editors.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_row

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  accent = "#7C7AED"

func isComponentInstance*(element: ElementRef): bool =
  ## A selection is treated as a component instance when at least one
  ## of its properties carries a non-empty ``schemaKey`` — i.e. the
  ## source map points at a schema entry rather than a raw DOM literal.
  if element.schemaKey.len > 0:
    return true
  for prop in element.properties:
    if prop.schemaKey.len > 0:
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

  proc rebuildList() =
    r.clearChildren(listEl)
    let el = vm.inspector.selectedElement.val
    if not isComponentInstance(el):
      return
    for prop in el.properties:
      if prop.schemaKey.len == 0:
        continue
      let value = createSignal(prop.value)
      let cfg = propertyRowText(name = prop.name, value = value,
        binding = vm.inspectorBindingFor(prop.name),
        onBindRequest = vm.inspectorBindRequestHandler(prop.name))
      let row = r.mountPropertyRow(listEl, cfg)
      r.setAttribute(row, "data-component-prop-schema", prop.schemaKey)

  createRenderEffect proc() =
    rebuildList()
    let el = vm.inspector.selectedElement.val
    let visible = isComponentInstance(el)
    r.setStyle(emptyEl, "display",
      if visible: "none" else: "block")
