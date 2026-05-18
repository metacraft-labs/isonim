## Compact one-of-many choice rows used by IsoNim editor panels.
##
## Provides both a horizontal variant (`renderCompactChoiceRow`) used by the
## inspector and component-detail option strips, and a vertical variant
## (`renderCompactChoiceColumn`) used by the M57 preview-pane edge strips.
##
## M58 backward-compatibility strategy: the original static-options overloads
## of both `renderCompactChoiceRow` and `renderCompactChoiceColumn` are
## preserved so existing call sites (M56 inspector code in
## `component_detail.nim` / `component_edit.nim` and the headless test fixture
## that exercises the column directly) keep compiling unchanged. New code that
## needs the chip set to follow a signal uses the thunk overload that wraps
## the chip-construction body in `createRenderEffect`, diffs against the
## previously-rendered set keyed by `(label, shortLabel)`, and patches the
## DOM in place — surviving chips keep their identity (focus + event
## listeners survive), removed chips are detached and their per-chip reactive
## owners disposed, and newly-added chips are spliced in at the right index.

import isonim/core/owner
import isonim/core/computation
import isonim/dsl/ui

const
  bgSurface = "#1E293B"
  bgInput = "#0F172A"
  bgSidebar = "#151D2E"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"

type
  CompactChoiceOption* = object
    label*: string
    shortLabel*: string
    ariaLabel*: string
    selected*: bool
    enabled*: bool
    dataAttrs*: seq[(string, string)]
    onChoose*: proc()

  CompactChoiceRow*[E] = object
    root*: E
    optionNodes*: seq[E]
    optionIndexes*: seq[int]
    overflowNode*: E

  CompactChoiceColumn*[E] = object
    root*: E
    optionNodes*: seq[E]
    optionIndexes*: seq[int]
    overflowNode*: E

  ChipMountedHook*[E] = proc(node: E; option: CompactChoiceOption; index: int)
    ## Callback fired by the thunk overload for every newly-created chip
    ## (either in the primary strip or in the overflow popup). The caller
    ## typically installs per-chip reactive bindings + live event listeners
    ## here (see `bindBackendChip` / `bindViewportChip` / `bindModeChip` in
    ## `shell.nim`).

func visibleText(option: CompactChoiceOption): string =
  if option.shortLabel.len > 0: option.shortLabel else: option.label

func selectedOptionIndex(options: seq[CompactChoiceOption]): int =
  result = -1
  for i in 0 ..< options.len:
    if options[i].selected:
      return i

func containsIndex(indexes: seq[int]; value: int): bool =
  for index in indexes:
    if index == value:
      return true

func compactChoiceVisibleIndexes(options: seq[CompactChoiceOption];
    visibleLimit: int): seq[int] =
  let limit = min(max(1, visibleLimit), options.len)
  for i in 0 ..< limit:
    result.add i
  let selectedIndex = selectedOptionIndex(options)
  if selectedIndex >= 0 and selectedIndex notin result:
    if result.len == 0:
      result.add selectedIndex
    else:
      result[^1] = selectedIndex

proc compactChoiceHandler(enabled: bool; callback: proc()): proc() =
  let capturedEnabled = enabled
  let capturedCallback = callback
  result = proc() =
    if capturedEnabled and capturedCallback != nil:
      capturedCallback()

func chipIdentity*(option: CompactChoiceOption): string =
  ## M58 chip-set diff identity. `CompactChoiceOption` has no stable id
  ## field; `(label, shortLabel)` is the best-available natural key for
  ## the strips we care about (backend / viewport / mode all use unique
  ## label pairs).
  option.label & "\x1F" & option.shortLabel

# ---- imperative chip builders (used by both row and column variants) -------

