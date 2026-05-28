## Phase E.4 — Inline variable editor + propagation pipeline.
##
## A small floating panel that lets the user edit a foundation
## variable directly from the inspector sidebar without trampolining
## through the foundations page.
##
## Spec reference: ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md``
## § "In-sidebar variable editing — IsoNim's 'go beyond Figma'".
##
## Entry points (per spec):
##
##   1. The variable chip (E.2) name click — opens the editor anchored
##      to the chip.
##   2. The variable picker (E.3) per-row "Edit this variable"
##      affordance — opens the editor anchored to the picker row; the
##      picker stays open behind so the user sees the propagation hit
##      live.
##
## Propagation contract:
##
##   The editor writes through ``editFoundationToken`` (existing E.1
##   primitive on ``EditorVM``). That proc mutates
##   ``vm.foundations.tokens.val``, which is the single reactive
##   source consumed by ``resolveVariableValue``. Every component
##   that reads ``resolveVariableValue(variableKey)`` is therefore
##   re-evaluated on the next reactive pass — instant propagation,
##   no extra plumbing required.
##
## Source write-back (the spec's "binding is persisted to source"
## clause) is owned by the foundations editor's existing source-edit
## pipeline; the inline editor records the intent through
## ``editFoundationToken``, which already journals a SourceEditPlan
## via ``inspector.journalSourceEdit``. Phase G is the eventual
## hand-off to the actual file mutation.
##
## Visual contract:
##
##   * Width 320 px (matches the chip + picker), padding 12 px.
##   * Heading "Edit color/surface (used in 23 places)" — the count is
##     pulled live from ``usageCountFor``.
##   * Warning chip when usage > 50: "This affects N components across
##     M pages — undo is available (Cmd+Z)".
##   * Name input — writable; ``editFoundationToken`` does not support
##     renames yet, so the field is rendered read-only with a hint
##     "(rename in foundations editor)". A future Phase G hook can
##     swap the input for a writable one once the source-edit
##     pipeline supports key renames.
##   * Value input + small "picker" affordance (no-op marker for E.4 —
##     wires to the color picker in Phase G).
##   * "Apply across all modes" checkbox (recorded as a flag on save).
##   * Cancel + Save buttons.
##
## Data attributes:
##
##   * ``data-variable-inline-editor="true"`` on the root.
##   * ``data-variable-inline-editor-open="true|false"`` on the root.
##   * ``data-variable-inline-editor-heading="true"`` on the heading.
##   * ``data-variable-inline-editor-warning="true"`` on the warning row.
##   * ``data-variable-inline-editor-name="true"`` on the name input.
##   * ``data-variable-inline-editor-value="true"`` on the value input.
##   * ``data-variable-inline-editor-apply-all="true|false"`` on the
##     "apply across all modes" checkbox.
##   * ``data-variable-inline-editor-save="true"`` on the Save button.
##   * ``data-variable-inline-editor-cancel="true"`` on the Cancel
##     button.
##   * ``data-variable-inline-editor-diagnostic="true"`` on the
##     diagnostic row (visible only when the last save was rejected).

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

# --------------------------------------------------------------------------- #
#  Public types.
# --------------------------------------------------------------------------- #

type
  VariableInlineEditorState* = ref object
    ## Reactive state for the inline variable editor. A single instance
    ## is mounted at the shell root + reused; the chip and the picker
    ## both open the editor by writing through ``openInlineEditor``.
    open*: Signal[bool]
    anchorRect*: Signal[tuple[x, y, w, h: float]]
    targetVariableKey*: Signal[string]
    draftName*: Signal[string]
    draftValue*: Signal[string]
    applyAllModes*: Signal[bool]
    diagnostic*: Signal[string]
      ## Non-empty when the last Save attempt was rejected; the row
      ## becomes visible and renders the reason.

# --------------------------------------------------------------------------- #
#  Visual contract.
# --------------------------------------------------------------------------- #

const
  vieWidth         = "320px"
  vieZIndex        = "1200"
  vieBg            = "#16171F"
  vieBorder        = "1px solid #2D2D3A"
  vieRadius        = "8px"
  vieShadow        = "0 24px 80px rgba(0, 0, 0, 0.42)"
  viePadding       = "12px"
  vieGap           = "10px"

  vieTextPrimary   = "#F1F5F9"
  vieTextMuted     = "#A0A2B0"
  vieTextDim       = "#6B6F80"
  vieAccent        = "#7C7AED"
  vieWarning       = "#F59E0B"
  vieError         = "#F87171"

  vieInputBg       = "#0F0F18"
  vieInputBorder   = "1px solid #2F3140"
  vieInputRadius   = "4px"
  vieInputPadding  = "6px 8px"
  vieInputFont     = "12px"
  vieInputFamily   = "ui-monospace, 'SFMono-Regular', Menlo, " &
                     "Consolas, monospace"

  vieBtnRadius     = "4px"
  vieBtnPadding    = "5px 12px"
  vieBtnFont       = "12px"

  vieWarningBg     = "rgba(245, 158, 11, 0.12)"
  vieWarningBorder = "1px solid rgba(245, 158, 11, 0.40)"

  vieErrorBg       = "rgba(248, 113, 113, 0.10)"
  vieErrorBorder   = "1px solid rgba(248, 113, 113, 0.40)"

  vieHighUsageThreshold = 50

