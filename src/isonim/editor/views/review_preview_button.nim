## CHRM-M2 — "Review this preview" chrome-bar trailing-edge button.
##
## The in-pane Preview/Brief tab strip was removed in CHRM-M2 (the
## chrome-bar Surface switch + TipTap spec pane cover the brief-viewing
## affordance already). The strip's one load-bearing sub-feature — the
## "Review this preview" button that dispatches a context-loaded prompt
## to the AI Assistant — survives, surfaced here as a chrome-bar
## trailing-edge button placed immediately before the 🕘 history
## button.
##
## Visibility predicate (mirrors the deleted in-pane button):
##   * Hidden when no brief covers ``(selectedStory, platform)``.
##   * Disabled with tooltip when the daemon connection state is
##     ``"failed"`` (matches ``preview_pane.nim:71-79`` from before).
##
## Dispatch: builds the prompt via
## ``design_review/review_prompt.buildReviewPrompt``, writes
## ``vm.chat.inputText``, then calls ``vm.sendAgentPrompt()``. Same path
## the deleted in-pane button used.

import std/[options, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/brief_index_static
import isonim/editor/design_review/review_prompt

# Visual tokens — match the chrome-bar history button so the two
# trailing-edge affordances read as a single group.
const
  rpAccent = "#7C7AED"
  rpText   = "#FFFFFF"
  rpBorder = "#6F6DD9"

proc activeBriefFor*(vm: EditorVM): Option[Brief] =
  ## Pure helper — looks up the brief covering the active
  ## ``(selectedStory, platform)`` pair. Returns ``none`` when no brief
  ## matches (the button is hidden in that case).
  let idx = builtInBriefIndex()
  if idx == nil or idx.empty():
    return none[Brief]()
  let story = vm.selectedStory.val
  if story.name.len == 0:
    return none[Brief]()
  let previewId = canonicalPreviewId(story, vm.platform.val)
  if previewId notin idx.byPreview:
    return none[Brief]()
  let candidates = idx.byPreview[previewId]
  # Prefer a render-kind brief when multiple cover the same preview —
  # matches the ``design_review_mount.resolveBriefId`` ordering so the
  # button + the spec pane resolve to the same brief.
  for id in candidates:
    if id in idx.byBriefId and idx.byBriefId[id].kind == bkRender:
      return some(idx.byBriefId[id])
  for id in candidates:
    if id in idx.byBriefId:
      return some(idx.byBriefId[id])
  none[Brief]()

proc composeAndDispatchReviewPrompt*(vm: EditorVM): bool {.discardable.} =
  ## Build the context-loaded review prompt and dispatch it through
  ## ``vm.chat`` + ``vm.sendAgentPrompt``. Returns ``false`` when no
  ## brief covers the active story (button click is a no-op then).
  let active = activeBriefFor(vm)
  if active.isNone:
    return false
  let story = vm.selectedStory.val
  let prompt = buildReviewPrompt(active.get, story, vm.platform.val)
  vm.chat.inputText.val = prompt
  discard vm.sendAgentPrompt()
  true

proc mountReviewPreviewButton*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Mount the trailing-edge "Review this preview" button onto
  ## ``parent`` (the chrome-bar toolbar). The button reactively hides
  ## itself when no brief covers the active story.
  let capturedVm = vm

  let button = ui(r):
    tdiv(
      `role` = "button",
      tabindex = "0",
      `aria-label` = "Review this preview",
      `data-chrome-action` = "review-preview",
      `data-preview-chrome-review-button` = "true",
      display = "inline-flex",
      align_items = "center",
      justify_content = "center",
      height = "26px",
      padding = "0 10px",
      margin_left = "6px",
      font_size = "11px",
      font_weight = "600",
      color = rpText,
      background_color = rpAccent,
      border = "1px solid " & rpBorder,
      border_radius = "4px",
      cursor = "pointer",
      user_select = "none",
      letter_spacing = "0.2px",
      white_space = "nowrap"):
      text "Review"

  # Disabled-state signal — read by the click handler so the live
  # connectionState short-circuits the dispatch without poking the DOM
  # back. (The reactive effect below mirrors the same value onto the
  # ``aria-disabled`` attribute for screen readers.)
  let isUnavailable = createSignal(false)

  proc activate() =
    if isUnavailable.val:
      return
    discard composeAndDispatchReviewPrompt(capturedVm)

  r.addEventListener(button, "click", activate)
  r.addEventListener(button, "keydown", activate)

  createRenderEffect proc() =
    let visible = activeBriefFor(capturedVm).isSome
    r.setAttribute(button, "data-review-button-visible",
                   if visible: "true" else: "false")
    # Inline display flip so the button collapses without leaving a gap.
    r.setAttribute(button, "style",
      (if visible: "display: inline-flex;"
       else: "display: none;") &
        " align-items: center; justify-content: center;" &
        " height: 26px; padding: 0 10px; margin-left: 6px;" &
        " font-size: 11px; font-weight: 600;" &
        " color: " & rpText & ";" &
        " background-color: " & rpAccent & ";" &
        " border: 1px solid " & rpBorder & ";" &
        " border-radius: 4px; cursor: pointer; user-select: none;" &
        " letter-spacing: 0.2px; white-space: nowrap;")
    r.setAttribute(button, "aria-hidden",
                   if visible: "false" else: "true")
    r.setAttribute(button, "tabindex",
                   if visible: "0" else: "-1")

  # Disabled-state mirror: when the AI chat connection is "failed" the
  # button stays visible but refuses clicks + carries a tooltip
  # explaining why (matches the deleted in-pane button's behaviour).
  createRenderEffect proc() =
    let state = capturedVm.chat.connectionState.val
    let unavailable = state == "failed"
    isUnavailable.val = unavailable
    r.setAttribute(button, "aria-disabled",
                   if unavailable: "true" else: "false")
    r.setAttribute(button, "data-review-button-enabled",
                   if unavailable: "false" else: "true")
    if unavailable:
      r.setAttribute(button, "title",
                     "daemon unavailable - start `isonim-review serve`")
    else:
      r.setAttribute(button, "title", "")

  r.appendChild(parent, button)
