## REV-M2: Brief tab — design-review brief surface inside the preview
## pane.
##
## Render-only: lists every brief covering the active story+backend,
## renders the active brief's frontmatter as colour-coded chips, and
## renders its markdown body to HTML. No editing affordances (those are
## explicitly out of scope per REV-M2).
##
## This module is dogfooded: every visual element is constructed via
## the ``ui:`` DSL. No raw ``setStyle`` call appears anywhere — the
## ``test_brief_tab_view_uses_ui_dsl_not_setstyle`` lexer scan asserts
## this invariant in CI.

import std/[options, strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/markdown
import isonim/editor/types

export brief_format.Brief, brief_format.BriefKind, brief_format.BriefViewport,
       brief_format.BriefScoringDimension, brief_format.BriefPreviewCoverage,
       brief_format.canonicalPreviewId

type
  BriefChipKind* = enum
    bckKind        ## "Brief kind" chip (render / interaction / ...)
    bckCount       ## "Covers N previews" chip
    bckViewport    ## One chip per capture viewport
    bckDimension   ## One chip per scoring dimension (carries the weight)

  BriefChip* = object
    label*: string
    value*: string
    kind*: BriefChipKind

  ReviewPromptDispatcher* = proc(prompt: string) {.closure.}
    ## Closure invoked when the "Review this preview" button is
    ## clicked.  Wired by the consumer (the editor shell) to a real
    ## ``AgentChatVM.sendAgentPrompt`` invocation; left ``nil`` when
    ## the consumer doesn't want to surface the button (eg. in the
    ## VM-level tests).

  BriefTabVM* = ref object
    index*: BriefIndex
    activeStory*: Signal[Option[StoryRef]]
    activeBackend*: Signal[PreviewBackend]
    briefTabVisible*: Signal[bool]
    availableBriefs*: Signal[seq[Brief]]
    activeBriefIndex*: Signal[int]
    activeBrief*: Memo[Option[Brief]]
    rendered*: Memo[string]
    chips*: Memo[seq[BriefChip]]
    ## Phase C: agent-driven review hook.  See ``ReviewPromptDispatcher``.
    reviewDispatcher*: ReviewPromptDispatcher
    reviewButtonEnabled*: Signal[bool]
    reviewButtonTooltip*: Signal[string]
    lastSubmittedReviewPrompt*: Signal[string]
      ## Test hook: the last prompt the button emitted, so VM tests
      ## can assert on its contents without round-tripping through the
      ## daemon.

# --------------------------------------------------------------------------- #
#  Pure helpers (testable independently of the reactive plumbing).
# --------------------------------------------------------------------------- #

proc kindLabel*(k: BriefKind): string =
  case k
  of bkRender:        "render"
  of bkInteraction:   "interaction"
  of bkAccessibility: "accessibility"
  of bkCopy:          "copy"
  of bkChrome:        "chrome"
  of bkComponent:     "component"
  of bkFoundation:    "foundation"
  of bkPattern:       "pattern"
  of bkVectorSymbol:  "vectorsymbol"
  of bkGuideline:     "guideline"

proc availableBriefsFor*(index: BriefIndex; story: Option[StoryRef];
                        backend: PreviewBackend): seq[Brief] =
  ## Look up briefs covering ``(story, backend)``. Order matches
  ## ``BriefIndex.byPreview`` (alphabetical by briefId).
  result = @[]
  if index == nil or story.isNone:
    return
  let previewId = canonicalPreviewId(story.get, backend)
  if previewId notin index.byPreview:
    return
  for id in index.byPreview[previewId]:
    if id in index.byBriefId:
      result.add(index.byBriefId[id])

proc chipsFor*(b: Brief): seq[BriefChip] =
  ## Build the chip strip for one brief.
  result = @[]
  result.add BriefChip(kind: bckKind, label: "Kind", value: kindLabel(b.kind))
  result.add BriefChip(kind: bckCount, label: "Covers",
                       value: $b.coversPreviews.len & " preview" &
                              (if b.coversPreviews.len == 1: "" else: "s"))
  for vp in b.captureViewports:
    let extent = $vp.width & "x" & $vp.height
    let label = if vp.label.len > 0: vp.label else: extent
    result.add BriefChip(kind: bckViewport, label: label, value: extent)
  for d in b.scoringDimensions:
    result.add BriefChip(kind: bckDimension,
                         label: d.label,
                         value: formatFloat(d.weight, ffDecimal, 2))

proc stripFrontmatterBody*(b: Brief): string =
  ## ``Brief.bodyMarkdown`` already excludes the ``---`` delimiters
  ## (the parser splits before populating the field).  We still trim
  ## leading/trailing whitespace so the rendered HTML doesn't carry an
  ## empty leading paragraph.
  result = b.bodyMarkdown.strip()

proc renderBriefBody*(b: Brief): string =
  ## Public so the e2e tests can compute the expected HTML for the
  ## ``test_brief_tab_vm_strips_frontmatter_from_body`` assertion.
  renderMarkdown(stripFrontmatterBody(b))

proc buildReviewPrompt*(b: Brief; story: StoryRef;
                        backend: PreviewBackend;
                        latestCaptureSha = ""): string =
  ## Compose the context-loaded prompt for the "Review this preview"
  ## button.  The shape matches the spec:
  ##
  ##   "Review the preview I'm currently looking at.
  ##    Brief: <bodyMarkdown>.
  ##    Story: <storyRef>.
  ##    Captured at: <sha>.
  ##    Score per the rubric in the brief."
  ##
  ## Kept as a pure proc so VM-level tests can call it directly.
  let storyRef = canonicalPreviewId(story, backend)
  let body = stripFrontmatterBody(b)
  var rubric = ""
  for d in b.scoringDimensions:
    rubric.add("- " & d.label & " (weight " &
               formatFloat(d.weight, ffDecimal, 2) & ")\n")
  result = "Review the preview I'm currently looking at."
  result.add "\n\n## Brief\n\n"
  result.add body
  result.add "\n\n## Story\n\n"
  result.add storyRef
  if latestCaptureSha.len > 0:
    result.add "\n\n## Captured at\n\n"
    result.add latestCaptureSha
  result.add "\n\n## Scoring\n\n"
  if rubric.len > 0:
    result.add rubric
  else:
    result.add "Score per the rubric in the brief.\n"
  result.add "\nScore per the rubric in the brief."

# --------------------------------------------------------------------------- #
#  Constructor — wires the signal graph.
# --------------------------------------------------------------------------- #

proc createBriefTabVM*(index: BriefIndex;
                       activeStory: Signal[Option[StoryRef]];
                       activeBackend: Signal[PreviewBackend]): BriefTabVM =
  let vm = BriefTabVM(
    index: index,
    activeStory: activeStory,
    activeBackend: activeBackend,
    briefTabVisible: createSignal(false),
    availableBriefs: createSignal[seq[Brief]](@[]),
    activeBriefIndex: createSignal(0),
    reviewButtonEnabled: createSignal(true),
    reviewButtonTooltip: createSignal(""),
    lastSubmittedReviewPrompt: createSignal("")
  )

  # ``availableBriefs`` is recomputed whenever the active story or
  # backend changes. We do that inside a render effect so signal writes
  # propagate to downstream memos (``activeBrief``, ``rendered``, etc.).
  let capturedVm = vm
  createRenderEffect proc() =
    let story = capturedVm.activeStory.val
    let backend = capturedVm.activeBackend.val
    let briefs = availableBriefsFor(capturedVm.index, story, backend)
    capturedVm.availableBriefs.val = briefs
    capturedVm.briefTabVisible.val = briefs.len > 0
    # Clamp the active index back into bounds when the brief set shrinks.
    if capturedVm.activeBriefIndex.val >= briefs.len:
      capturedVm.activeBriefIndex.val = 0

  vm.activeBrief = createMemo[Option[Brief]] proc(): Option[Brief] =
    let briefs = capturedVm.availableBriefs.val
    if briefs.len == 0:
      return none[Brief]()
    let idx = capturedVm.activeBriefIndex.val
    let clamped = if idx < 0: 0
                  elif idx >= briefs.len: 0
                  else: idx
    some(briefs[clamped])

  vm.rendered = createMemo[string] proc(): string =
    let active = capturedVm.activeBrief.val
    if active.isNone:
      return ""
    renderBriefBody(active.get)

  vm.chips = createMemo[seq[BriefChip]] proc(): seq[BriefChip] =
    let active = capturedVm.activeBrief.val
    if active.isNone:
      return @[]
    chipsFor(active.get)

  vm

# --------------------------------------------------------------------------- #
#  View — ui DSL only. No setStyle calls.
# --------------------------------------------------------------------------- #

const
  brTabBg          = "#0F172A"
  brTabPanelBg     = "#111827"
  brTabBorder      = "#334155"
  brTabBorderFaint = "#1E293B"
  brTabAccent      = "#7C7AED"
  brTabAccentMuted = "#475569"
  brTabTextPrimary = "#F1F5F9"
  brTabTextMuted   = "#94A3B8"
  brTabTextDim     = "#64748B"
  brTabChipKind    = "#2563EB"
  brTabChipCount   = "#0EA5E9"
  brTabChipVp      = "#22C55E"
  brTabChipDim     = "#A855F7"

proc chipBg(kind: BriefChipKind): string =
  case kind
  of bckKind:      brTabChipKind
  of bckCount:     brTabChipCount
  of bckViewport:  brTabChipVp
  of bckDimension: brTabChipDim

proc previewIdFromActive(vm: BriefTabVM): string =
  let story = vm.activeStory.val
  if story.isNone:
    return ""
  canonicalPreviewId(story.get, vm.activeBackend.val)

proc submitReviewPrompt*(vm: BriefTabVM): bool {.discardable.} =
  ## Build the context-loaded review prompt and dispatch it through
  ## ``vm.reviewDispatcher``.  Returns ``false`` when there is no
  ## active brief or no dispatcher wired.  The composed prompt is
  ## cached in ``vm.lastSubmittedReviewPrompt`` so tests can assert
  ## on its contents.
  let active = vm.activeBrief.val
  if active.isNone:
    return false
  let story = vm.activeStory.val
  if story.isNone:
    return false
  let prompt = buildReviewPrompt(active.get, story.get, vm.activeBackend.val)
  vm.lastSubmittedReviewPrompt.val = prompt
  if vm.reviewDispatcher == nil:
    return false
  vm.reviewDispatcher(prompt)
  true

proc mountBriefTab*[R, E](r: R; parent: E; vm: BriefTabVM) =
  ## Mount the brief tab DOM under ``parent``. The brief tab is a
  ## self-contained block with its own header, sub-tab strip (for
  ## multi-brief coverage), chip strip, and rendered markdown body.
  let capturedVm = vm

  var subTabsHost: E
  var chipStripHost: E
  var bodyHost: E
  var emptyHost: E
  var previewIdValueNode: E
  var copyButtonNode: E
  var reviewButtonNode: E
  var reviewActionsHost: E

  let root = ui(r):
    tdiv(
      `data-design-review-brief-tab` = "true",
      display = "flex", flex_direction = "column",
      gap = "12px", padding = "12px 16px",
      background_color = brTabBg,
      border = "1px solid " & brTabBorder,
      border_radius = "8px",
      color = brTabTextPrimary,
      min_width = "0", min_height = "0",
      max_height = "100%", overflow_y = "auto"):
      # --- Header / "tab" label ----------------------------------------
      tdiv(display = "flex", flex_direction = "row", align_items = "center",
            gap = "8px",
            `data-design-review-brief-header` = "true"):
        span(font_size = "10px", font_weight = "700",
              text_transform = "uppercase", letter_spacing = "0.4px",
              color = brTabAccent):
          text "Brief"
        span(font_size = "11px", color = brTabTextMuted):
          text "for the selected preview"
      # --- Sub-tab strip (shown only when multiple briefs cover) ------
      tdiv(
        ref = subTabsHost,
        display = "flex", flex_direction = "row", flex_wrap = "wrap",
        gap = "6px", min_height = "26px",
        `data-design-review-brief-subtabs` = "true",
        `role` = "tablist",
        `aria-label` = "Briefs covering this preview")
      # --- Chip strip --------------------------------------------------
      tdiv(
        ref = chipStripHost,
        display = "flex", flex_direction = "row", flex_wrap = "wrap",
        gap = "6px",
        `data-design-review-brief-chips` = "true")
      # --- Body container ---------------------------------------------
      tdiv(
        ref = bodyHost,
        display = "flex", flex_direction = "column",
        padding = "12px 14px",
        background_color = brTabPanelBg,
        border = "1px solid " & brTabBorderFaint,
        border_radius = "6px",
        font_size = "13px", line_height = "1.55",
        color = brTabTextPrimary,
        `data-design-review-brief-body` = "true")
      # --- Review-this-preview actions (Phase C) ----------------------
      tdiv(
        ref = reviewActionsHost,
        display = "flex", flex_direction = "row",
        align_items = "center", justify_content = "flex-end",
        gap = "8px", padding = "4px 0px",
        `data-design-review-brief-actions` = "true"):
        tdiv(
          ref = reviewButtonNode,
          `role` = "button", tabindex = "0",
          `aria-label` = "Review this preview",
          `data-design-review-review-button` = "true",
          padding = "6px 12px",
          font_size = "11px", font_weight = "700",
          text_transform = "uppercase", letter_spacing = "0.4px",
          color = brTabTextPrimary,
          background_color = brTabAccent,
          border = "1px solid " & brTabAccent,
          border_radius = "4px",
          cursor = "pointer"):
          text "Review this preview"
      # --- Empty-state container --------------------------------------
      tdiv(
        ref = emptyHost,
        display = "flex", flex_direction = "column",
        align_items = "stretch", gap = "8px",
        padding = "16px",
        background_color = brTabPanelBg,
        border = "1px dashed " & brTabBorder,
        border_radius = "6px",
        color = brTabTextMuted,
        font_size = "12px",
        `data-design-review-brief-empty` = "true"):
        span(font_weight = "600", color = brTabTextPrimary):
          text "No brief covers this preview yet"
        span(font_size = "11px", line_height = "1.5",
              color = brTabTextMuted):
          text "Create a brief under briefs/<kind>/<slug>.md whose " &
               "coversPreviews entry names the storyRef + backend below."
        tdiv(display = "flex", flex_direction = "row", align_items = "center",
              gap = "6px",
              `data-design-review-brief-empty-actions` = "true"):
          span(font_size = "10px", text_transform = "uppercase",
                letter_spacing = "0.4px", font_weight = "700",
                color = brTabTextDim):
            text "Preview id"
          tdiv(ref = previewIdValueNode,
                font_family = "monospace", font_size = "11px",
                color = brTabTextPrimary, padding = "3px 6px",
                background_color = brTabBg,
                border = "1px solid " & brTabBorderFaint,
                border_radius = "4px",
                `data-design-review-brief-preview-id-value` = "true"):
            text ""
          tdiv(
            ref = copyButtonNode,
            `role` = "button", tabindex = "0",
            `aria-label` = "Copy storyRef",
            `data-design-review-brief-copy` = "true",
            padding = "4px 8px",
            font_size = "10px", font_weight = "600",
            text_transform = "uppercase", letter_spacing = "0.4px",
            color = brTabTextPrimary,
            background_color = brTabAccentMuted,
            border = "1px solid " & brTabBorder,
            border_radius = "4px",
            cursor = "pointer"):
            text "Copy"

  # --- Reactive: visibility flags --------------------------------------
  createRenderEffect proc() =
    let visible = capturedVm.briefTabVisible.val
    r.setAttribute(root, "data-design-review-brief-visible",
                   if visible: "true" else: "false")
    r.setAttribute(subTabsHost, "data-design-review-visible",
                   if visible: "true" else: "false")
    r.setAttribute(chipStripHost, "data-design-review-visible",
                   if visible: "true" else: "false")
    r.setAttribute(bodyHost, "data-design-review-visible",
                   if visible: "true" else: "false")
    r.setAttribute(emptyHost, "data-design-review-visible",
                   if visible: "false" else: "true")

  # --- Reactive: sub-tab strip --------------------------------------------
  proc syncSubTabs() =
    r.clearChildren(subTabsHost)
    let briefs = capturedVm.availableBriefs.val
    let active = capturedVm.activeBriefIndex.val
    if briefs.len <= 1:
      return
    for idx, b in briefs:
      let isActive = idx == active
      let capturedIdx = idx
      let chip = ui(r):
        tdiv(
          `role` = "tab", tabindex = "0",
          `data-design-review-brief-subtab` = b.briefId,
          `aria-selected` = (if isActive: "true" else: "false"),
          `aria-label` = "Select brief " & b.briefId,
          padding = "4px 10px",
          font_size = "11px",
          font_weight = (if isActive: "700" else: "500"),
          color = (if isActive: brTabTextPrimary else: brTabTextMuted),
          background_color = (if isActive: brTabAccent else: brTabPanelBg),
          border = "1px solid " &
            (if isActive: brTabAccent else: brTabBorderFaint),
          border_radius = "4px",
          cursor = "pointer"):
          text b.briefId
      r.addEventListener(chip, "click", proc() =
        capturedVm.activeBriefIndex.val = capturedIdx)
      r.addEventListener(chip, "keydown", proc() =
        capturedVm.activeBriefIndex.val = capturedIdx)
      r.appendChild(subTabsHost, chip)

  syncSubTabs()
  createRenderEffect proc() =
    syncSubTabs()

  # --- Reactive: chip strip ------------------------------------------------
  proc syncChips() =
    r.clearChildren(chipStripHost)
    for chip in capturedVm.chips.val:
      let chipKind = chip.kind
      let chipLabel = chip.label
      let chipValue = chip.value
      let chipColor = chipBg(chipKind)
      let chipKindStr = $chipKind
      let chipNode = ui(r):
        tdiv(
          `data-design-review-brief-chip` = chipKindStr,
          display = "inline-flex", flex_direction = "row",
          align_items = "center", gap = "6px",
          padding = "3px 8px",
          font_size = "10px",
          color = brTabTextPrimary,
          background_color = chipColor,
          border_radius = "999px",
          font_weight = "600",
          letter_spacing = "0.2px"):
          span(text_transform = "uppercase",
                letter_spacing = "0.4px",
                opacity = "0.85"):
            text chipLabel
          span(font_size = "10px",
                font_weight = "700"):
            text chipValue
      r.appendChild(chipStripHost, chipNode)

  syncChips()
  createRenderEffect proc() =
    syncChips()

  # --- Reactive: rendered body --------------------------------------------
  createRenderEffect proc() =
    r.setInnerHtml(bodyHost, capturedVm.rendered.val)

  # --- Reactive: preview-id label for the empty state ---------------------
  createRenderEffect proc() =
    let id = previewIdFromActive(capturedVm)
    r.setTextContent(previewIdValueNode, id)
    r.setAttribute(previewIdValueNode,
                   "data-design-review-brief-preview-id", id)

  # --- Copy-preview-id button (clipboard write where available) ----------
  let copyHandler = proc() =
    let id = previewIdFromActive(capturedVm)
    when defined(js):
      let payload = id.cstring
      {.emit: ["""
        try {
          if (typeof navigator !== 'undefined' && navigator.clipboard) {
            navigator.clipboard.writeText(""", payload, """);
          }
        } catch (e) { /* clipboard unavailable - ignore */ }
      """].}
    else:
      discard id
  r.addEventListener(copyButtonNode, "click", copyHandler)
  r.addEventListener(copyButtonNode, "keydown", copyHandler)

  # --- Review-this-preview button (Phase C) -----------------------------
  let reviewHandler = proc() =
    if not capturedVm.reviewButtonEnabled.val: return
    discard submitReviewPrompt(capturedVm)
  r.addEventListener(reviewButtonNode, "click", reviewHandler)
  r.addEventListener(reviewButtonNode, "keydown", reviewHandler)

  # Reactive: hide the button when no brief is active; toggle disabled
  # styling when the daemon is unreachable.
  createRenderEffect proc() =
    let active = capturedVm.activeBrief.val
    let visible = active.isSome
    let enabled = capturedVm.reviewButtonEnabled.val
    r.setAttribute(reviewActionsHost, "data-design-review-visible",
                   if visible: "true" else: "false")
    r.setAttribute(reviewButtonNode, "data-design-review-enabled",
                   if enabled: "true" else: "false")
    r.setAttribute(reviewButtonNode, "aria-disabled",
                   if enabled: "false" else: "true")
    let tooltip = capturedVm.reviewButtonTooltip.val
    if tooltip.len > 0:
      r.setAttribute(reviewButtonNode, "title", tooltip)

  r.appendChild(parent, root)
