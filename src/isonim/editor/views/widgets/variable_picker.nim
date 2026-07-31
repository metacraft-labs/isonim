## Phase E.3 — Design system variable picker popover.
##
## Anchored floating popover that lists every foundation token
## available to the current selection, grouped by category. Opening
## the picker is driven by ``VariablePickerState``; a single instance
## of the popover is mounted at the editor shell root and re-used by
## every property row.
##
## Spec reference: ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md``
## § "Variable picker".
##
## Architecture:
##
##   * The picker's state lives in ``VariablePickerState`` — reactive
##     signals for ``open``, ``anchorRect``, ``searchText``, and
##     ``targetPropertyKey``. The shell owns one instance and hands a
##     reference to every property row via ``onBindRequest``.
##   * ``mountVariablePicker`` mounts the popover under any parent (in
##     practice, the editor shell root) so the absolute-positioned
##     popover layers above the inspector + preview without parent
##     clipping. The mount is renderer-agnostic.
##   * ``openVariablePicker`` is the JS-side helper that computes
##     ``anchorRect`` from a DOM element via ``getBoundingClientRect``
##     and flips the state to open. Native callers can flip ``open``
##     and ``anchorRect`` manually for headless tests.
##
## Visual contract (matches the spec to 1px precision):
##
##   * Width 320 px; max-height 480 px with internal scroll.
##   * Search field at the top: filters by prefix + infix on key.
##   * Category headers (Colour / Spacing / Typography / Radius /
##     Effect / Number / String) collapsible per-category.
##   * Each variable row exposes:
##       - 16x16 swatch (for color tokens) OR value preview chip
##         (everything else).
##       - Variable name in monospace.
##       - Resolved value in muted text.
##       - Usage count badge ``"used 23 ×"``.
##       - "Edit this variable" hover affordance.
##   * Footer reads "Library: Foundations".
##   * ESC + outside click close the popover.
##   * Smart edge-flipping: if the popover would extend past the
##     viewport bottom, anchor to the top of the anchor instead.
##
## Data attributes for tests:
##
##   * ``data-variable-picker="true"`` on the popover root.
##   * ``data-variable-picker-open="true|false"`` on the popover root.
##   * ``data-variable-picker-search="true"`` on the search input.
##   * ``data-variable-picker-category=<slug>`` on each category row.
##   * ``data-variable-picker-row=<variable key>`` on each variable row.
##   * ``data-variable-picker-row-name=<variable key>`` on the name cell.
##   * ``data-variable-picker-row-value=<resolved value>`` on the value
##     cell.
##   * ``data-variable-picker-row-usage=<count>`` on the usage badge.
##   * ``data-variable-picker-row-edit="true"`` on the per-row edit
##     affordance.
##   * ``data-variable-picker-empty="true"`` on the empty-state row.
##   * ``data-variable-picker-footer="true"`` on the source-scope footer.
##   * ``data-variable-picker-close="true"`` on the close button.

import std/[strutils, tables]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

# --------------------------------------------------------------------------- #
#  Public types.
# --------------------------------------------------------------------------- #

