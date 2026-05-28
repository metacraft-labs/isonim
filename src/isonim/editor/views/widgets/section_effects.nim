## Phase G — Effects section body widget.
##
## Per the spec (§ "Effects section consolidates Transitions + Filters")
## the Effects section folds in Transitions + Filters. Each effect is a
## row with a type icon + parameter controls inline + visibility toggle
## + delete button. Phase G renders the scaffold:
##
##   * A list host that paints one row per stored effect (initially
##     empty).
##   * A "+ Add effect" pill below the list. (The section header also
##     exposes a ``+`` button; this body-level button mirrors it so the
##     affordance is reachable when the section is scrolled mid-body.)
##   * Per-row controls land in Phase G+1.
##
## The effect entries are stored in a section-local
## ``Signal[seq[EffectEntry]]`` for now. When the editor gains a real
## ``vm.inspector.effects`` signal (Phase H), the section reads from it
## instead.

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
        text "No effects. Press + to add one."
      tdiv(ref = addBtnEl,
            role = "button", tabindex = "0",
            `data-effects-add` = "true",
            `aria-label` = "Add effect",
            display = "flex", align_items = "center",
            justify_content = "center",
            height = "26px",
            border = "1px dashed " & border,
            border_radius = "4px",
            color = textMuted, font_size = "11px",
            cursor = "pointer"):
        text "+ Add effect"
  r.appendChild(parent, body)

  proc mountRow(idx: int; entry: EffectEntry) =
    ## Isolating helper — closure-captures ``idx`` from this proc's
    ## scope so each row's click handlers bind to the right index.
    var visBtnEl: E
    var delBtnEl: E
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
        span(flex = "1",
              color = textPrimary, font_size = "11px",
              overflow = "hidden", text_overflow = "ellipsis",
              white_space = "nowrap"):
          text (if entry.label.len > 0: entry.label
                else: effectKindLabel(entry.kind))
        tdiv(ref = visBtnEl,
              role = "button", tabindex = "0",
              `data-effects-row-visibility` = $idx,
              `aria-label` = "Toggle effect visibility",
              width = "20px", height = "20px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = textMuted, font_size = "11px",
              cursor = "pointer"):
          text (if entry.visible: "\xE2\x97\x90" else: "\xE2\x97\x8B")
        tdiv(ref = delBtnEl,
              role = "button", tabindex = "0",
              `data-effects-row-delete` = $idx,
              `aria-label` = "Delete effect",
              width = "20px", height = "20px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = textMuted, font_size = "11px",
              cursor = "pointer"):
          text "\xC3\x97"
    r.appendChild(listEl, row)
    r.addEventListener(visBtnEl, "click", proc() =
      var next = entries.val
      if idx >= 0 and idx < next.len:
        next[idx].visible = not next[idx].visible
        entries.val = next)
    r.addEventListener(delBtnEl, "click", proc() =
      var next = entries.val
      if idx >= 0 and idx < next.len:
        next.delete(idx)
        entries.val = next)

  proc rebuildList() =
    r.clearChildren(listEl)
    for i in 0 ..< entries.val.len:
      mountRow(i, entries.val[i])

  createRenderEffect proc() =
    rebuildList()
    r.setStyle(emptyEl, "display",
      if entries.val.len == 0: "block" else: "none")

  let onAdd = proc() =
    var next = entries.val
    next.add EffectEntry(kind: eekDropShadow,
      label: "Drop shadow", visible: true)
    entries.val = next
  r.addEventListener(addBtnEl, "click", onAdd)
  r.addEventListener(addBtnEl, "keydown", onAdd)