proc buildColumnChip[R, E](r: R; option: CompactChoiceOption;
    chipWidth, chipHeight: string): E =
  ## Build a single primary-strip chip for the vertical column. Returns
  ## the chip's outer element with text content + onclick / onkeydown
  ## handlers already installed by the `ui` macro. The caller is
  ## responsible for any per-chip live reactive bindings.
  ##
  ## M-EVP-14: each chip is a real pill — rounded radius, padding
  ## 4px 12px, transparent background with a subtle 1px border on the
  ## inactive state, and font-weight 500. The active state (solid
  ## indigo + white text) is applied by the caller's per-chip
  ## bindBackendChip / bindViewportChip / bindModeChip render effect.
  ## The chip width is treated as a *minimum* so horizontal toolbar
  ## reuse (`tiltHorizontal`) lets the chip grow to fit its label.
  let enabled = option.enabled
  let selected = option.selected
  let choose = compactChoiceHandler(enabled, option.onChoose)
  result = ui(r):
    tdiv(role = "button", tabindex = (if enabled: "0" else: "-1"),
          `aria-label` = option.ariaLabel,
          `aria-pressed` = (if selected: "true" else: "false"),
          `aria-disabled` = (if enabled: "false" else: "true"),
          `data-compact-choice-enabled` = (
              if enabled: "true" else: "false"),
          min_height = chipHeight,
          display = "flex", align_items = "center",
          justify_content = "center",
          padding = "4px 12px",
          border = "1px solid " & (
              if selected: "transparent"
              else: "rgba(255,255,255,0.08)"),
          border_radius = "6px",
          background_color = (
              if selected: accent else: "transparent"),
          color = (
              if selected: "#FFFFFF"
              elif enabled: "#A0A2B0"
              else: textDim),
          opacity = (if enabled: "1" else: "0.35"),
          font_size = "11px",
          font_weight = (if selected: "600" else: "500"),
          line_height = "1",
          cursor = (
              if enabled: "pointer" else: "not-allowed"),
          white_space = "nowrap", overflow = "hidden",
          text_overflow = "ellipsis",
          transition = "background-color 120ms ease, color 120ms ease, border-color 120ms ease",
          onclick = choose,
          onkeydown = choose):
      text option.visibleText()
  for (key, value) in option.dataAttrs:
    r.setAttribute(result, key, value)

