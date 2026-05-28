## Phase G — State section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   When the selection has reactive Signal-backed state, render each
##   ``Signal[T]``'s current value as an editable property row.
##   Replaces the prior 12-tab "State" surface.
##
## The inspector's data model exposes a list of ``PropertyInfo``
## entries — a Signal-backed property is one whose
## ``origin == poSetStyle`` (a direct setStyle call on the live element)
## or whose ``originDetail`` starts with ``signal:``. Phase G surfaces
## those rows; full Signal[T] introspection lands in Phase H once the
## reactive runtime exposes a debug iterator.

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

func isReactiveStateProperty*(prop: PropertyInfo): bool =
  ## Heuristic: a property is "Signal-backed" when its origin is
  ## ``poSetStyle`` (likely a direct setStyle from a Nim closure) or
  ## when its ``originDetail`` carries the ``signal:`` marker the
  ## source-edit pipeline writes for known reactive bindings.
  if prop.originDetail.startsWith("signal:"):
    return true
  prop.origin == poSetStyle

proc collectReactiveProperties*(properties: seq[PropertyInfo]): seq[PropertyInfo] =
  for prop in properties:
    if isReactiveStateProperty(prop):
      result.add prop

proc mountSectionState*[R, E](r: R; parent: E; vm: EditorVM) =
  var listEl: E
  var emptyEl: E

  let body = ui(r):
    tdiv(`data-state-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "4px", padding = "4px 0"):
      tdiv(ref = listEl,
            `data-state-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-state-empty` = "true",
            padding = "8px 0", font_size = "11px", color = textMuted):
        text "No reactive state in selection"
  r.appendChild(parent, body)

  proc rebuildList() =
    r.clearChildren(listEl)
    let entries = collectReactiveProperties(vm.inspector.properties.val)
    for prop in entries:
      let value = createSignal(prop.value)
      let row = r.mountPropertyRow(listEl,
        propertyRowText(name = prop.name, value = value))
      r.setAttribute(row, "data-state-signal-origin", prop.originDetail)

  createRenderEffect proc() =
    rebuildList()
    let entries = collectReactiveProperties(vm.inspector.properties.val)
    r.setStyle(emptyEl, "display",
      if entries.len == 0: "block" else: "none")
