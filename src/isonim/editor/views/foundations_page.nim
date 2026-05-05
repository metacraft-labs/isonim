## Dedicated foundations-page editor.

import std/[sequtils, strutils]

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgCard = "#151D2E"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  danger = "#F87171"
  success = "#22C55E"

proc categoryButtonHandler[R, E](r: R; node: E; vm: EditorVM;
    kind: FoundationTokenKind): proc() =
  let captured = kind
  let capturedNode = node
  result = proc() =
    discard vm.setFoundationCategory(captured)
    r.setAttribute(capturedNode, "aria-pressed", "true")
    r.setStyle(capturedNode, "background-color", accent)
    r.setStyle(capturedNode, "color", textPrimary)
    when defined(js):
      let current = capturedNode
      {.emit: ["""
        const active = """, current, """;
        active.parentElement?.querySelectorAll('[data-foundation-category]').forEach((node) => {
          if (node === active) return;
          node.setAttribute('aria-pressed', 'false');
          node.style.backgroundColor = '""", bgSurface, """';
          node.style.color = '""", textSecondary, """';
        });
      """].}

proc tokenButtonHandler(vm: EditorVM; key: string): proc() =
  let captured = key
  result = proc() = discard vm.selectFoundationToken(captured)

proc editTokenHandler[R, E](r: R; vm: EditorVM; input: E): proc() =
  let capturedInput = input
  result = proc() =
    let token = vm.foundations.selectedToken.val
    if token.key.len > 0:
      discard vm.editFoundationToken(token.key, r.inputValue(capturedInput))

proc revertHandler(vm: EditorVM): proc() =
  result = proc() = discard vm.runEditorCommand(eckRevert)

proc saveHandler(vm: EditorVM): proc() =
  result = proc() = discard vm.runEditorCommand(eckSave)

proc undoHandler(vm: EditorVM): proc() =
  result = proc() = discard vm.undoFoundationTokenEdit()

proc searchHandler[R, E](r: R; vm: EditorVM; input: E): proc() =
  let captured = input
  result = proc() = vm.setFoundationSearch(r.inputValue(captured))

proc tokenPreviewStyle(token: FoundationTokenEntry): string =
  let value = token.value
  case token.kind
  of ftkColorPalette, ftkSemanticColor, ftkAccessibilityConstraint:
    if value.startsWith("#"):
      "background:" & value & ";"
    else:
      "background:#CBD5E1;"
  of ftkTypographyScale:
    "font-size:" & value & ";"
  of ftkSpacingScale:
    "width:" & value & ";height:" & value & ";background:#3B82F6;"
  of ftkRadiusScale:
    "border-radius:" & value & ";background:#3B82F6;"
  of ftkShadow:
    "box-shadow:" & value & ";background:white;"
  of ftkMotion:
    "transition-duration:" & value & ";"
  of ftkBreakpoint:
    "width:min(" & value & ",100%);"
  of ftkDensity:
    "padding:" & value & ";"

