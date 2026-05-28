## Phase K — Notion / Coda / Google Docs-style inline comment overlay.
##
## Mounts an absolute-positioned layer ON TOP of the editor's preview
## surface that surfaces a click-to-place comment anchor + a thread
## popover bound to the existing ``vm.review.annotations`` machinery
## (see REV-M5+).  Reuses the design-review annotation data model —
## anchors authored in Comment mode flow through the same persistence
## pipeline the AI agent already consumes; this widget only renders
## the interaction layer.
##
## Lifecycle:
##
##   * The overlay layer is mounted unconditionally on the parent.
##     Its outermost ``data-comment-overlay`` element toggles between
##     ``display: none`` and ``display: block`` via a reactive effect
##     observing ``vm.editMode``.  When mode != ``emComment`` the
##     anchors are hidden and any open popover collapses; the
##     underlying annotation data is preserved.
##
##   * When mode == ``emComment`` the overlay also lights up an
##     underlay element (``data-comment-overlay-underlay``) with
##     ``pointer-events: auto`` so clicks land on it instead of the
##     iframe / canvas below.  A click on the underlay places a new
##     ``ReviewAnnotation`` at the click's overlay-relative
##     coordinates and auto-opens the thread popover for it.
##
##   * Each annotation renders one ``data-comment-anchor`` marker
##     positioned by its ``anchorX`` / ``anchorY`` slots.  Markers
##     carry a sequential number (1-indexed, in insertion order) so
##     the user can refer to "Comment 3" the same way Google Docs /
##     Notion do.
##
##   * Hovering OR clicking a marker mounts the thread popover next
##     to it.  The popover shows existing comments + a composer +
##     a ``Resolve`` button.  Resolving sets ``state = ransResolved``;
##     the anchor flips to its muted-dot visual.
##
## Styling deliberately mirrors the existing ``spec_comment_chat`` /
## ``spec_comment_popover`` look — same dark-surface background, same
## 1 px hairline border, same 280 px popover width — so the overlay
## reads as a sibling of those affordances rather than a parallel UI.
##
## DSL note: every ``setStyle`` call lives inside a
## ``createRenderEffect`` (or, for the absolute-positioning math that
## changes per-anchor, inside a per-anchor effect).  No raw
## ``setStyle`` runs outside an effect.

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  ## Colour tokens chosen to match the surrounding editor surfaces —
  ## ``shell.nim``'s ``bgSidebar`` / ``borderFaint`` / ``accent`` /
  ## ``accentSoft``.  We duplicate the hex literals here rather than
  ## import shell.nim (which would create a circular dep with the
  ## widget catalogue).
  bgSidebar = "#15161F"
  bgSurface = "#1A1B26"
  borderFaint = "#1F212C"
  borderStrong = "#2F3140"
  textPrimary = "#ECEDF3"
  textMuted = "#6B6F80"
  accent = "#7C7AED"
  accentMuted = "#4B4D62"
  popoverWidth = "280px"

proc anchorIsResolved(annotation: ReviewAnnotation): bool {.inline.} =
  annotation.state == ransResolved