type
  VariablePickerState* = ref object
    ## Reactive state for the picker popover. A single instance is
    ## mounted at the shell root and reused across all property rows;
    ## clicking the chip's chevron writes ``targetPropertyKey`` and
    ## flips ``open`` to ``true``. Clicking outside or pressing ESC
    ## flips ``open`` back to ``false``.
    open*: Signal[bool]
    anchorRect*: Signal[tuple[x, y, w, h: float]]
      ## Anchor rectangle in document coordinates (viewport rect plus
      ## window.scrollX/Y on the JS side). The mount positions the
      ## popover absolutely from this rect and flips it above the
      ## anchor when the bottom would clip the viewport.
    searchText*: Signal[string]
    targetPropertyKey*: Signal[PropertyBindingKey]
    compatibleCategories*: Signal[set[VariablePickerCategory]]
      ## VBIND-M4 compatibility filter. When NON-empty, the picker lists
      ## only variables whose ``variableCategoryFor`` is in this set (so
      ## a colour property offers only colour tokens). The EMPTY set is
      ## the backward-compatible default meaning *no filter / show all*;
      ## callers that never set it (every existing caller and the
      ## isolated fixture) see the picker exactly as before. Opening the
      ## picker to link a specific property seeds this from
      ## ``compatibleCategoriesFor(targetKey.propertyName)``.
    previouslyLinked*: Signal[seq[string]]
      ## VBIND-M6 "Previously linked" group. The variable keys previously
      ## linked to the target property (``elementId × propertyName``),
      ## MOST-RECENT-FIRST, seeded at open time from
      ## ``previouslyLinkedVariables(vm, targetKey)``. When non-empty the
      ## picker renders these in a leading group ABOVE the category
      ## groups, intersected with the currently-available + compatible +
      ## searched token set (so only still-valid, still-compatible,
      ## still-matching prior variables show) and DEDUPED out of their
      ## category groups below. The EMPTY seq is the backward-compatible
      ## default: no group, picker identical to VBIND-M4. Callers that
      ## never set it (every existing caller + the isolated fixture) see
      ## no change.
    expandedCategories*: Signal[Table[VariablePickerCategory, bool]]
      ## Per-category expansion state. ``true`` means the category's
      ## rows are visible; ``false`` collapses them. All categories
      ## default to ``true``.
    onVariableEdit*: Signal[proc(variableKey: string)]
      ## Callback invoked when a row's "Edit this variable" affordance
      ## fires. Hooks the inline editor (Phase E.4). The default value
      ## is ``nil`` — callers wire the inline editor by writing through
      ## the signal after construction.

  EditAnchorHookProc* = proc(variableKey: string;
                              x, y, w, h: float)

# --------------------------------------------------------------------------- #
#  Visual contract — pulled from the spec.
# --------------------------------------------------------------------------- #

const
  vpWidth          = "320px"
  vpMaxHeight      = "480px"
  vpZIndex         = "1100"
  vpBg             = "#16171F"
  vpBorder         = "1px solid #2D2D3A"
  vpRadius         = "8px"
  vpShadow         = "0 24px 80px rgba(0, 0, 0, 0.42)"
  vpPaddingY       = "6px"
  vpSearchBg       = "#0F0F18"
  vpSearchBorder   = "1px solid #2F3140"
  vpSearchRadius   = "4px"
  vpSearchPadding  = "6px 8px"
  vpRowGap         = "8px"
  vpRowHeight      = "32px"
  vpRowPadding     = "0 12px"
  vpRowHoverBg     = "rgba(124, 122, 237, 0.10)"
  vpTextPrimary    = "#F1F5F9"
  vpTextMuted      = "#A0A2B0"
  vpTextDim        = "#6B6F80"
  vpAccent         = "#7C7AED"
  vpSwatchSize     = "16px"
  vpSwatchBorder   = "1px solid rgba(255, 255, 255, 0.12)"
  vpSwatchRadius   = "3px"
  vpCategoryFont   = "10px"
  vpRowFont        = "12px"
  vpRowFamily      = "ui-monospace, 'SFMono-Regular', Menlo, " &
                     "Consolas, monospace"
  vpUsageBg        = "rgba(124, 122, 237, 0.16)"
  vpUsageBorder    = "1px solid rgba(124, 122, 237, 0.30)"
  vpUsageColor     = "#C8C6FF"
  vpUsagePadding   = "1px 6px"
  vpUsageRadius    = "9999px"
  vpUsageFont      = "10px"
  vpFooterBg       = "#0F0F18"
  vpFooterBorder   = "1px solid #2F3140"
  vpEmptyColor     = "#6B6F80"

# --------------------------------------------------------------------------- #
#  Constructors + state helpers.
# --------------------------------------------------------------------------- #

proc createVariablePickerState*(): VariablePickerState =
  ## Fresh picker state in the closed position. All categories start
  ## expanded so the user sees every available variable on first open.
  var expansion = initTable[VariablePickerCategory, bool]()
  for cat in [vpcColour, vpcSpacing, vpcTypography, vpcRadius,
              vpcEffect, vpcNumber, vpcString]:
    expansion[cat] = true
  VariablePickerState(
    open: createSignal(false),
    anchorRect: createSignal((0.0, 0.0, 0.0, 0.0)),
    searchText: createSignal(""),
    targetPropertyKey: createSignal(PropertyBindingKey()),
    compatibleCategories:
      createSignal(default(set[VariablePickerCategory])),
    previouslyLinked: createSignal[seq[string]](@[]),
    expandedCategories: createSignal(expansion),
    onVariableEdit: createSignal[proc(variableKey: string)](nil))