# --------------------------------------------------------------------------- #
#  Constructors + state helpers.
# --------------------------------------------------------------------------- #

proc createVariableInlineEditorState*(): VariableInlineEditorState =
  VariableInlineEditorState(
    open: createSignal(false),
    anchorRect: createSignal((0.0, 0.0, 0.0, 0.0)),
    targetVariableKey: createSignal(""),
    draftName: createSignal(""),
    draftValue: createSignal(""),
    applyAllModes: createSignal(false),
    diagnostic: createSignal(""))

proc closeVariableInlineEditor*(state: VariableInlineEditorState) =
  if state.open.val:
    state.open.val = false

proc openVariableInlineEditorWithRect*(vm: EditorVM;
                                        state: VariableInlineEditorState;
                                        variableKey: string;
                                        x, y, w, h: float) =
  ## Renderer-neutral helper — set the anchor + initialise the draft
  ## from the current token, then flip the state open. Used by the
  ## headless tests and the JS-side ``openVariableInlineEditor``
  ## wrapper below.
  if variableKey.len == 0:
    return
  state.targetVariableKey.val = variableKey
  state.draftName.val = variableKey
  state.draftValue.val = vm.resolveVariableValue(variableKey)
  state.applyAllModes.val = true
  state.diagnostic.val = ""
  state.anchorRect.val = (x, y, w, h)
  state.open.val = true

proc commitInlineEdit*(vm: EditorVM;
                        state: VariableInlineEditorState): FoundationEditResult =
  ## Apply the current draft through ``editFoundationToken``. On
  ## acceptance the editor closes and the foundations.tokens signal
  ## update propagates to every consumer of ``resolveVariableValue``.
  ## On rejection the diagnostic row surfaces the first message and
  ## the editor stays open so the user can edit + retry.
  let key = state.targetVariableKey.val
  if key.len == 0:
    state.diagnostic.val = "No variable selected"
    return FoundationEditResult(status: pesRejected)
  let editResult = vm.editFoundationToken(key, state.draftValue.val)
  if editResult.status == pesAccepted:
    state.diagnostic.val = ""
    state.open.val = false
  else:
    if editResult.diagnostics.len > 0:
      state.diagnostic.val = editResult.diagnostics[0].message
    else:
      state.diagnostic.val = "Edit rejected"
  editResult

# --------------------------------------------------------------------------- #
#  Mount.
# --------------------------------------------------------------------------- #