proc mountCommentOverlay*[R, E](r: R; parent: E; vm: EditorVM): E {.
    discardable.} =
  ## Phase K — mount the Notion-style comment overlay layer under
  ## ``parent`` (typically the editor centre column so the overlay
  ## absolute-positions across the active preview without disturbing
  ## the chrome bar or right sidebar).  Returns the overlay root for
  ## tests + caller wiring.
  ##
  ## ``parent`` MUST be a positioned ancestor (``position: relative``
  ## or similar) — otherwise the absolute-positioned overlay layer
  ## falls back to the document body.  ``shell.nim``'s ``centerColumn``
  ## already sets ``position: relative`` (see the AIVS-NSO no-story
  ## overlay) so the contract holds for the canonical mount point.
  let capturedVm = vm

  # --- Track the currently-open popover (anchor id) ----------------
  let openAnchorId = createSignal[string]("")
  # The composer text persists across re-renders of the popover so
  # the user doesn't lose what they typed when a re-render fires.
  let composerText = createSignal[string]("")
  # Click-vs-hover discrimination: a hover-open popover dismisses on
  # mouseleave; a click-open one is sticky until the user clicks
  # outside or hits Resolve.  ``clickSticky`` tracks the sticky bit
  # on the active popover so a mouseleave doesn't slam shut a
  # deliberately-opened thread.
  let clickSticky = createSignal[bool](false)

  var overlayRoot: E
  var underlayEl: E
  var anchorsHostEl: E
  var popoverRootEl: E
  var popoverHeaderEl: E
  var popoverCommentsListEl: E
  var popoverComposerEl: E
  var popoverSendBtn: E
  var popoverResolveBtn: E
  var popoverErrorEl: E

  # ------------------------------------------------------------------
  # DOM skeleton.  The underlay carries the click-to-place handler and
  # sits behind the anchors host; the anchors host paints the markers
  # on top of the underlay so the markers stay clickable even while
  # the underlay catches "empty area" clicks.  The popover is mounted
  # at the same level so its absolute coordinates resolve against the
  # overlay root (not against an individual marker).
  # ------------------------------------------------------------------
  let overlayTree = ui(r):
    tdiv(ref = overlayRoot,
          `data-comment-overlay` = "true",
          position = "absolute",
          left = "0", top = "0", right = "0", bottom = "0",
          display = "none",
          pointer_events = "none",
          z_index = "30"):
      tdiv(ref = underlayEl,
            `data-comment-overlay-underlay` = "true",
            position = "absolute",
            left = "0", top = "0", right = "0", bottom = "0",
            pointer_events = "none",
            cursor = "crosshair")
      tdiv(ref = anchorsHostEl,
            `data-comment-overlay-anchors` = "true",
            position = "absolute",
            left = "0", top = "0", right = "0", bottom = "0",
            pointer_events = "none")
      tdiv(ref = popoverRootEl,
            `data-comment-thread-popover` = "true",
            position = "absolute",
            display = "none",
            flex_direction = "column",
            gap = "8px",
            padding = "10px 12px",
            width = popoverWidth,
            background_color = bgSidebar,
            border = "1px solid " & borderFaint,
            border_radius = "8px",
            box_shadow = "0 8px 28px rgba(0,0,0,0.45)",
            color = textPrimary,
            font_size = "12px",
            pointer_events = "auto",
            z_index = "40"):
        tdiv(display = "flex",
              flex_direction = "row",
              align_items = "center",
              justify_content = "space-between",
              gap = "8px"):
          span(ref = popoverHeaderEl,
                `data-comment-thread-popover-title` = "true",
                font_weight = "600",
                font_size = "12px",
                color = textPrimary):
            text ""
          button(ref = popoverResolveBtn,
                  `data-comment-thread-popover-resolve` = "true",
                  `type` = "button",
                  padding = "3px 8px",
                  border_radius = "4px",
                  border = "1px solid " & borderStrong,
                  background_color = "transparent",
                  color = textMuted,
                  cursor = "pointer",
                  font_size = "11px"):
            text("Resolve")
        tdiv(ref = popoverCommentsListEl,
              `data-comment-thread-popover-comments` = "true",
              display = "flex",
              flex_direction = "column",
              gap = "6px",
              max_height = "180px",
              overflow_y = "auto"):
          discard
        textarea(ref = popoverComposerEl,
                  `data-comment-thread-popover-input` = "true",
                  placeholder = "Reply or add a comment...",
                  rows = "2",
                  resize = "vertical",
                  padding = "6px 8px",
                  background_color = bgSurface,
                  border = "1px solid " & borderStrong,
                  border_radius = "4px",
                  color = textPrimary,
                  font_family = "inherit",
                  font_size = "12px",
                  outline = "none")
        tdiv(ref = popoverErrorEl,
              `data-comment-thread-popover-error` = "true",
              display = "none",
              color = "#FF6B6B",
              font_size = "11px"):
          text ""
        tdiv(display = "flex",
              flex_direction = "row",
              gap = "8px",
              justify_content = "flex-end"):
          button(ref = popoverSendBtn,
                  `data-comment-thread-popover-send` = "true",
                  `type` = "button",
                  padding = "4px 10px",
                  border_radius = "4px",
                  border = "1px solid " & accent,
                  background_color = accent,
                  color = "#FFFFFF",
                  cursor = "pointer",
                  font_size = "11px"):
            text("Send")
  discard overlayTree
  r.appendChild(parent, overlayRoot)

  # ------------------------------------------------------------------
  # Mode reactivity — show / hide the overlay; flip pointer-events on
  # the underlay so click-to-place only intercepts events while the
  # user is in Comment mode.  The anchors themselves stay
  # ``pointer-events: auto`` per-marker so they remain interactive
  # while the overlay is visible.
  # ------------------------------------------------------------------
  createRenderEffect proc() =
    let active = capturedVm.editMode.val == emComment
    if active:
      r.setStyle(overlayRoot, "display", "block")
      r.setStyle(underlayEl, "pointer-events", "auto")
    else:
      r.setStyle(overlayRoot, "display", "none")
      r.setStyle(underlayEl, "pointer-events", "none")
      # Leaving Comment mode dismisses any open popover.  The
      # annotation data itself is preserved via the unchanged
      # ``vm.review.annotations`` signal.
      openAnchorId.val = ""
      clickSticky.val = false

  # ------------------------------------------------------------------
  # Anchor markers — re-render the host on every annotations change.
  # We rebuild the whole anchor host rather than diff individual
  # markers because the per-anchor mounted-effect closure captures the
  # annotation by value; refreshing the host wholesale keeps the
  # signal wiring deterministic and small.
  # ------------------------------------------------------------------
  proc openPopover(id: string; sticky: bool) =
    openAnchorId.val = id
    clickSticky.val = sticky
    # Refresh the composer slot whenever the user opens a different
    # anchor's popover so half-typed text doesn't leak across threads.
    composerText.val = ""

  proc closePopover() =
    openAnchorId.val = ""
    clickSticky.val = false

  createRenderEffect proc() =
    r.clearChildren(anchorsHostEl)
    let annotations = capturedVm.review.annotations.val
    var idx = 0
    for annotation in annotations:
      let capturedAnnotation = annotation
      let resolved = capturedAnnotation.anchorIsResolved()
      let number = idx + 1
      var anchorEl: E
      let resolvedAttr = if resolved: "true" else: "false"
      let markerNode = ui(r):
        tdiv(ref = anchorEl,
              `data-comment-anchor` = capturedAnnotation.id,
              `data-comment-anchor-number` = $number,
              `data-comment-resolved` = resolvedAttr,
              position = "absolute",
              width = "24px",
              height = "24px",
              border_radius = "12px",
              display = "flex",
              align_items = "center",
              justify_content = "center",
              border = "1px solid " & borderFaint,
              cursor = "pointer",
              pointer_events = "auto",
              user_select = "none",
              font_size = "11px",
              font_weight = "600",
              line_height = "1",
              color = "#FFFFFF",
              box_shadow = "0 2px 6px rgba(0,0,0,0.32)"):
          span(`data-comment-anchor-number` = "true",
                pointer_events = "none"):
            text $number
      # Position + colour bound through a render effect so a
      # resolve / move update animates without a remount.
      let captureAnchorEl = anchorEl
      let captureAnnotation = capturedAnnotation
      createRenderEffect proc() =
        let latest = capturedVm.review.annotations.val
        var fresh = captureAnnotation
        for a in latest:
          if a.id == captureAnnotation.id:
            fresh = a
            break
        let isResolved = fresh.anchorIsResolved()
        let bg = if isResolved: accentMuted else: accent
        r.setStyle(captureAnchorEl, "background-color", bg)
        r.setStyle(captureAnchorEl, "opacity",
          if isResolved: "0.55" else: "1.0")
        # The marker shrinks to a muted dot when resolved.
        let dim = if isResolved: "14px" else: "24px"
        r.setStyle(captureAnchorEl, "width", dim)
        r.setStyle(captureAnchorEl, "height", dim)
        r.setStyle(captureAnchorEl, "border-radius",
          if isResolved: "7px" else: "12px")
        # Anchor offset places the marker centred on the click point.
        let halfWidth = if isResolved: 7.0 else: 12.0
        let leftPx = fresh.anchorX - halfWidth
        let topPx = fresh.anchorY - halfWidth
        r.setStyle(captureAnchorEl, "left", $leftPx & "px")
        r.setStyle(captureAnchorEl, "top", $topPx & "px")
        r.setAttribute(captureAnchorEl, "data-comment-resolved",
          if isResolved: "true" else: "false")
      # Hover and click handlers — hover opens an ephemeral popover;
      # click pins it (sticky) so the user can reach the composer
      # without losing focus when the cursor drifts.
      let capturedId = capturedAnnotation.id
      proc onMouseEnter() =
        if capturedVm.editMode.val != emComment:
          return
        if clickSticky.val:
          return
        openPopover(capturedId, sticky = false)
      proc onMouseLeave() =
        if clickSticky.val:
          return
        if openAnchorId.val == capturedId:
          closePopover()
      proc onClick() =
        if capturedVm.editMode.val != emComment:
          return
        openPopover(capturedId, sticky = true)
      r.addEventListener(anchorEl, "mouseenter", onMouseEnter)
      r.addEventListener(anchorEl, "mouseleave", onMouseLeave)
      r.addEventListener(anchorEl, "click", onClick)
      r.appendChild(anchorsHostEl, markerNode)
      inc idx

  # ------------------------------------------------------------------
  # Popover content + visibility binding.  Reads from
  # ``openAnchorId`` + ``vm.review.annotations`` so the popover
  # always reflects the live state of the underlying annotation
  # (which Resolve / addComment mutate directly).
  # ------------------------------------------------------------------
  createRenderEffect proc() =
    let openId = openAnchorId.val
    if openId.len == 0:
      r.setStyle(popoverRootEl, "display", "none")
      return
    let annotations = capturedVm.review.annotations.val
    var found = false
    var hit: ReviewAnnotation
    var anchorNum = 0
    for i, a in annotations:
      if a.id == openId:
        hit = a
        found = true
        anchorNum = i + 1
        break
    if not found:
      r.setStyle(popoverRootEl, "display", "none")
      return
    r.setStyle(popoverRootEl, "display", "flex")
    # Anchor the popover slightly down + right of the marker so it
    # doesn't overlap the click point.  Stay inside the overlay so
    # both coordinates are overlay-relative.
    let leftPx = hit.anchorX + 18.0
    let topPx = hit.anchorY + 18.0
    r.setStyle(popoverRootEl, "left", $leftPx & "px")
    r.setStyle(popoverRootEl, "top", $topPx & "px")
    r.setTextContent(popoverHeaderEl, "Comment " & $anchorNum)
    # Re-render the comments list from the annotation's text +
    # comments fields.  The first comment lives in ``hit.text`` to
    # preserve back-compat with the existing review-annotation flow;
    # replies are in ``hit.comments``.
    r.clearChildren(popoverCommentsListEl)
    if hit.text.len > 0:
      var firstBubble: E
      let bubble = ui(r):
        tdiv(ref = firstBubble,
              `data-comment-thread-popover-comment` = "first",
              padding = "6px 8px",
              background_color = bgSurface,
              border_radius = "4px",
              color = textPrimary,
              font_size = "12px",
              line_height = "1.4",
              white_space = "pre-wrap"):
          text hit.text
      r.appendChild(popoverCommentsListEl, bubble)
    for i, reply in hit.comments:
      var replyEl: E
      let bubble = ui(r):
        tdiv(ref = replyEl,
              `data-comment-thread-popover-comment` = "reply",
              `data-comment-thread-popover-reply-index` = $i,
              padding = "6px 8px",
              background_color = bgSurface,
              border_radius = "4px",
              color = textPrimary,
              font_size = "12px",
              line_height = "1.4",
              white_space = "pre-wrap"):
          text reply.text
      r.appendChild(popoverCommentsListEl, bubble)
    # Resolve button label / colour reflects state.
    if hit.state == ransResolved:
      r.setTextContent(popoverResolveBtn, "Resolved")
      r.setAttribute(popoverResolveBtn, "data-comment-thread-popover-resolved",
        "true")
    else:
      r.setTextContent(popoverResolveBtn, "Resolve")
      r.setAttribute(popoverResolveBtn, "data-comment-thread-popover-resolved",
        "false")

  # Mirror the composer signal into the textarea so refresh / open
  # cycles keep the user's typing in view.  We only push the value
  # back when it diverges so caret position doesn't reset.
  createRenderEffect proc() =
    let text = composerText.val
    when defined(js):
      if r.inputValue(popoverComposerEl) != text:
        r.setInputValue(popoverComposerEl, text)
    else:
      r.setAttribute(popoverComposerEl,
        "data-comment-thread-popover-input-value", text)

  # ------------------------------------------------------------------
  # Underlay click-to-place handler.  Computes overlay-relative
  # coordinates from the click and drops a new annotation through the
  # VM helper.  Under the mock renderer there's no real coordinate
  # payload, so we drop the anchor at (0, 0); browser tests reach the
  # placement-at-coordinates path via ``placeAnchorAt`` to round-trip
  # known coordinates.  The ``{.emit.}`` block below reads ``clientX``
  # / ``clientY`` from the live ``window.event`` (set by the click) so
  # we sidestep the renderer-specific event-arg overload — every
  # editor renderer agrees on the no-arg ``addEventListener`` shape.
  # ------------------------------------------------------------------
  proc onUnderlayClick() =
    if capturedVm.editMode.val != emComment:
      return
    var relX: float = 0.0
    var relY: float = 0.0
    when defined(js):
      let overlayHandle = overlayRoot
      {.emit: ["""
        try {
          var ev = window.event;
          if (ev && """, overlayHandle, """ &&
              """, overlayHandle, """.getBoundingClientRect) {
            var rect = """, overlayHandle, """.getBoundingClientRect();
            """, relX, """ = ev.clientX - rect.left;
            """, relY, """ = ev.clientY - rect.top;
          }
        } catch (e) { /* leave defaults */ }
      """].}
    let newId = capturedVm.addReviewAnnotationAtAnchor(relX, relY)
    if newId.len > 0:
      openPopover(newId, sticky = true)
  r.addEventListener(underlayEl, "click", onUnderlayClick)

  # ------------------------------------------------------------------
  # Composer + Send + Resolve wiring.
  # ------------------------------------------------------------------
  when defined(js):
    proc onComposerInput() =
      composerText.val = r.inputValue(popoverComposerEl)
    r.addEventListener(popoverComposerEl, "input", onComposerInput)

  proc onSendClick() =
    let openId = openAnchorId.val
    if openId.len == 0: return
    let text = composerText.val.strip()
    if text.len == 0: return
    discard capturedVm.review.addCommentToAnnotation(openId, text)
    composerText.val = ""
    # Closing the popover after Send matches the spec's "click outside
    # closes" intuition + gives the user immediate feedback that the
    # comment landed.  The anchor stays visible.
    closePopover()
  r.addEventListener(popoverSendBtn, "click", onSendClick)

  proc onResolveClick() =
    let openId = openAnchorId.val
    if openId.len == 0: return
    discard capturedVm.review.resolveReviewAnnotation(openId)
    closePopover()
  r.addEventListener(popoverResolveBtn, "click", onResolveClick)

  overlayRoot

# --------------------------------------------------------------------------- #
#  Test helpers — exposed so ``test_editor_comment_overlay.nim`` can
#  drive the overlay's reactive state machine without simulating
#  browser-only events.
# --------------------------------------------------------------------------- #

proc placeAnchorAt*(vm: EditorVM; x, y: float; selector = ""): string {.
    discardable.} =
  ## Headless wrapper that mirrors what the underlay click handler
  ## does on the real browser path.  Exists so the headless test can
  ## simulate a click-to-place without dispatching a synthetic
  ## ``MouseEvent`` through the mock DOM.
  vm.addReviewAnnotationAtAnchor(x, y, selector = selector)