proc closeVariablePicker*(state: VariablePickerState) =
  ## Close the popover. Idempotent (no-op when already closed).
  if state.open.val:
    state.open.val = false

proc toggleCategoryExpansion*(state: VariablePickerState;
                               category: VariablePickerCategory) =
  ## Flip the expansion state of ``category``. Idempotent through the
  ## signal's default equality.
  state.expandedCategories.update(proc(prev: Table[VariablePickerCategory, bool]):
      Table[VariablePickerCategory, bool] =
    result = prev
    let current = result.getOrDefault(category, true)
    result[category] = not current)

# --------------------------------------------------------------------------- #
#  Filtering / categorisation helpers (pure — exported so the tests can
#  exercise them without mounting).
# --------------------------------------------------------------------------- #

func categoryLabel*(category: VariablePickerCategory): string =
  case category
  of vpcColour:     "Colour"
  of vpcSpacing:    "Spacing"
  of vpcTypography: "Typography"
  of vpcRadius:     "Radius"
  of vpcEffect:     "Effect"
  of vpcNumber:     "Number"
  of vpcString:     "String"

func categorySlug*(category: VariablePickerCategory): string =
  case category
  of vpcColour:     "colour"
  of vpcSpacing:    "spacing"
  of vpcTypography: "typography"
  of vpcRadius:     "radius"
  of vpcEffect:     "effect"
  of vpcNumber:     "number"
  of vpcString:     "string"

func matchesPickerQuery*(token: FoundationTokenEntry;
                          query: string): bool =
  ## Returns true when ``query`` is empty (everything matches) OR the
  ## token's key contains the query as a case-insensitive substring.
  ## The spec calls for "prefix and infix" — substring covers both.
  if query.len == 0:
    return true
  token.key.toLowerAscii().contains(query.toLowerAscii())

func filterPickerTokens*(tokens: seq[FoundationTokenEntry];
                          query: string): seq[FoundationTokenEntry] =
  for token in tokens:
    if token.matchesPickerQuery(query):
      result.add token

func filterByCompatibleCategories*(tokens: seq[FoundationTokenEntry];
    categories: set[VariablePickerCategory]): seq[FoundationTokenEntry] =
  ## VBIND-M4: restrict ``tokens`` to those whose
  ## ``variableCategoryFor`` is one of ``categories``. An EMPTY
  ## ``categories`` set is the backward-compatible no-op: the input is
  ## returned unchanged (the picker shows every variable, as before).
  if categories == {}:
    return tokens
  for token in tokens:
    if variableCategoryFor(token) in categories:
      result.add token

func categoriseTokens*(tokens: seq[FoundationTokenEntry]):
    seq[tuple[category: VariablePickerCategory;
              entries: seq[FoundationTokenEntry]]] =
  ## Groups ``tokens`` into the seven picker categories, preserving
  ## the within-category source order. Empty categories are dropped
  ## from the result so the mount can iterate without an extra
  ## visibility test. The category order is the spec's reading order.
  var byCategory = initTable[VariablePickerCategory, seq[FoundationTokenEntry]]()
  for token in tokens:
    let cat = variableCategoryFor(token)
    if cat notin byCategory:
      byCategory[cat] = @[]
    byCategory[cat].add token
  for cat in [vpcColour, vpcSpacing, vpcTypography, vpcRadius,
              vpcEffect, vpcNumber, vpcString]:
    if cat in byCategory and byCategory[cat].len > 0:
      result.add (category: cat, entries: byCategory[cat])

# --------------------------------------------------------------------------- #
#  Mount — single-instance popover for the editor.
# --------------------------------------------------------------------------- #