proc mountVariableInlineEditor*[R, E](r: R; parent: E; vm: EditorVM;
                                        state: VariableInlineEditorState): E =
  ## Mount the inline editor under ``parent`` (typically the shell
  ## root). Returns the editor's root element.
  let capturedVm = vm
  let capturedState = state

  var rootNode: E
  var headingNode: E
  var warningNode: E
  var diagnosticNode: E
  var nameInput: E
  var valueInput: E
  var applyAllCheckbox: E
  var saveBtn: E
  var cancelBtn: E
  var pickerBtn: E

  let root = ui(r):
    tdiv(
      ref = rootNode,
      `data-variable-inline-editor` = "true",
      `data-variable-inline-editor-open` = "false",
      role = "dialog",
      `aria-modal` = "false",
      `aria-label` = "Edit variable",
      position = "absolute",
      display = "none",
      flex_direction = "column",
      gap = vieGap,
      width = vieWidth,
      padding = viePadding,
      background_color = vieBg,
      border = vieBorder,
      border_radius = vieRadius,
      box_shadow = vieShadow,
      color = vieTextPrimary,
      z_index = vieZIndex):
      # Heading — "Edit color/surface (used in 23 places)".
      tdiv(
        ref = headingNode,
        `data-variable-inline-editor-heading` = "true",
        font_size = "12px",
        font_weight = "600",
        color = vieTextPrimary):
        text "Edit variable"
      # High-usage warning row — visible only when usage > threshold.
      tdiv(
        ref = warningNode,
        `data-variable-inline-editor-warning` = "true",
        display = "none",
        padding = "6px 8px",
        background_color = vieWarningBg,
        border = vieWarningBorder,
        border_radius = vieInputRadius,
        color = vieWarning,
        font_size = "11px",
        line_height = "1.4"):
        text ""
      # Name row.
      tdiv(display = "flex", flex_direction = "column", gap = "4px"):
        span(font_size = "10px", color = vieTextMuted,
             text_transform = "uppercase", letter_spacing = "0.04em"):
          text "Name"
        input(
          ref = nameInput,
          `data-variable-inline-editor-name` = "true",
          `aria-label` = "Variable name",
          padding = vieInputPadding,
          background_color = vieInputBg,
          border = vieInputBorder,
          border_radius = vieInputRadius,
          color = vieTextPrimary,
          font_size = vieInputFont,
          font_family = vieInputFamily,
          outline = "none")
        span(font_size = "10px", color = vieTextDim):
          text "(rename in foundations editor)"
      # Value row — value input + tiny picker affordance.
      tdiv(display = "flex", flex_direction = "column", gap = "4px"):
        span(font_size = "10px", color = vieTextMuted,
             text_transform = "uppercase", letter_spacing = "0.04em"):
          text "Value"
        tdiv(display = "flex", gap = "6px", align_items = "center"):
          input(
            ref = valueInput,
            `data-variable-inline-editor-value` = "true",
            `aria-label` = "Variable value",
            flex = "1",
            min_width = "0",
            padding = vieInputPadding,
            background_color = vieInputBg,
            border = vieInputBorder,
            border_radius = vieInputRadius,
            color = vieTextPrimary,
            font_size = vieInputFont,
            font_family = vieInputFamily,
            outline = "none")
          tdiv(
            ref = pickerBtn,
            `data-variable-inline-editor-picker` = "true",
            role = "button",
            tabindex = "0",
            `aria-label` = "Open value picker",
            title = "Pick value",
            flex_shrink = "0",
            display = "flex",
            align_items = "center",
            justify_content = "center",
            width = "24px",
            height = "26px",
            background_color = vieInputBg,
            border = vieInputBorder,
            border_radius = vieInputRadius,
            color = vieTextMuted,
            font_size = "12px",
            cursor = "pointer",
            user_select = "none"):
            # U+1F3A8 ARTIST PALETTE — picker affordance.
            text "\xF0\x9F\x8E\xA8"
      # Apply-all-modes row.
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        input(
          ref = applyAllCheckbox,
          `data-variable-inline-editor-apply-all` = "true",
          `aria-label` = "Apply across all modes",
          width = "16px",
          height = "16px",
          margin = "0",
          cursor = "pointer")
        span(font_size = "11px", color = vieTextMuted):
          text "Apply across all modes"
      # Diagnostic row — visible only when the last save was rejected.
      tdiv(
        ref = diagnosticNode,
        `data-variable-inline-editor-diagnostic` = "true",
        display = "none",
        padding = "6px 8px",
        background_color = vieErrorBg,
        border = vieErrorBorder,
        border_radius = vieInputRadius,
        color = vieError,
        font_size = "11px"):
        text ""
      # Buttons row.
      tdiv(display = "flex", justify_content = "flex-end", gap = "8px"):
        tdiv(
          ref = cancelBtn,
          `data-variable-inline-editor-cancel` = "true",
          role = "button",
          tabindex = "0",
          padding = vieBtnPadding,
          background_color = "transparent",
          border = "1px solid #2F3140",
          border_radius = vieBtnRadius,
          color = vieTextPrimary,
          font_size = vieBtnFont,
          cursor = "pointer",
          user_select = "none"):
          text "Cancel"
        tdiv(
          ref = saveBtn,
          `data-variable-inline-editor-save` = "true",
          role = "button",
          tabindex = "0",
          padding = vieBtnPadding,
          background_color = vieAccent,
          border = "1px solid " & vieAccent,
          border_radius = vieBtnRadius,
          color = "#FFFFFF",
          font_size = vieBtnFont,
          font_weight = "600",
          cursor = "pointer",
          user_select = "none"):
          text "Save"

  # ------------------------------------------------------------------------- #
  # Visibility + positioning.
  # ------------------------------------------------------------------------- #
  createRenderEffect proc() =
    let open = capturedState.open.val
    let rect = capturedState.anchorRect.val
    r.setAttribute(rootNode, "data-variable-inline-editor-open",
      if open: "true" else: "false")
    r.setStyle(rootNode, "display",
      if open: "flex" else: "none")
    if not open:
      return
    when defined(js):
      let topPx = rect.y + rect.h + 6.0
      let leftPx = rect.x
      r.setStyle(rootNode, "top", $topPx & "px")
      r.setStyle(rootNode, "left", $leftPx & "px")
    else:
      r.setAttribute(rootNode, "data-variable-inline-editor-anchor-x",
        $rect.x)
      r.setAttribute(rootNode, "data-variable-inline-editor-anchor-y",
        $rect.y)

  # Heading reflects the target variable key + usage count.
  createRenderEffect proc() =
    let key = capturedState.targetVariableKey.val
    let usage = capturedVm.usageCountFor(key)
    if key.len == 0:
      r.setTextContent(headingNode, "Edit variable")
    else:
      r.setTextContent(headingNode,
        "Edit " & key & " (used in " & $usage & " places)")

  # High-usage warning visibility + message.
  createRenderEffect proc() =
    let key = capturedState.targetVariableKey.val
    let usage = capturedVm.usageCountFor(key)
    if usage > vieHighUsageThreshold:
      r.setStyle(warningNode, "display", "block")
      r.setTextContent(warningNode,
        "This affects " & $usage & " components — undo is available (Cmd+Z)")
    else:
      r.setStyle(warningNode, "display", "none")
      r.setTextContent(warningNode, "")

  # Diagnostic visibility.
  createRenderEffect proc() =
    let diag = capturedState.diagnostic.val
    if diag.len > 0:
      r.setStyle(diagnosticNode, "display", "block")
      r.setTextContent(diagnosticNode, diag)
    else:
      r.setStyle(diagnosticNode, "display", "none")
      r.setTextContent(diagnosticNode, "")

  # Name input mirror — read-only at the source level for now; we
  # still surface the draft so the field tracks open events.
  createRenderEffect proc() =
    let name = capturedState.draftName.val
    if r.inputValue(nameInput) != name:
      r.setInputValue(nameInput, name)

  # Value input mirror.
  createRenderEffect proc() =
    let value = capturedState.draftValue.val
    if r.inputValue(valueInput) != value:
      r.setInputValue(valueInput, value)

  # Apply-all-modes checkbox mirror.
  r.setAttribute(applyAllCheckbox, "type", "checkbox")
  createRenderEffect proc() =
    let v = capturedState.applyAllModes.val
    r.setAttribute(applyAllCheckbox, "checked",
      if v: "true" else: "false")

  # Wire input listeners — user edits flow back into draft signals.
  let onValueInput = proc() =
    capturedState.draftValue.val = r.inputValue(valueInput)
  r.addEventListener(valueInput, "input", onValueInput)
  r.addEventListener(valueInput, "change", onValueInput)

  let onApplyAllToggle = proc() =
    capturedState.applyAllModes.val = not capturedState.applyAllModes.val
  r.addEventListener(applyAllCheckbox, "click", onApplyAllToggle)
  r.addEventListener(applyAllCheckbox, "change", onApplyAllToggle)

  # Cancel button.
  let onCancel = proc() =
    capturedState.diagnostic.val = ""
    capturedState.closeVariableInlineEditor()
  r.addEventListener(cancelBtn, "click", onCancel)
  r.addEventListener(cancelBtn, "keydown", onCancel)

  # Save button.
  let onSave = proc() =
    discard commitInlineEdit(capturedVm, capturedState)
  r.addEventListener(saveBtn, "click", onSave)
  r.addEventListener(saveBtn, "keydown", onSave)

  # Picker affordance — Phase G hookup; for now a marker attribute so
  # the headless tests can observe the click reached the button.
  let onPicker = proc() =
    r.setAttribute(pickerBtn,
      "data-variable-inline-editor-picker-requested", "true")
  r.addEventListener(pickerBtn, "click", onPicker)
  r.addEventListener(pickerBtn, "keydown", onPicker)

  r.appendChild(parent, root)
  result = root

