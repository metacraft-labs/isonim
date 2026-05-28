## Phase G — Source section body widget.
##
## Section catalogue (spec § "Section catalogue"):
##
##   * File path + line — "src/path.nim:42".
##   * Source scope (Local / Shared / Component schema / Theme token).
##   * Staged commit count (number of pending source edits).
##   * Ownership warnings — surface ``inspector.conflicts`` summary.

import std/[options, strutils]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  warn = "#F59E0B"
  border = "#2A2C3A"

proc deriveScopeLabel(element: ElementRef): string =
  ## Derive a coarse scope label from the selection. The full schema-
  ## aware derivation lives in the source-edit pipeline; for the
  ## section body we mirror the four labels the spec calls out.
  for prop in element.properties:
    if prop.tokenName.len > 0:
      return "Theme token"
    if prop.schemaKey.len > 0:
      return "Component schema"
    if prop.sharedCount > 0:
      return "Shared"
  "Local"

proc mountSectionSource*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the Source section body. The section is read-only for
  ## Phase G — it surfaces the four metadata rows the spec calls out
  ## (file:line, scope, staged commits, ownership warnings).
  var fileLineEl: E
  var scopeEl: E
  var stagedEl: E
  var ownershipEl: E

  let body = ui(r):
    tdiv(`data-source-section-body` = "true",
         display = "flex", flex_direction = "column",
         gap = "8px", padding = "4px 0"):
      # File path + line row.
      tdiv(`data-source-row` = "file",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "File"
        span(ref = fileLineEl,
              `data-source-file-line` = "true",
              color = textPrimary,
              font_family = "monospace",
              overflow = "hidden",
              text_overflow = "ellipsis",
              white_space = "nowrap",
              flex = "1"):
          text "—"
      # Scope row.
      tdiv(`data-source-row` = "scope",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "Scope"
        span(ref = scopeEl,
              `data-source-scope` = "true",
              color = textSecondary):
          text "Local"
      # Staged commits row.
      tdiv(`data-source-row` = "staged",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "6px",
            font_size = "11px"):
        span(color = textMuted, min_width = "60px"): text "Staged"
        span(ref = stagedEl,
              `data-source-staged-count` = "true",
              color = textSecondary):
          text "0"
      # Ownership warnings row — kept always-present so the data
      # attribute is queryable by tests even when empty.
      tdiv(`data-source-row` = "ownership",
            display = "flex", flex_direction = "column", gap = "4px",
            border = "1px solid " & border, border_radius = "4px",
            padding = "6px 8px", background_color = "#0F172A",
            font_size = "11px"):
        span(color = textDim, font_size = "10px",
              text_transform = "uppercase", letter_spacing = "0.4px"):
          text "Ownership"
        span(ref = ownershipEl,
              `data-source-ownership` = "true",
              color = textSecondary):
          text "No conflicts"
  r.appendChild(parent, body)

  createRenderEffect proc() =
    let el = vm.inspector.selectedElement.val
    if vm.inspector.hasElement.val:
      let label =
        if el.sourceFile.len > 0 and el.sourceLine > 0:
          el.sourceFile & ":" & $el.sourceLine
        elif el.sourceFile.len > 0: el.sourceFile
        else: "—"
      r.setTextContent(fileLineEl, label)
      r.setTextContent(scopeEl, deriveScopeLabel(el))
    else:
      r.setTextContent(fileLineEl, "—")
      r.setTextContent(scopeEl, "—")

  createRenderEffect proc() =
    let staged = vm.inspector.pendingSourceEdits.val.len
    r.setTextContent(stagedEl, $staged)

  createRenderEffect proc() =
    let conflicts = vm.inspector.conflicts.val
    if conflicts.len == 0:
      r.setTextContent(ownershipEl, "No conflicts")
      r.setAttribute(ownershipEl, "data-source-ownership-warning", "false")
      r.setStyle(ownershipEl, "color", textSecondary)
    else:
      r.setTextContent(ownershipEl,
        $conflicts.len & " conflict(s)")
      r.setAttribute(ownershipEl, "data-source-ownership-warning", "true")
      r.setStyle(ownershipEl, "color", warn)
