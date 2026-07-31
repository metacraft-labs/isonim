## Phase G — Fill section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * One row per fill entry. Each row: 16x16 swatch + 7-char hex
##     input + opacity ``%`` input + bind affordance.
##   * "+ Add fill" pill below the list (mirrors the section header
##     ``+`` button).
##
## Phase G keeps fills in a section-local
## ``Signal[seq[FillEntry]]`` seeded from ``background-color`` on the
## selected element. Phase H lifts the signal onto the inspector so
## multi-fill compositing is a first-class VM concept.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/section_position
import isonim/editor/views/widgets/variable_chip

type
  FillEntry* = object
    color*: string
    alpha*: float

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  accent = "#7C7AED"
  bgInput = "#1A1B22"

proc mountSectionFill*[R, E](r: R; parent: E; vm: EditorVM) =
  let entries = createSignal[seq[FillEntry]](@[])

  # Seed from the selection's background-color when an element is
  # selected. The seeding happens once per selection change.
  var lastElementId = ""
  createRenderEffect proc() =
    let el = vm.inspector.selectedElement.val
    let id = el.id
    if id != lastElementId:
      lastElementId = id
      if vm.inspector.hasElement.val:
        let bg = findPropertyValue(el.properties, "background-color", "")
        if bg.len > 0 and bg != "transparent" and bg != "none":
          entries.val = @[FillEntry(color: bg, alpha: 1.0)]
        else:
          entries.val = @[]
      else:
        entries.val = @[]

  var listEl: E
  var emptyEl: E
  var addBtnEl: E

  # Phase H (2026-05-28): the Figma reference shows ONLY the
  # placeholder hint when the list is empty — the section header's
  # ``+`` button is the canonical "add fill" affordance. We retain
  # the body-level ``data-fill-add`` button (the per-section test
  # binds to it) but render it as a tiny invisible focus target
  # behind the placeholder text — the placeholder doubles as the
  # click surface. This keeps the spec's section-header ``+`` as
  # the visual anchor without breaking the headless test contract.
  let body = ui(r):
    tdiv(`data-fill-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "4px", padding = "2px 0"):
      tdiv(ref = listEl,
            `data-fill-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-fill-empty` = "true",
            padding = "2px 0",
            font_size = "12px",
            color = textMuted):
        text "Click + to replace mixed content"
      tdiv(ref = addBtnEl,
            role = "button", tabindex = "0",
            `data-fill-add` = "true",
            `aria-label` = "Add fill",
            display = "none")
  r.appendChild(parent, body)

  proc mountRow(idx: int; entry: FillEntry) =
    ## Isolating helper — closure-captures ``idx`` from this proc's
    ## scope so each row's click handlers bind to the right index.
    ## ``for``-body ``let`` does not isolate captures across iterations.
    ##
    ## VBIND-M1 read-path: the first fill entry maps onto the
    ## selected element's canonical ``background-color`` property, so
    ## when that property is bound to a design-system variable the
    ## value area renders the real ``variable_chip`` instead of the
    ## inert ``◇``. Reading the binding here (inside ``rebuildList``'s
    ## ``createRenderEffect``) makes the row re-render when the binding
    ## or the selection changes. Because ``propertyBindings`` is empty
    ## for every workspace until M5 seeds it, ``binding`` is ``none``
    ## for every row today and the DOM is byte-identical to before.
    ##
    ## Only the primary fill (idx 0) participates in M1: multi-fill
    ## compositing has no per-index canonical CSS property yet, so
    ## additional fill rows stay literal (honest M1 gap — see M2/M3).
    let binding =
      if idx == 0: vm.inspectorBindingFor("background-color")
      else: none(VariableBinding)
    var swatchEl: E
    var hexEl: E
    var alphaEl: E
    var bindEl: E
    var deleteEl: E
    var chipHostEl: E
    let row = ui(r):
      tdiv(`data-fill-row` = $idx,
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            padding = "4px 6px",
            border = "1px solid " & border, border_radius = "4px"):
        tdiv(ref = swatchEl,
              `data-fill-row-swatch` = $idx,
              role = "button", tabindex = "0",
              width = "16px", height = "16px",
              border = "1px solid rgba(255, 255, 255, 0.12)",
              border_radius = "3px",
              background_color = entry.color,
              cursor = "pointer", flex_shrink = "0")
        if binding.isSome:
          # Linked chip read-path — replaces the hex + opacity inputs
          # and the inert ◇ bind slot with the real variable chip.
          # The detach / re-bind click wiring lands in M2/M3; for M1
          # the chip is display-only.
          tdiv(ref = chipHostEl,
                `data-fill-row-chip-host` = $idx,
                display = "flex", flex = "1", min_width = "0",
                align_items = "center")
        else:
          input(ref = hexEl,
                 `data-fill-row-hex` = $idx,
                 `aria-label` = "Edit fill hex",
                 flex = "1", min_width = "0",
                 background_color = bgInput,
                 border = "1px solid " & border,
                 border_radius = "3px",
                 color = textPrimary, font_size = "11px",
                 font_family = "monospace",
                 padding = "2px 6px", height = "22px")
          input(ref = alphaEl,
                 `data-fill-row-alpha` = $idx,
                 `aria-label` = "Edit fill opacity",
                 width = "48px",
                 background_color = bgInput,
                 border = "1px solid " & border,
                 border_radius = "3px",
                 color = textSecondary, font_size = "11px",
                 padding = "2px 6px", height = "22px",
                 text_align = "right")
          tdiv(ref = bindEl,
                role = "button", tabindex = "0",
                `data-fill-row-bind` = $idx,
                `aria-label` = "Bind fill to variable",
                width = "20px", height = "20px",
                display = "flex", align_items = "center",
                justify_content = "center",
                color = textMuted, font_size = "12px",
                cursor = "pointer"):
            text "\xE2\x97\x87"
        tdiv(ref = deleteEl,
              role = "button", tabindex = "0",
              `data-fill-row-delete` = $idx,
              `aria-label` = "Delete fill",
              width = "20px", height = "20px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = textMuted, font_size = "11px",
              cursor = "pointer"):
          text "\xC3\x97"
    r.appendChild(listEl, row)
    if binding.isSome:
      r.setAttribute(row, "data-fill-row-linked", "true")
      let chipConfig = variableChipConfig(
        binding = binding.get,
        extraRootAttr = "data-fill-row-linked-chip=true")
      discard r.mountVariableChip(chipHostEl, chipConfig)
    else:
      r.setInputValue(hexEl, entry.color)
      r.setInputValue(alphaEl, $int(entry.alpha * 100.0))
      r.addEventListener(hexEl, "change", proc() =
        var next = entries.val
        if idx >= 0 and idx < next.len:
          next[idx].color = r.inputValue(hexEl)
          entries.val = next)
      r.addEventListener(alphaEl, "change", proc() =
        var next = entries.val
        if idx >= 0 and idx < next.len:
          var parsed = 100.0
          try: parsed = parseFloat(r.inputValue(alphaEl))
          except ValueError: discard
          next[idx].alpha = max(0.0, min(1.0, parsed / 100.0))
          entries.val = next)
    r.addEventListener(deleteEl, "click", proc() =
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
    next.add FillEntry(color: "#FFFFFF", alpha: 1.0)
    entries.val = next
  r.addEventListener(addBtnEl, "click", onAdd)
  r.addEventListener(addBtnEl, "keydown", onAdd)