proc renderFoundationsPage*[R, E](r: R; vm: EditorVM): E =
  let page = ui(r):
    tdiv(class = "editor-preview",
          `data-foundations-page` = "true",
          display = "flex", flex_direction = "column",
          flex = "1", min_width = "0", height = "100%",
          background_color = bgBase, color = textPrimary)

  var headerStatus: E
  let header = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          height = "44px", min_height = "44px", padding = "0 20px",
          background_color = bgCard,
          border_bottom = "1px solid " & border):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(font_size = "11px", color = textDim):
          text "Foundations"
        span(font_size = "11px", color = textDim):
          text ">"
        span(font_size = "13px", font_weight = "600", color = textPrimary):
          text "Token browser"
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        span(ref = headerStatus, font_size = "11px", color = textMuted):
          text "Clean"
  r.appendChild(page, header)

  let body = ui(r):
    tdiv(display = "grid",
          grid_template_columns = "220px minmax(260px, 1fr) 320px",
          gap = "0", flex = "1", min_height = "0")
  r.appendChild(page, body)

  let categories = ui(r):
    aside(display = "flex", flex_direction = "column", gap = "10px",
          padding = "16px", border_right = "1px solid " & border,
          overflow_y = "auto"):
      span(font_size = "10px", font_weight = "700",
            color = textDim, text_transform = "uppercase"):
        text "Categories"
  r.appendChild(body, categories)

  for kind in allFoundationTokenKinds():
    let capturedKind = kind
    let label = foundationTokenKindLabel(capturedKind)
    let slug = foundationTokenKindSlug(capturedKind)
    let count = vm.foundations.tokens.val.filterIt(it.kind == capturedKind).len
    var button: E
    let row = ui(r):
      tdiv(ref = button, role = "button", tabindex = "0",
            `aria-label` = "Select foundation category " & label,
            `data-foundation-category` = slug,
            display = "flex", align_items = "center",
            justify_content = "space-between",
            padding = "8px 10px", border_radius = "6px",
            cursor = "pointer", font_size = "12px"):
        span:
          text label
        span(font_size = "10px", color = textDim):
            text $count
    let chooseCategory = categoryButtonHandler[R, E](r, button, vm, capturedKind)
    r.addEventListener(button, "click", chooseCategory)
    r.addEventListener(button, "keydown", chooseCategory)
    let active = vm.foundations.selectedCategory.val == capturedKind
    r.setStyle(button, "background-color", if active: accent else: bgSurface)
    r.setStyle(button, "color", if active: textPrimary else: textSecondary)
    r.setAttribute(button, "aria-pressed", if active: "true" else: "false")
    r.appendChild(categories, row)

  var searchInput: E
  var tokenList: E
  let tokenPane = ui(r):
    section(display = "flex", flex_direction = "column",
            min_width = "0", min_height = "0"):
      tdiv(display = "flex", align_items = "center", gap = "10px",
            padding = "14px 16px", border_bottom = "1px solid " & border):
        input(ref = searchInput, class = "editor-input",
              `aria-label` = "Search foundation tokens",
              placeholder = "Search tokens",
              width = "100%", padding = "8px 10px",
              border = "1px solid " & border,
              border_radius = "6px", background_color = bgSurface,
              color = textPrimary)
      tdiv(ref = tokenList,
            `data-foundation-token-list` = "true",
            display = "flex", flex_direction = "column",
            gap = "8px", padding = "16px",
            overflow_y = "auto")
  r.addEventListener(searchInput, "input", searchHandler[R, E](r, vm, searchInput))
  r.appendChild(body, tokenPane)

  var previewName: E
  var previewValue: E
  var previewBox: E
  var valueInput: E
  var diagnosticsNode: E
  var impactNode: E
  var sourceNode: E
  var saveButton: E
  var revertButton: E
  var undoButton: E
  var applyButton: E
  let detail = ui(r):
    aside(display = "flex", flex_direction = "column",
          min_width = "0", min_height = "0",
          padding = "16px", gap = "14px",
          border_left = "1px solid " & border,
          overflow_y = "auto"):
      tdiv(display = "flex", flex_direction = "column", gap = "4px"):
        span(ref = previewName, font_size = "13px",
              font_weight = "700", color = textPrimary):
          text "No token selected"
        span(ref = previewValue, font_size = "11px",
              color = textMuted, font_family = "monospace"):
          text ""
      tdiv(ref = previewBox,
            `data-foundation-preview` = "true",
            min_height = "120px", display = "flex",
            align_items = "center", justify_content = "center",
            border = "1px solid " & border,
            border_radius = "8px",
            background_color = bgSurface,
            overflow = "hidden"):
        span(font_size = "20px", font_weight = "700",
              color = textPrimary):
          text "Aa"
      tdiv(display = "flex", flex_direction = "column", gap = "8px"):
        label(font_size = "11px", font_weight = "700", color = textSecondary):
          text "Value"
        input(ref = valueInput, class = "editor-input",
              `aria-label` = "Foundation token value",
              padding = "9px 10px",
              border = "1px solid " & border,
              border_radius = "6px", background_color = bgSurface,
              color = textPrimary,
              font_family = "monospace")
      tdiv(display = "grid", grid_template_columns = "1fr 1fr",
            gap = "8px"):
        tdiv(ref = applyButton, role = "button", tabindex = "0",
              `aria-label` = "Apply foundation token value",
              padding = "8px 10px", border_radius = "6px",
              background_color = accent, color = textPrimary,
              text_align = "center", cursor = "pointer",
              font_size = "12px", font_weight = "700"):
          text "Apply"
        tdiv(ref = undoButton, role = "button", tabindex = "0",
              `aria-label` = "Undo foundation token edit",
              padding = "8px 10px", border_radius = "6px",
              background_color = bgSurface, color = textSecondary,
              text_align = "center", cursor = "pointer",
              font_size = "12px", font_weight = "700"):
          text "Undo"
        tdiv(ref = saveButton, role = "button", tabindex = "0",
              `aria-label` = "Save foundation source edits",
              padding = "8px 10px", border_radius = "6px",
              background_color = success, color = "#052E16",
              text_align = "center", cursor = "pointer",
              font_size = "12px", font_weight = "700"):
          text "Save"
        tdiv(ref = revertButton, role = "button", tabindex = "0",
              `aria-label` = "Revert foundation source edits",
              padding = "8px 10px", border_radius = "6px",
              background_color = bgSurface, color = textSecondary,
              text_align = "center", cursor = "pointer",
              font_size = "12px", font_weight = "700"):
          text "Revert"
      tdiv(ref = diagnosticsNode,
            `data-foundation-diagnostics` = "true",
            display = "flex", flex_direction = "column", gap = "6px",
            padding = "10px", border = "1px solid " & border,
            border_radius = "6px", color = textSecondary,
            font_size = "11px"):
        text "No diagnostics"
      tdiv(ref = impactNode,
            `data-foundation-impact` = "true",
            padding = "10px", border = "1px solid " & border,
            border_radius = "6px", color = textSecondary,
            font_size = "11px"):
        text "No impact analysis yet"
      tdiv(ref = sourceNode,
            `data-foundation-source` = "true",
            padding = "10px", border = "1px solid " & border,
            border_radius = "6px", color = textMuted,
            font_size = "11px", font_family = "monospace",
            overflow_wrap = "anywhere"):
        text ""
  r.addEventListener(applyButton, "click", editTokenHandler[R, E](r, vm, valueInput))
  r.addEventListener(applyButton, "keydown", editTokenHandler[R, E](r, vm,
    valueInput))
  r.addEventListener(saveButton, "click", saveHandler(vm))
  r.addEventListener(saveButton, "keydown", saveHandler(vm))
  r.addEventListener(revertButton, "click", revertHandler(vm))
  r.addEventListener(revertButton, "keydown", revertHandler(vm))
  r.addEventListener(undoButton, "click", undoHandler(vm))
  r.addEventListener(undoButton, "keydown", undoHandler(vm))
  r.appendChild(body, detail)

  createRenderEffect proc() =
    r.setTextContent(headerStatus,
      (if vm.foundations.isDirty.val: "Unsaved token edit" else: "Clean") &
      " - source " & (if vm.sourceAdapterReady.val: "ready" else: "missing"))
    r.setInputValue(searchInput, vm.foundations.searchFilter.val)
    r.setTextContent(tokenList, "")
    for token in vm.foundations.filteredTokens.val:
      let key = token.key
      let value = token.value
      let previewStyle = tokenPreviewStyle(token)
      let chooseToken = tokenButtonHandler(vm, key)
      var button: E
      let node = ui(r):
        tdiv(ref = button, role = "button", tabindex = "0",
              `aria-label` = "Select foundation token " & key,
              `data-foundation-token` = key,
              display = "grid",
              grid_template_columns = "32px minmax(0, 1fr)",
              gap = "10px", align_items = "center",
              padding = "10px", border = "1px solid " & border,
              border_radius = "8px", background_color = bgCard,
              cursor = "pointer"):
          span(width = "28px", height = "28px",
                border = "1px solid " & border,
                border_radius = "6px",
                style = previewStyle)
          tdiv(display = "flex", flex_direction = "column", gap = "3px",
                min_width = "0"):
            span(font_size = "12px", font_weight = "700",
                  color = textPrimary,
                  overflow = "hidden", text_overflow = "ellipsis",
                  white_space = "nowrap"):
              text key
            span(font_size = "11px", color = textMuted,
                  font_family = "monospace",
                  overflow = "hidden", text_overflow = "ellipsis",
                  white_space = "nowrap"):
              text value
      r.addEventListener(button, "click", chooseToken)
      r.addEventListener(button, "keydown", chooseToken)
      let selected = key.toLowerAscii() ==
        vm.foundations.selectedTokenKey.val.toLowerAscii()
      r.setAttribute(button, "aria-selected", if selected: "true" else: "false")
      r.setStyle(button, "border-color", if selected: accent else: border)
      r.appendChild(tokenList, node)

    let token = vm.foundations.selectedToken.val
    r.setTextContent(previewName,
      if token.key.len > 0: token.key else: "No token selected")
    r.setTextContent(previewValue, token.value)
    r.setInputValue(valueInput, token.value)
    r.setAttribute(previewBox, "style",
      "min-height:120px;display:flex;align-items:center;justify-content:center;border:1px solid " &
      border & ";border-radius:8px;background-color:" & bgSurface &
      ";overflow:hidden;" & tokenPreviewStyle(token))
    r.setTextContent(sourceNode,
      if token.key.len > 0:
        token.sourceFile & ":" & $token.sourceLine & " " & token.schemaKey
      else:
        "")
    if vm.foundations.diagnostics.val.len == 0:
      r.setTextContent(diagnosticsNode, "No diagnostics")
      r.setStyle(diagnosticsNode, "color", textSecondary)
      r.setStyle(diagnosticsNode, "border-color", border)
    else:
      r.setTextContent(diagnosticsNode,
        vm.foundations.diagnostics.val.mapIt(it.message).join(" "))
      r.setStyle(diagnosticsNode, "color", danger)
      r.setStyle(diagnosticsNode, "border-color", danger)
    if vm.foundations.impacts.val.len > 0:
      r.setTextContent(impactNode, vm.foundations.impacts.val[0].message)
    else:
      r.setTextContent(impactNode, "No impact analysis yet")

    let save = vm.evaluateCommand(eckSave)
    let revert = vm.evaluateCommand(eckRevert)
    r.setAttribute(saveButton, "aria-disabled",
      if save.status == ecsDisabled: "true" else: "false")
    r.setAttribute(revertButton, "aria-disabled",
      if revert.status == ecsDisabled: "true" else: "false")
    r.setAttribute(undoButton, "aria-disabled",
      if vm.foundations.undoStack.val.len == 0: "true" else: "false")
    r.setStyle(saveButton, "opacity", if save.status == ecsDisabled: "0.5" else: "1")
    r.setStyle(revertButton, "opacity",
      if revert.status == ecsDisabled: "0.5" else: "1")
    r.setStyle(undoButton, "opacity",
      if vm.foundations.undoStack.val.len == 0: "0.5" else: "1")

  page
