## Phase G — Effects section body widget.
##
## Inspect selected effect metadata while specialized source editing is
## unavailable. No section-local list can pretend to edit the document.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/viewmodels

type
  EffectEntryKind* = enum
    eekDropShadow
    eekInnerShadow
    eekBlur
    eekBackdropBlur
    eekFilter
    eekTransition

  EffectEntry* = object
    kind*: EffectEntryKind
    label*: string
    visible*: bool

const
  textPrimary = "#ECEDF3"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  border = "#2A2C3A"
  accent = "#7C7AED"

func effectKindLabel*(kind: EffectEntryKind): string =
  case kind
  of eekDropShadow: "Drop shadow"
  of eekInnerShadow: "Inner shadow"
  of eekBlur: "Blur"
  of eekBackdropBlur: "Backdrop blur"
  of eekFilter: "Filter"
  of eekTransition: "Transition"

func effectKindGlyph*(kind: EffectEntryKind): string =
  case kind
  of eekDropShadow: "\xE2\x97\x90"
  of eekInnerShadow: "\xE2\x97\x91"
  of eekBlur: "\xE2\x9D\x96"
  of eekBackdropBlur: "\xE2\x9D\x9D"
  of eekFilter: "\xE2\x9A\x99"
  of eekTransition: "\xE2\x86\x86"

proc mountSectionEffects*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Effects section. The list host is data-attributed so
  ## tests can target it; the empty-state shows when no effects exist.
  let entries = createSignal[seq[EffectEntry]](@[])
  createRenderEffect proc() =
    var selected: seq[EffectEntry]
    for prop in vm.inspector.properties.val:
      let kind = case prop.name
        of "box-shadow": eekDropShadow
        of "filter": eekFilter
        of "backdrop-filter": eekBackdropBlur
        of "transition": eekTransition
        else: continue
      let value = (if prop.authoredValue.len > 0: prop.authoredValue else: prop.value).strip()
      if value.len > 0 and value != "none":
        selected.add EffectEntry(kind: kind, label: prop.name & ": " & value, visible: true)
    entries.val = selected

  var listEl: E
  var emptyEl: E
  var addBtnEl: E

  let body = ui(r):
    tdiv(`data-effects-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "6px", padding = "4px 0"):
      tdiv(ref = listEl,
            `data-effects-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-effects-empty` = "true",
            padding = "8px 0",
            font_size = "11px",
            color = textMuted):
        text "No effect values exposed by this selection."
      tdiv(`data-effects-readonly-message` = "true", role = "note",
            font_size = "11px", color = textMuted):
        text "Effects are read-only here. Edit them in source."
      tdiv(ref = addBtnEl,
            role = "button", tabindex = "0",
            `data-effects-add` = "true",
            `aria-label` = "Add effect",
            `aria-disabled` = "true",
            title = "Effect source editing is unavailable in the inspector.",
            display = "flex", align_items = "center",
            justify_content = "center",
            height = "26px",
            border = "1px dashed " & border,
            border_radius = "4px",
            color = textMuted, font_size = "11px",
            cursor = "default"):
        text "+ Add effect"
  r.appendChild(parent, body)

  proc mountRow(idx: int; entry: EffectEntry) =
    ## Rows show the current selection's metadata, without edit actions.
    let row = ui(r):
      tdiv(`data-effects-row` = $idx,
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            padding = "4px 6px",
            border = "1px solid " & border, border_radius = "4px"):
        span(`aria-hidden` = "true",
              width = "16px", height = "16px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = accent, font_size = "12px"):
          text effectKindGlyph(entry.kind)
        span(flex = "1", min_width = "0",
              color = textPrimary, font_size = "11px",
              overflow_wrap = "anywhere"):
          text (if entry.label.len > 0: entry.label
                else: effectKindLabel(entry.kind))
    r.appendChild(listEl, row)

  proc rebuildList() =
    r.clearChildren(listEl)
    for i in 0 ..< entries.val.len:
      mountRow(i, entries.val[i])

  createRenderEffect proc() =
    rebuildList()
    r.setStyle(emptyEl, "display",
      if entries.val.len == 0: "block" else: "none")
