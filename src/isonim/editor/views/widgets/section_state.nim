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

import isonim/core/[signals, batch]
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/property_commit
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

type StateFocusTarget* = tuple[
  group, name: string, kind: StoryKind, id, domPath: string]

func stateFocusTarget*(story: StoryRef; element: ElementRef): StateFocusTarget =
  (story.group, story.name, story.kind, element.id, element.domPath)

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

  var renderedTarget: StateFocusTarget
  proc rebuildList() =
    let el = vm.inspector.selectedElement.val
    let story = vm.selectedStory.val
    let target = stateFocusTarget(story, el)
    let sameTarget = target == renderedTarget
    when defined(js):
      # Accepted commits replace selected metadata. Preserve the active State
      # field for another keyboard edit, without carrying focus to a new target.
      {.emit: ["""
      var stateFocusProperty = '', stateFocusStart = null, stateFocusEnd = null;
      if (""", sameTarget, """ && typeof document !== 'undefined' &&
          typeof """, listEl, """.contains === 'function') {
        var active = document.activeElement;
        if (active && """, listEl, """.contains(active) && active.matches('[data-property-row-input]')) {
          var activeRow = active.closest('[data-property-row-css-property]');
          stateFocusProperty = activeRow ? activeRow.getAttribute('data-property-row-css-property') : '';
          stateFocusStart = active.selectionStart; stateFocusEnd = active.selectionEnd;
        }
      }
      """].}
    r.clearChildren(listEl)
    let entries = collectReactiveProperties(vm.inspector.properties.val)
    for prop in entries:
      let value = createSignal(prop.value)
      let row = r.mountPropertyRow(listEl,
        propertyRowText(name = prop.name, value = value,
          binding = vm.inspectorBindingFor(prop.name),
          onBindRequest = vm.inspectorBindRequestHandler(prop.name),
          onDetachRequest = vm.inspectorDetachRequestHandler(prop.name),
          wiring = vm.inspectorRowWiring(prop.name)))
      r.setAttribute(row, "data-state-signal-origin", prop.originDetail)
    renderedTarget = target
    when defined(js):
      {.emit: ["""
      if (stateFocusProperty) {
        var inputs = """, listEl, """.querySelectorAll('[data-property-row-input]');
        for (var i = 0; i < inputs.length; i++) {
          var row = inputs[i].closest('[data-property-row-css-property]');
          if (row && row.getAttribute('data-property-row-css-property') === stateFocusProperty) {
            inputs[i].focus();
            if (stateFocusStart !== null) inputs[i].setSelectionRange(stateFocusStart, stateFocusEnd);
            break;
          }
        }
      }
      """].}

  createRenderEffect proc() =
    discard vm.selectedStory.val
    # Field drafts belong to their row, not to the effect replacing the list.
    # A text commit updates its draft before calling the guarded writer.
    untrack(proc() = rebuildList())
    let entries = collectReactiveProperties(vm.inspector.properties.val)
    r.setStyle(emptyEl, "display",
      if entries.len == 0: "block" else: "none")