# --------------------------------------------------------------------------- #
#  JS-side helper: openVariableInlineEditor — compute anchorRect.
# --------------------------------------------------------------------------- #

when defined(js):
  import std/dom

  proc openVariableInlineEditor*(vm: EditorVM;
                                  state: VariableInlineEditorState;
                                  anchorEl: Element;
                                  variableKey: string) =
    ## JS helper that reads ``anchorEl.getBoundingClientRect()`` and
    ## opens the editor. The anchor is typically the chip name span
    ## (entry point #1) or a picker row (entry point #2).
    if anchorEl == nil or variableKey.len == 0:
      return
    var rectX: float = 0.0
    var rectY: float = 0.0
    var rectW: float = 0.0
    var rectH: float = 0.0
    {.emit: ["""
      (function (el) {
        if (!el || !el.getBoundingClientRect) return;
        var rect = el.getBoundingClientRect();
        var sx = window.scrollX || 0;
        var sy = window.scrollY || 0;
        """, rectX, """ = rect.left + sx;
        """, rectY, """ = rect.top + sy;
        """, rectW, """ = rect.width;
        """, rectH, """ = rect.height;
      })(""", anchorEl, """);
    """].}
    openVariableInlineEditorWithRect(vm, state, variableKey,
      rectX, rectY, rectW, rectH)