proc mountVariablePicker*[R, E](r: R; parent: E; vm: EditorVM;
                                  state: VariablePickerState): E =
  ## Mount the popover under ``parent``. Returns the popover root.
  ##
  ## The popover renders nothing when ``state.open`` is false (the
  ## root carries ``display: none``). When opened the body is rebuilt
  ## reactively on every change to ``state.searchText`` /
  ## ``vm.inspector.availableVariables`` / ``state.expandedCategories``
  ## so the row set always mirrors the foundations.
  let capturedVm = vm
  let capturedState = state

  var rootNode: E
  var searchInput: E
  var bodyNode: E
  var footerNode: E
  var closeBtn: E

  let root = ui(r):
    tdiv(
      ref = rootNode,
      `data-variable-picker` = "true",
      `data-variable-picker-open` = "false",
      role = "dialog",
      `aria-modal` = "false",
      `aria-label` = "Variable picker",
      position = "absolute",
      display = "none",
      flex_direction = "column",
      width = vpWidth,
      max_height = vpMaxHeight,
      background_color = vpBg,
      border = vpBorder,
      border_radius = vpRadius,
      box_shadow = vpShadow,
      color = vpTextPrimary,
      font_size = vpRowFont,
      z_index = vpZIndex,
      overflow = "hidden"):
      # Header row — search field + close button.
      tdiv(
        display = "flex",
        flex_direction = "row",
        align_items = "center",
        gap = vpRowGap,
        padding = "8px 10px",
        border_bottom = vpFooterBorder):
        input(
          ref = searchInput,
          `data-variable-picker-search` = "true",
          `aria-label` = "Filter variables",
          placeholder = "Search variables...",
          `type` = "text",
          flex = "1",
          min_width = "0",
          height = "28px",
          padding = vpSearchPadding,
          background_color = vpSearchBg,
          border = vpSearchBorder,
          border_radius = vpSearchRadius,
          color = vpTextPrimary,
          font_size = vpRowFont,
          font_family = "inherit",
          outline = "none")
        tdiv(
          ref = closeBtn,
          `data-variable-picker-close` = "true",
          role = "button",
          tabindex = "0",
          `aria-label` = "Close variable picker",
          flex_shrink = "0",
          display = "flex",
          align_items = "center",
          justify_content = "center",
          width = "20px",
          height = "20px",
          color = vpTextMuted,
          font_size = "14px",
          cursor = "pointer",
          user_select = "none"):
          # U+00D7 MULTIPLICATION SIGN — close glyph.
          text "\xC3\x97"
      # Scrollable body — category sections rendered reactively.
      tdiv(
        ref = bodyNode,
        `data-variable-picker-body` = "true",
        display = "flex",
        flex_direction = "column",
        flex = "1",
        min_height = "0",
        overflow_y = "auto",
        overflow_x = "hidden",
        padding = vpPaddingY & " 0")
      # Source-scope footer.
      tdiv(
        ref = footerNode,
        `data-variable-picker-footer` = "true",
        display = "flex",
        align_items = "center",
        justify_content = "space-between",
        padding = "6px 10px",
        background_color = vpFooterBg,
        border_top = vpFooterBorder,
        color = vpTextMuted,
        font_size = vpCategoryFont,
        text_transform = "uppercase",
        letter_spacing = "0.04em"):
        span:
          text "Library: Foundations"
        span(color = vpTextDim):
          text "Local scope"

  # ------------------------------------------------------------------------- #
  # Visibility + smart edge-flipping.
  # ------------------------------------------------------------------------- #
  createRenderEffect proc() =
    let open = capturedState.open.val
    let rect = capturedState.anchorRect.val
    r.setAttribute(rootNode, "data-variable-picker-open",
      if open: "true" else: "false")
    r.setStyle(rootNode, "display",
      if open: "flex" else: "none")
    if not open:
      return
    # The picker anchors below the chevron by default; if the popover
    # would extend past the viewport bottom, flip above the anchor.
    when defined(js):
      let belowSpace = 720.0 - (rect.y + rect.h)
      let placeAbove = belowSpace < 480.0 and rect.y > 480.0
      let topPx =
        if placeAbove: rect.y - 6.0 - 480.0
        else: rect.y + rect.h + 6.0
      let leftPx = rect.x
      r.setStyle(rootNode, "top", $topPx & "px")
      r.setStyle(rootNode, "left", $leftPx & "px")
    else:
      # Native path — surface the rect via data-attrs so headless tests
      # can verify the popover is positioned without measuring DOM.
      r.setAttribute(rootNode, "data-variable-picker-anchor-x", $rect.x)
      r.setAttribute(rootNode, "data-variable-picker-anchor-y", $rect.y)
      r.setAttribute(rootNode, "data-variable-picker-anchor-w", $rect.w)
      r.setAttribute(rootNode, "data-variable-picker-anchor-h", $rect.h)

  # ------------------------------------------------------------------------- #
  # Reactive body — rebuilds the list when search / variables / expansion
  # changes. Tests run the effect by writing through the state signals
  # without needing a real DOM.
  # ------------------------------------------------------------------------- #
  createRenderEffect proc() =
    let query = capturedState.searchText.val
    let tokens = capturedVm.inspector.availableVariables.val
    let expansion = capturedState.expandedCategories.val
    let targetKey = capturedState.targetPropertyKey.val
    let compatible = capturedState.compatibleCategories.val
    let priorKeys = capturedState.previouslyLinked.val
    r.clearChildren(bodyNode)
    # VBIND-M4: restrict to the property's compatible categories first
    # (empty set ⇒ no filter), then apply the search query. An empty
    # result falls through to the shared empty-state row below.
    let filtered = filterByCompatibleCategories(
      filterPickerTokens(tokens, query), compatible)
    if filtered.len == 0:
      let empty = ui(r):
        tdiv(
          `data-variable-picker-empty` = "true",
          display = "flex",
          align_items = "center",
          justify_content = "center",
          padding = "32px 16px",
          color = vpEmptyColor,
          font_size = vpRowFont,
          text_align = "center"):
          text "No matching variables"
      r.appendChild(bodyNode, empty)
      return

    # Shared per-row builder — reused by the VBIND-M6 "Previously linked"
    # group and the normal category groups, so a row clicked in either
    # place binds identically (``bindPropertyToVariable`` + close).
    proc renderRow(entry: FoundationTokenEntry) =
      let entryKey = entry.key
      let entryValue = entry.value
      let usage = entry.affectedStories.len
      let isColour = variableCategoryFor(entry) == vpcColour
      var rowNode: E
      var editNode: E
      let rowMounted = ui(r):
        tdiv(
          ref = rowNode,
          `data-variable-picker-row` = entryKey,
          role = "button",
          tabindex = "0",
          display = "flex",
          align_items = "center",
          gap = vpRowGap,
          min_height = vpRowHeight,
          padding = vpRowPadding,
          cursor = "pointer")
      # Swatch (colour categories) or value-preview tile (others).
      # Built outside the ui block so a clean ``if/else`` keeps the
      # DSL happy.
      let preview =
        if isColour:
          ui(r):
            tdiv(
              `data-variable-picker-row-swatch` = entryValue,
              width = vpSwatchSize,
              height = vpSwatchSize,
              background_color = entryValue,
              border = vpSwatchBorder,
              border_radius = vpSwatchRadius,
              flex_shrink = "0")
        else:
          ui(r):
            tdiv(
              `data-variable-picker-row-preview` = entryValue,
              display = "flex",
              align_items = "center",
              justify_content = "center",
              min_width = vpSwatchSize,
              height = vpSwatchSize,
              padding = "0 4px",
              background_color = "#1A1B22",
              border = "1px solid #2A2B36",
              border_radius = vpSwatchRadius,
              color = vpTextMuted,
              font_size = "9px",
              flex_shrink = "0"):
              text (if entryValue.len > 0: entryValue else: "-")
      r.appendChild(rowNode, preview)
      # Name + resolved value column.
      let nameCol = ui(r):
        tdiv(
          display = "flex",
          flex_direction = "column",
          flex = "1",
          min_width = "0",
          gap = "1px"):
          span(
            `data-variable-picker-row-name` = entryKey,
            color = vpTextPrimary,
            font_size = vpRowFont,
            font_family = vpRowFamily,
            overflow = "hidden",
            text_overflow = "ellipsis",
            white_space = "nowrap"):
            text entryKey
          span(
            `data-variable-picker-row-value` = entryValue,
            color = vpTextMuted,
            font_size = "10px",
            font_family = vpRowFamily,
            overflow = "hidden",
            text_overflow = "ellipsis",
            white_space = "nowrap"):
            text entryValue
      r.appendChild(rowNode, nameCol)
      # Usage badge.
      let usageBadge = ui(r):
        span(
          `data-variable-picker-row-usage` = $usage,
          flex_shrink = "0",
          padding = vpUsagePadding,
          background_color = vpUsageBg,
          border = vpUsageBorder,
          border_radius = vpUsageRadius,
          color = vpUsageColor,
          font_size = vpUsageFont,
          white_space = "nowrap"):
          text ($usage & "x")
      r.appendChild(rowNode, usageBadge)
      # Edit this variable affordance.
      let editButton = ui(r):
        tdiv(
          ref = editNode,
          `data-variable-picker-row-edit` = "true",
          role = "button",
          tabindex = "0",
          `aria-label` = "Edit variable " & entryKey,
          title = "Edit this variable",
          flex_shrink = "0",
          padding = "0 4px",
          color = vpAccent,
          font_size = "11px",
          cursor = "pointer",
          user_select = "none"):
          # U+270E LOWER RIGHT PENCIL.
          text "\xE2\x9C\x8E"
      r.appendChild(rowNode, editButton)
      r.appendChild(bodyNode, rowMounted)
      let capturedKey = entryKey
      let pickHandler = proc() =
        capturedVm.bindPropertyToVariable(targetKey, capturedKey)
        capturedState.closeVariablePicker()
      r.addEventListener(rowNode, "click", pickHandler)
      r.addEventListener(rowNode, "keydown", pickHandler)
      let editHandler = proc() =
        let cb = capturedState.onVariableEdit.val
        if cb != nil:
          cb(capturedKey)
      r.addEventListener(editNode, "click", editHandler)
      r.addEventListener(editNode, "keydown", editHandler)

    # VBIND-M6: leading "Previously linked" group. Intersect the history
    # (already most-recent-first) with the currently-visible ``filtered``
    # set so only still-available + still-compatible + still-matching
    # prior variables appear; a prior variable that no longer exists (or
    # was filtered out) is dropped. The matched keys are deduped OUT of
    # the category groups below so each variable renders once (at the
    # top). Empty history ⇒ no group ⇒ picker identical to VBIND-M4.
    var priorEntries: seq[FoundationTokenEntry] = @[]
    var priorMatched: seq[string] = @[]
    for pk in priorKeys:
      for token in filtered:
        if token.key == pk and token.key notin priorMatched:
          priorEntries.add token
          priorMatched.add token.key
          break
    if priorEntries.len > 0:
      let priorHeader = ui(r):
        tdiv(
          `data-variable-picker-previously-linked` = "true",
          display = "flex",
          flex_direction = "column",
          margin_bottom = "4px"):
          tdiv(
            `data-variable-picker-previously-linked-header` = "true",
            display = "flex",
            align_items = "center",
            justify_content = "space-between",
            padding = "4px 12px",
            color = vpTextMuted,
            font_size = vpCategoryFont,
            text_transform = "uppercase",
            letter_spacing = "0.04em",
            user_select = "none"):
            span:
              text "Previously linked"
      r.appendChild(bodyNode, priorHeader)
      for entry in priorEntries:
        renderRow(entry)

    let grouped = categoriseTokens(filtered)
    for groupIndex in 0 ..< grouped.len:
      let category = grouped[groupIndex].category
      # Dedup: hide entries already shown in the "Previously linked"
      # group so a prior variable renders once (at the top).
      var entries: seq[FoundationTokenEntry] = @[]
      for entry in grouped[groupIndex].entries:
        if entry.key notin priorMatched:
          entries.add entry
      if entries.len == 0:
        continue
      let slug = categorySlug(category)
      let label = categoryLabel(category)
      let expanded = expansion.getOrDefault(category, true)
      var headerNode: E
      let section = ui(r):
        tdiv(
          `data-variable-picker-category` = slug,
          `data-variable-picker-category-expanded` =
            (if expanded: "true" else: "false"),
          display = "flex",
          flex_direction = "column",
          margin_bottom = "4px"):
          tdiv(
            ref = headerNode,
            `data-variable-picker-category-header` = slug,
            role = "button",
            tabindex = "0",
            display = "flex",
            align_items = "center",
            justify_content = "space-between",
            padding = "4px 12px",
            color = vpTextMuted,
            font_size = vpCategoryFont,
            text_transform = "uppercase",
            letter_spacing = "0.04em",
            cursor = "pointer",
            user_select = "none"):
            span:
              text label
            span:
              # U+25BE down arrow when expanded, U+25B8 right arrow
              # when collapsed.
              text (if expanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
      r.appendChild(bodyNode, section)
      let capturedCategory = category
      r.addEventListener(headerNode, "click", proc() =
        capturedState.toggleCategoryExpansion(capturedCategory))
      r.addEventListener(headerNode, "keydown", proc() =
        capturedState.toggleCategoryExpansion(capturedCategory))
      if not expanded:
        continue
      for entry in entries:
        renderRow(entry)

  # Mirror searchText → search input on external writes (e.g. tests).
  createRenderEffect proc() =
    let q = capturedState.searchText.val
    r.setInputValue(searchInput, q)

  # User typing into the search input flows back into the signal.
  let onSearchInput = proc() =
    capturedState.searchText.val = r.inputValue(searchInput)
  r.addEventListener(searchInput, "input", onSearchInput)
  r.addEventListener(searchInput, "change", onSearchInput)

  # Close button.
  let onCloseClick = proc() =
    capturedState.closeVariablePicker()
  r.addEventListener(closeBtn, "click", onCloseClick)
  r.addEventListener(closeBtn, "keydown", onCloseClick)

  # Outside click + ESC. JS-only: the headless tests close the picker
  # through ``closeVariablePicker``.
  when defined(js):
    {.emit: ["""
      (function (root, st) {
        if (!root || root.__isonimPickerBound) return;
        root.__isonimPickerBound = true;
        function onDocClick(e) {
          if (!root.__isonimPickerOpen) return;
          if (root.contains(e.target)) return;
          if (typeof st === 'function') return;
          // Fire a synthetic close — we use a custom event that the
          // Nim side hooks for symmetry with the keydown path.
          var ev = new Event('isonim-picker-close', { bubbles: false });
          root.dispatchEvent(ev);
        }
        function onKeyDown(e) {
          if (e.key !== 'Escape') return;
          if (!root.__isonimPickerOpen) return;
          var ev = new Event('isonim-picker-close', { bubbles: false });
          root.dispatchEvent(ev);
        }
        document.addEventListener('mousedown', onDocClick, true);
        document.addEventListener('keydown', onKeyDown);
      })(""", rootNode, """, null);
    """].}
    r.addEventListener(rootNode, "isonim-picker-close", proc() =
      capturedState.closeVariablePicker())
    # Mirror open state into a flag the JS shim reads above.
    createRenderEffect proc() =
      let open = capturedState.open.val
      {.emit: [rootNode, ".__isonimPickerOpen = ", open, ";"].}

  r.appendChild(parent, root)
  result = root

# --------------------------------------------------------------------------- #
#  JS-side helper: openVariablePicker — compute anchorRect from a DOM
#  element and flip the state to open.
# --------------------------------------------------------------------------- #

proc openVariablePickerWithRect*(state: VariablePickerState;
                                  targetKey: PropertyBindingKey;
                                  x, y, w, h: float) =
  ## Renderer-neutral helper — set the anchor rectangle directly. Used
  ## by the headless tests + the JS-side ``openVariablePicker`` wrapper
  ## below.
  state.targetPropertyKey.val = targetKey
  state.anchorRect.val = (x, y, w, h)
  state.searchText.val = ""
  state.open.val = true

when defined(js):
  import std/dom

  proc openVariablePicker*(state: VariablePickerState;
                            anchorEl: Element;
                            targetKey: PropertyBindingKey) =
    ## JS helper that reads the anchor element's ``getBoundingClientRect``
    ## and flips the picker open with the right anchor rectangle. The
    ## anchor element is the chevron / chip the picker should sit
    ## below.
    if anchorEl == nil:
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
    # VBIND-M4: seed the compatibility filter from the target property
    # so a JS-side open (chip chevron / bind slot) lists only compatible
    # variables. An unmapped property → empty set → show all.
    state.compatibleCategories.val =
      compatibleCategoriesFor(targetKey.propertyName)
    openVariablePickerWithRect(state, targetKey, rectX, rectY, rectW, rectH)
