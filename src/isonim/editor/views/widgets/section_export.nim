## Phase G — Export section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * One row per export entry. Each row: size selector (1x / 2x /
##     3x) + format (PNG / SVG / PDF) + suffix input.
##   * "+ Add export" pill mirroring the section header's ``+`` button.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/viewmodels

type
  ExportFormat* = enum
    efPng
    efSvg
    efPdf

  ExportSize* = enum
    es1x
    es2x
    es3x

  ExportEntry* = object
    size*: ExportSize
    format*: ExportFormat
    suffix*: string

const
  textMuted = "#6B6F80"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  border = "#2A2C3A"
  accent = "#7C7AED"
  bgInput = "#1A1B22"

func formatLabel*(f: ExportFormat): string =
  case f
  of efPng: "PNG"
  of efSvg: "SVG"
  of efPdf: "PDF"

func sizeLabel*(s: ExportSize): string =
  case s
  of es1x: "1x"
  of es2x: "2x"
  of es3x: "3x"

proc mountSectionExport*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Export section body. The entries live in a local signal
  ## for Phase G; Phase H will lift them to ``vm.inspector.exports``.
  let entries = createSignal[seq[ExportEntry]](@[])

  var listEl: E
  var emptyEl: E
  var addBtnEl: E

  let body = ui(r):
    tdiv(`data-export-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "6px", padding = "4px 0"):
      tdiv(ref = listEl,
            `data-export-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "4px")
      tdiv(ref = emptyEl,
            `data-export-empty` = "true",
            padding = "8px 0",
            font_size = "11px",
            color = textMuted):
        text "No export targets. Press + to add one."
      tdiv(ref = addBtnEl,
            role = "button", tabindex = "0",
            `data-export-add` = "true",
            `aria-label` = "Add export target",
            display = "flex", align_items = "center",
            justify_content = "center",
            height = "26px",
            border = "1px dashed " & border,
            border_radius = "4px",
            color = textMuted, font_size = "11px",
            cursor = "pointer"):
        text "+ Add export"
  r.appendChild(parent, body)

  proc mountRow(idx: int; entry: ExportEntry) =
    ## Isolating helper — each row's click closures capture ``idx``
    ## from this proc's scope rather than the for-loop body, sidestep-
    ## ping Nim's shared-let-binding semantics inside ``for`` blocks.
    var sizeBtnEl: E
    var formatBtnEl: E
    var suffixInputEl: E
    var deleteBtnEl: E
    let row = ui(r):
      tdiv(`data-export-row` = $idx,
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            padding = "4px 6px",
            border = "1px solid " & border, border_radius = "4px"):
        tdiv(ref = sizeBtnEl,
              role = "button", tabindex = "0",
              `data-export-row-size` = $idx,
              `aria-label` = "Cycle export size",
              display = "flex", align_items = "center",
              justify_content = "center",
              min_width = "32px", height = "22px",
              background_color = bgInput,
              border_radius = "3px",
              color = textSecondary, font_size = "11px",
              cursor = "pointer"):
          text sizeLabel(entry.size)
        tdiv(ref = formatBtnEl,
              role = "button", tabindex = "0",
              `data-export-row-format` = $idx,
              `aria-label` = "Cycle export format",
              display = "flex", align_items = "center",
              justify_content = "center",
              min_width = "44px", height = "22px",
              background_color = bgInput,
              border_radius = "3px",
              color = textSecondary, font_size = "11px",
              cursor = "pointer"):
          text formatLabel(entry.format)
        input(ref = suffixInputEl,
               `data-export-row-suffix` = $idx,
               `aria-label` = "Export suffix",
               flex = "1", min_width = "0",
               background_color = bgInput,
               border = "1px solid " & border,
               border_radius = "3px",
               color = textPrimary, font_size = "11px",
               padding = "2px 6px", height = "22px")
        tdiv(ref = deleteBtnEl,
              role = "button", tabindex = "0",
              `data-export-row-delete` = $idx,
              `aria-label` = "Remove export target",
              width = "20px", height = "20px",
              display = "flex", align_items = "center",
              justify_content = "center",
              color = textMuted, font_size = "11px",
              cursor = "pointer"):
          text "\xC3\x97"
    r.appendChild(listEl, row)
    r.setInputValue(suffixInputEl, entry.suffix)
    r.addEventListener(sizeBtnEl, "click", proc() =
      var next = entries.val
      if idx >= 0 and idx < next.len:
        next[idx].size =
          case next[idx].size
          of es1x: es2x
          of es2x: es3x
          of es3x: es1x
        entries.val = next)
    r.addEventListener(formatBtnEl, "click", proc() =
      var next = entries.val
      if idx >= 0 and idx < next.len:
        next[idx].format =
          case next[idx].format
          of efPng: efSvg
          of efSvg: efPdf
          of efPdf: efPng
        entries.val = next)
    r.addEventListener(suffixInputEl, "change", proc() =
      var next = entries.val
      if idx >= 0 and idx < next.len:
        next[idx].suffix = r.inputValue(suffixInputEl)
        entries.val = next)
    r.addEventListener(deleteBtnEl, "click", proc() =
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
    next.add ExportEntry(size: es1x, format: efPng, suffix: "")
    entries.val = next
  r.addEventListener(addBtnEl, "click", onAdd)
  r.addEventListener(addBtnEl, "keydown", onAdd)