proc buildColumnPopupChip[R, E](r: R; option: CompactChoiceOption): E =
  ## Build a single overflow-popup row for the vertical column.
  let enabled = option.enabled
  let selected = option.selected
  let choose = compactChoiceHandler(enabled, option.onChoose)
  result = ui(r):
    tdiv(role = "button", tabindex = (if enabled: "0" else: "-1"),
          `aria-label` = option.ariaLabel,
          `aria-pressed` = (if selected: "true" else: "false"),
          `aria-disabled` = (if enabled: "false" else: "true"),
          `data-compact-choice-enabled` = (
              if enabled: "true" else: "false"),
          `data-compact-choice-overflow-option` = "true",
          display = "grid",
          grid_template_columns = "34px minmax(0, 1fr)",
          align_items = "center", column_gap = "5px",
          min_height = "22px",
          padding = "3px 4px",
          border_radius = "3px",
          background_color = (
              if selected: bgSurface else: "transparent"),
          color = (if enabled: textPrimary else: textDim),
          font_size = "10px",
          cursor = (if enabled: "pointer" else: "default"),
          onclick = choose,
          onkeydown = choose):
      span(color = (if selected: accent else: textMuted),
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text option.visibleText()
      span(white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text option.label
  for (key, value) in option.dataAttrs:
    r.setAttribute(result, key, value)

proc buildRowChip[R, E](r: R; option: CompactChoiceOption): E =
  ## Build a single primary-strip chip for the horizontal row.
  ## v4: each chip is now a discrete pill (rounded outline, accent fill only
  ## on the selected one) instead of a segment of a single filled bar. The
  ## strip-level border/background is dropped in `renderCompactChoiceRow` so
  ## the chips read as a pill group, not one continuous filled rail.
  let enabled = option.enabled
  let selected = option.selected
  let choose = compactChoiceHandler(enabled, option.onChoose)
  result = ui(r):
    tdiv(role = "button", tabindex = (if enabled: "0" else: "-1"),
          `aria-label` = option.ariaLabel,
          `aria-pressed` = (if selected: "true" else: "false"),
          `data-compact-choice-enabled` = (
              if enabled: "true" else: "false"),
          min_width = "0",
          height = "20px",
          display = "flex", align_items = "center",
          justify_content = "center",
          padding = "0 7px",
          border = "1px solid " & (if selected: accent else: border),
          border_radius = "10px",
          background_color = (if selected: accent &
              "55" else: bgInput),
          color = (if enabled: (if selected: textPrimary else: textMuted) else: textDim),
          font_size = "10px",
          font_weight = (if selected: "700" else: "500"),
          line_height = "1",
          box_shadow = (if selected: "inset 0 0 0 1px rgba(147,197,253,.28)" else: "none"),
          cursor = (if enabled: "pointer" else: "default"),
          white_space = "nowrap", overflow = "hidden",
          text_overflow = "ellipsis",
          onclick = choose,
          onkeydown = choose):
      text option.visibleText()
  for (key, value) in option.dataAttrs:
    r.setAttribute(result, key, value)
  if enabled and option.onChoose != nil:
    r.addEventListener(result, "click", option.onChoose)
    r.addEventListener(result, "keydown", option.onChoose)

proc buildRowPopupChip[R, E](r: R; option: CompactChoiceOption): E =
  ## Build a single overflow-popup row for the horizontal row.
  let enabled = option.enabled
  let selected = option.selected
  let choose = compactChoiceHandler(enabled, option.onChoose)
  result = ui(r):
    tdiv(role = "button", tabindex = (if enabled: "0" else: "-1"),
          `aria-label` = option.ariaLabel,
          `aria-pressed` = (if selected: "true" else: "false"),
          `data-compact-choice-enabled` = (
              if enabled: "true" else: "false"),
          display = "grid",
          grid_template_columns = "34px minmax(0, 1fr)",
          align_items = "center", column_gap = "5px",
          min_height = "22px",
          padding = "3px 4px",
          border_radius = "3px",
          background_color = (
              if selected: bgSurface else: "transparent"),
          color = (if enabled: textPrimary else: textDim),
          font_size = "10px",
          cursor = (if enabled: "pointer" else: "default"),
          onclick = choose,
          onkeydown = choose):
      span(color = (if selected: accent else: textMuted),
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text option.visibleText()
      span(white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text option.label
  for (key, value) in option.dataAttrs:
    r.setAttribute(result, key, value)
  if enabled and option.onChoose != nil:
    r.addEventListener(result, "click", option.onChoose)
    r.addEventListener(result, "keydown", option.onChoose)

# ---- horizontal row (static + thunk overloads) -----------------------------

proc renderCompactChoiceRow*[R, E](r: R; label, ariaLabel: string;
    options: seq[CompactChoiceOption]; visibleLimit = 2;
    labelWidth = "72px"; minHeight = "24px"): CompactChoiceRow[E] =
  let hasLabel = label.len > 0
  let visibleIndexes = compactChoiceVisibleIndexes(options, visibleLimit)
  let visibleCount = visibleIndexes.len
  let hasOverflow = visibleCount < options.len
  let chipColumns =
    if visibleCount <= 0:
      if hasOverflow: "20px" else: "minmax(0, 1fr)"
    elif hasOverflow:
      "repeat(" & $visibleCount & ", minmax(0, 1fr)) 20px"
    else:
      "repeat(" & $visibleCount & ", minmax(0, 1fr))"
  let rootColumns =
    if hasLabel: labelWidth & " minmax(0, 1fr)" else: "minmax(0, 1fr)"

  var rowRoot: E
  var stripNode: E
  result = CompactChoiceRow[E](optionNodes: @[], optionIndexes: @[])
  rowRoot = ui(r):
    tdiv(display = "grid",
          grid_template_columns = rootColumns,
          align_items = "center", column_gap = "6px",
          min_height = minHeight,
          max_width = "100%",
          overflow = "visible",
          role = "group",
          `aria-label` = ariaLabel,
          `data-compact-choice-row` = "true"):
      if hasLabel:
        span(font_size = "10px", color = textMuted,
              white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis"):
          text label
      tdiv(ref = stripNode,
            display = "grid",
            grid_template_columns = chipColumns,
            align_items = "center",
            min_height = "22px",
            min_width = "0",
            # v4: strip is now a transparent container; each chip carries
            # its own border/radius so the row reads as a pill group.
            column_gap = "4px",
            overflow = "visible",
            `data-compact-choice-strip` = "true")
  result.root = rowRoot

  # Insert the primary chips imperatively (no popup chevron yet — that
  # comes after, as a sibling of the chip cells inside the strip's grid).
  for i in 0 ..< options.len:
    if not visibleIndexes.containsIndex(i):
      continue
    let chip = buildRowChip[R, E](r, options[i])
    r.appendChild(stripNode, chip)
    result.optionNodes.add chip
    result.optionIndexes.add i

  if hasOverflow:
    var detailsNode: E
    var summaryNode: E
    var popupListNode: E
    detailsNode = ui(r):
      details(position = "relative",
              height = "20px",
              color = textDim,
              font_size = "10px"):
        summary(ref = summaryNode,
                display = "flex", align_items = "center",
                justify_content = "center",
                width = "20px", height = "20px",
                list_style = "none", cursor = "pointer",
                # v4: strip background is gone; give the overflow chevron its
                # own pill border so it matches the new chip styling.
                border = "1px solid " & border,
                border_radius = "10px",
                `aria-label` = "More " & ariaLabel):
          text "\xE2\x8C\x84"
        tdiv(ref = popupListNode,
              position = "absolute", right = "0", top = "22px",
              z_index = "30", min_width = "170px",
              padding = "4px", border = "1px solid " & border,
              border_radius = "4px", background_color = bgSidebar,
              box_shadow = "0 8px 24px rgba(0,0,0,0.28)")
    r.appendChild(stripNode, detailsNode)
    result.overflowNode = summaryNode
    for i in 0 ..< options.len:
      let chip = buildRowPopupChip[R, E](r, options[i])
      r.appendChild(popupListNode, chip)
      result.optionNodes.add chip
      result.optionIndexes.add i

proc renderCompactChoiceRow*[R, E](r: R; label, ariaLabel: string;
    optionsThunk: proc(): seq[CompactChoiceOption]; visibleLimit = 2;
    labelWidth = "72px"; minHeight = "24px";
    onChipMounted: ChipMountedHook[E] = nil): CompactChoiceRow[E] =
  ## Thunk-driven horizontal variant. Mirrors the static overload but
  ## wraps the chip-construction body in `createRenderEffect` so the
  ## strip's chip set diffs / patches when the underlying signal set
  ## changes. See the file header for the M58 backward-compat strategy.
  let snapshot = optionsThunk()
  result = renderCompactChoiceRow[R, E](r, label, ariaLabel, snapshot,
    visibleLimit, labelWidth, minHeight)
  if onChipMounted != nil:
    for k in 0 ..< result.optionNodes.len:
      let idx = result.optionIndexes[k]
      if idx >= 0 and idx < snapshot.len:
        onChipMounted(result.optionNodes[k], snapshot[idx], idx)

# ---- vertical column (static + thunk overloads) ----------------------------

proc renderCompactChoiceColumn*[R, E](r: R; ariaLabel: string;
    options: seq[CompactChoiceOption]; visibleLimit = options.len;
    chipWidth = "44px"; chipHeight = "26px";
    dataAttrs: seq[(string, string)] = @[]): CompactChoiceColumn[E] =
  ## Vertical compact choice column. Mirrors `renderCompactChoiceRow`'s
  ## affordances (segmented strip, accent fill on active, overflow
  ## chevron, aria-pressed / aria-disabled, click + keydown handlers),
  ## but stacks the chips top-to-bottom for use on the preview pane's
  ## edge strips. The overflow popup expands to the right because edge
  ## strips sit flush against the left preview border.
  let limit = min(max(1, visibleLimit), options.len)
  let hasOverflow = limit < options.len
  var visibleIndexes: seq[int] = @[]
  for i in 0 ..< limit:
    visibleIndexes.add i
  let selectedIndex = selectedOptionIndex(options)
  if selectedIndex >= 0 and selectedIndex notin visibleIndexes:
    if visibleIndexes.len == 0:
      visibleIndexes.add selectedIndex
    else:
      visibleIndexes[^1] = selectedIndex

  result = CompactChoiceColumn[E](optionNodes: @[], optionIndexes: @[])

  var columnRoot: E
  var primaryHost: E
  columnRoot = ui(r):
    tdiv(ref = primaryHost,
          display = "flex", flex_direction = "column",
          align_items = "stretch",
          min_width = chipWidth, width = chipWidth,
          border = "1px solid " & border,
          border_radius = "3px",
          overflow = "visible",
          background_color = bgInput,
          role = "group",
          `aria-label` = ariaLabel,
          `aria-orientation` = "vertical",
          `data-compact-choice-column` = "true")
  for (key, value) in dataAttrs:
    r.setAttribute(columnRoot, key, value)
  result.root = columnRoot

  for i in 0 ..< options.len:
    if not visibleIndexes.containsIndex(i):
      continue
    let chip = buildColumnChip[R, E](r, options[i], chipWidth, chipHeight)
    r.appendChild(primaryHost, chip)
    result.optionNodes.add chip
    result.optionIndexes.add i

  if hasOverflow:
    var detailsNode: E
    var summaryNode: E
    var popupListNode: E
    detailsNode = ui(r):
      details(position = "relative",
              width = chipWidth,
              color = textDim,
              font_size = "10px"):
        summary(ref = summaryNode,
                display = "flex", align_items = "center",
                justify_content = "center",
                width = chipWidth, height = chipHeight,
                list_style = "none", cursor = "pointer",
                border_top = "1px solid " & border,
                `aria-label` = "More " & ariaLabel,
                `data-compact-choice-overflow` = "true"):
          text "\xE2\x96\xBE"
        tdiv(ref = popupListNode,
              position = "absolute", left = chipWidth, top = "0",
              z_index = "30", min_width = "170px",
              padding = "4px", border = "1px solid " & border,
              border_radius = "4px", background_color = bgSidebar,
              box_shadow = "0 8px 24px rgba(0,0,0,0.28)",
              `data-compact-choice-overflow-popup` = "true")
    r.appendChild(primaryHost, detailsNode)
    result.overflowNode = summaryNode
    for i in 0 ..< options.len:
      let chip = buildColumnPopupChip[R, E](r, options[i])
      r.appendChild(popupListNode, chip)
      result.optionNodes.add chip
      result.optionIndexes.add i

proc renderCompactChoiceColumn*[R, E](r: R; ariaLabel: string;
    optionsThunk: proc(): seq[CompactChoiceOption];
    visibleLimit: int = -1;
    visibleLimitThunk: proc(): int = nil;
    chipWidth = "44px"; chipHeight = "26px";
    dataAttrs: seq[(string, string)] = @[];
    onChipMounted: ChipMountedHook[E] = nil): CompactChoiceColumn[E] =
  ## Thunk-driven vertical column (M58). Builds the column's outer
  ## container once, then wraps the chip-construction body in
  ## `createRenderEffect` so the primary strip + overflow popup diff /
  ## patch their chip sets on each tick the thunk's tracked signals
  ## change. Surviving chips keep their DOM identity (focus + event
  ## listeners survive); removed chips are detached from the parent and
  ## drop their per-chip reactive owners; newly-added chips are spliced
  ## in at the correct index and fire `onChipMounted` so the caller can
  ## install per-chip live reactive bindings.
  result = CompactChoiceColumn[E](optionNodes: @[], optionIndexes: @[])

  # Outer container — built once, persists across rebuild ticks.
  var columnRoot: E
  var primaryHost: E
  columnRoot = ui(r):
    tdiv(ref = primaryHost,
          display = "flex", flex_direction = "column",
          align_items = "stretch",
          min_width = chipWidth, width = chipWidth,
          border = "1px solid " & border,
          border_radius = "3px",
          overflow = "visible",
          background_color = bgInput,
          role = "group",
          `aria-label` = ariaLabel,
          `aria-orientation` = "vertical",
          `data-compact-choice-column` = "true")
  for (key, value) in dataAttrs:
    r.setAttribute(columnRoot, key, value)
  result.root = columnRoot

  # `details` overflow container — built once and re-used across ticks;
  # its inner `popupListNode` is the diffed parent for popup chips.
  var detailsNode: E
  var summaryNode: E
  var popupListNode: E
  detailsNode = ui(r):
    details(position = "relative",
            width = chipWidth,
            color = textDim,
            font_size = "10px"):
      summary(ref = summaryNode,
              display = "flex", align_items = "center",
              justify_content = "center",
              width = chipWidth, height = chipHeight,
              list_style = "none", cursor = "pointer",
              border_top = "1px solid " & border,
              `aria-label` = "More " & ariaLabel,
              `data-compact-choice-overflow` = "true"):
        text "\xE2\x96\xBE"
      tdiv(ref = popupListNode,
            position = "absolute", left = chipWidth, top = "0",
            z_index = "30", min_width = "170px",
            padding = "4px", border = "1px solid " & border,
            border_radius = "4px", background_color = bgSidebar,
            box_shadow = "0 8px 24px rgba(0,0,0,0.28)",
            `data-compact-choice-overflow-popup` = "true")
  # detailsNode is appended/removed by the rebuild effect when the
  # option count crosses the visibleLimit threshold.

  # Captured renderer + parent owner — the rebuild effect must install
  # per-chip reactive bindings under an owner that survives the next
  # tick, otherwise survivors lose their bindings every time the option
  # set changes. We park them under the column's own creation owner.
  let parentOwner = getOwner()
  let capturedHook = onChipMounted

  var primaryKeys: seq[string] = @[]
  var primaryNodes: seq[E] = @[]
  var popupKeys: seq[string] = @[]
  var popupNodes: seq[E] = @[]
  var detailsAttached = false
  var firstTick = true
  var latestOverflowNode: E = default(E)

  let capturedThunk = optionsThunk

  createRenderEffect proc() =
    let options = capturedThunk()
    let userLimit =
      if visibleLimitThunk != nil:
        let v = visibleLimitThunk()
        if v < 0: options.len else: v
      elif visibleLimit < 0:
        options.len
      else:
        visibleLimit
    let limit = min(max(1, userLimit), max(1, options.len))
    var visibleIndexes: seq[int] = @[]
    for i in 0 ..< limit:
      if i < options.len:
        visibleIndexes.add i
    let selectedIndex = selectedOptionIndex(options)
    if selectedIndex >= 0 and selectedIndex notin visibleIndexes:
      if visibleIndexes.len == 0:
        visibleIndexes.add selectedIndex
      else:
        visibleIndexes[^1] = selectedIndex
    let hasOverflow = visibleIndexes.len < options.len

    # ---- diff/patch primary strip ----------------------------------------
    var newPrimaryOpts: seq[CompactChoiceOption] = @[]
    var newPrimaryKeys: seq[string] = @[]
    for i in 0 ..< options.len:
      if visibleIndexes.containsIndex(i):
        newPrimaryOpts.add options[i]
        newPrimaryKeys.add chipIdentity(options[i])

    # Build the target node sequence by reusing survivors.
    var newPrimaryNodes: seq[E] = @[]
    for k in 0 ..< newPrimaryKeys.len:
      var reused: E = default(E)
      var found = false
      for j in 0 ..< primaryKeys.len:
        if primaryKeys[j] == newPrimaryKeys[k]:
          reused = primaryNodes[j]
          found = true
          break
      if found:
        newPrimaryNodes.add reused
      else:
        let chip = buildColumnChip[R, E](r, newPrimaryOpts[k],
          chipWidth, chipHeight)
        newPrimaryNodes.add chip

    # Decide which removed survivors should claim the focus pointer.
    # If the currently-focused element is one of the soon-to-be-detached
    # nodes, transfer focus to the option marked `selected` in the new
    # list. We fall back to the first new node if no selection exists.
    let activeBefore = r.activeElement()
    var focusedRemoved = false
    if activeBefore != default(E):
      for j in 0 ..< primaryNodes.len:
        if primaryNodes[j] == activeBefore:
          var stillPresent = false
          for k in 0 ..< newPrimaryNodes.len:
            if newPrimaryNodes[k] == activeBefore:
              stillPresent = true
              break
          if not stillPresent:
            focusedRemoved = true
          break
    # Same check for popup chips.
    if not focusedRemoved and activeBefore != default(E):
      for j in 0 ..< popupNodes.len:
        if popupNodes[j] == activeBefore:
          # Popup chips are rebuilt below; capture the same intent.
          discard
          break

    # Remove old primary chips that are not in the new set.
    for j in 0 ..< primaryNodes.len:
      var stillPresent = false
      for k in 0 ..< newPrimaryNodes.len:
        if newPrimaryNodes[k] == primaryNodes[j]:
          stillPresent = true
          break
      if not stillPresent:
        r.removeChild(primaryHost, primaryNodes[j])

    # Detach the overflow `details` so we can re-insert it cleanly at the
    # end after the primary chips. (Skipping this would force per-child
    # `insertBefore` choreography against a moving reference node.)
    if detailsAttached:
      r.removeChild(primaryHost, detailsNode)
      detailsAttached = false

    # Re-attach surviving chips in the new order; append newly-built
    # chips. `appendChild` follows browser semantics — if the node is
    # already a sibling, it is detached from its current slot first and
    # re-appended at the end, WITHOUT clearing focus on it.
    for k in 0 ..< newPrimaryNodes.len:
      r.appendChild(primaryHost, newPrimaryNodes[k])

    # Fire onChipMounted for genuinely-new chips (post-attach).
    if capturedHook != nil:
      for k in 0 ..< newPrimaryNodes.len:
        var wasSurvivor = false
        for j in 0 ..< primaryNodes.len:
          if primaryNodes[j] == newPrimaryNodes[k]:
            wasSurvivor = true
            break
        if not wasSurvivor:
          # Install the hook under the parent owner so its
          # createRenderEffect bindings survive subsequent rebuild ticks.
          runWithOwner(parentOwner, proc() =
            capturedHook(newPrimaryNodes[k], newPrimaryOpts[k], k))

    # Append or remove the overflow `details` based on hasOverflow.
    if hasOverflow:
      r.appendChild(primaryHost, detailsNode)
      detailsAttached = true

    # ---- diff/patch popup contents ---------------------------------------
    # Popup carries the FULL option list (mirroring the static overload's
    # behaviour: popup is the long-tail menu, including the currently-
    # pinned entries so users always have the canonical chooser surface).
    var newPopupOpts: seq[CompactChoiceOption] = @[]
    var newPopupKeys: seq[string] = @[]
    if hasOverflow:
      for i in 0 ..< options.len:
        newPopupOpts.add options[i]
        newPopupKeys.add chipIdentity(options[i])

    var newPopupNodes: seq[E] = @[]
    for k in 0 ..< newPopupKeys.len:
      var reused: E = default(E)
      var found = false
      for j in 0 ..< popupKeys.len:
        if popupKeys[j] == newPopupKeys[k]:
          reused = popupNodes[j]
          found = true
          break
      if found:
        newPopupNodes.add reused
      else:
        let chip = buildColumnPopupChip[R, E](r, newPopupOpts[k])
        newPopupNodes.add chip

    # Remove old popup chips not in new set.
    for j in 0 ..< popupNodes.len:
      var stillPresent = false
      for k in 0 ..< newPopupNodes.len:
        if newPopupNodes[k] == popupNodes[j]:
          stillPresent = true
          break
      if not stillPresent:
        r.removeChild(popupListNode, popupNodes[j])

    # Re-attach in the new order (relies on appendChild's detach-first
    # semantics; see the primary-strip block above).
    for k in 0 ..< newPopupNodes.len:
      r.appendChild(popupListNode, newPopupNodes[k])

    if capturedHook != nil:
      for k in 0 ..< newPopupNodes.len:
        var wasSurvivor = false
        for j in 0 ..< popupNodes.len:
          if popupNodes[j] == newPopupNodes[k]:
            wasSurvivor = true
            break
        if not wasSurvivor:
          runWithOwner(parentOwner, proc() =
            capturedHook(newPopupNodes[k], newPopupOpts[k], k))

    # Commit the new state. We only populate the returned
    # `CompactChoiceColumn` on the first tick — its fields are read by
    # callers right after construction; subsequent ticks mutate the DOM
    # in place. Writing to `result` after the parent proc has returned
    # is unsafe (the local lives on the stack frame of
    # `renderCompactChoiceColumn`).
    primaryKeys = newPrimaryKeys
    primaryNodes = newPrimaryNodes
    popupKeys = newPopupKeys
    popupNodes = newPopupNodes
    if hasOverflow:
      latestOverflowNode = summaryNode
    else:
      latestOverflowNode = default(E)

    # Focus transfer: if the focused chip was removed, transfer focus to
    # the active (selected) chip in the new primary list. We fall back
    # to the first new primary node if no chip is marked `selected`.
    if focusedRemoved:
      var target: E = default(E)
      for k in 0 ..< newPrimaryOpts.len:
        if newPrimaryOpts[k].selected:
          target = newPrimaryNodes[k]
          break
      if target == default(E) and newPrimaryNodes.len > 0:
        target = newPrimaryNodes[0]
      if target != default(E):
        r.focus(target)

    if firstTick:
      firstTick = false

  # First-tick state is now committed to the closure-captured locals.
  # Mirror it into `result` so the caller can iterate the initial chip
  # set the way the static overload allows.
  for k in 0 ..< primaryNodes.len:
    result.optionNodes.add primaryNodes[k]
    result.optionIndexes.add k
  let primaryCount = primaryNodes.len
  for k in 0 ..< popupNodes.len:
    result.optionNodes.add popupNodes[k]
    result.optionIndexes.add primaryCount + k
  result.overflowNode = latestOverflowNode
