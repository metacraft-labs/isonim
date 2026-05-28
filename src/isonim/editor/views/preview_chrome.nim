## REV-M7 — preview chrome 🕘 history affordance.
##
## The legacy preview chrome bar lives in ``shell.nim``'s
## ``renderPreviewChromeBar``.  REV-M7 layers a single new affordance
## onto it: a ``🕘`` button that toggles the gallery overlay.  The
## button is reactive on ``briefHasHistory`` — when the active preview
## has zero captured runs the button is hidden, so a fresh project
## doesn't sprout a useless control.
##
## All chrome added here is built via the ``ui:`` DSL.  No raw
## ``setStyle`` and no raw ``createElement`` — the REV-M7
## ``test_design_review_gallery_no_setstyle`` source scan covers this
## file alongside ``gallery_overlay.nim``.

import std/[options]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/views/icons  # historySvg

type
  HistoryButtonVM* = ref object
    ## ``briefHasHistory`` — when false the button is data-hidden so
    ## the chrome bar doesn't show a useless ``🕘`` for previews with
    ## no captured runs.  Driven by the editor-side history probe
    ## (``GET /api/design-review/brief-has-history`` polled when the
    ## active preview changes).
    briefHasHistory*: Signal[bool]
    galleryOpen*: Signal[bool]

proc createHistoryButtonVM*(): HistoryButtonVM =
  HistoryButtonVM(
    briefHasHistory: createSignal(false),
    galleryOpen: createSignal(false))

const
  hbBg          = "#0F172A"
  hbBgActive    = "#1E293B"
  hbBorder      = "#334155"
  hbAccent      = "#7C7AED"
  hbText        = "#F1F5F9"

proc mountHistoryButton*[R, E](r: R; parent: E; vm: HistoryButtonVM;
                                onActivate: proc()) =
  ## Mount the ``🕘`` button into ``parent``.  ``onActivate`` is the
  ## click handler that opens the gallery overlay (provided by the
  ## preview-pane glue — REV-M7's gallery is the only consumer at
  ## this milestone).  The button is data-tagged so e2e selectors can
  ## find it without scraping emoji bytes.
  let capturedVm = vm
  let capturedOnActivate = onActivate

  let button = ui(r):
    tdiv(
      `role` = "button",
      tabindex = "0",
      `aria-label` = "Open design-review gallery",
      `data-preview-chrome-history-button` = "true",
      `data-design-review-history-button` = "true",
      display = "inline-flex",
      align_items = "center",
      justify_content = "center",
      width = "26px",
      height = "26px",
      padding = "0",
      margin_left = "6px",
      font_size = "14px",
      color = hbText,
      background_color = hbBg,
      border = "1px solid " & hbBorder,
      border_radius = "4px",
      cursor = "pointer",
      user_select = "none")
  # Replace the Unicode clock-face emoji with a proper SVG history
  # glyph that matches the rest of the in-house icon family (clock
  # face with a counter-clockwise rewind arrow at top-left). See
  # docs/icon-design/history.svg.
  r.setInnerHtml(button, historySvg)

  proc activate() =
    capturedVm.galleryOpen.val = not capturedVm.galleryOpen.val
    if capturedOnActivate != nil:
      capturedOnActivate()

  r.addEventListener(button, "click", activate)
  r.addEventListener(button, "keydown", activate)

  createRenderEffect proc() =
    let hasHistory = capturedVm.briefHasHistory.val
    let isOpen = capturedVm.galleryOpen.val
    # CHRM-M5 Fix D: the button is now always visible — the
    # ``data-history-visible`` attribute mirrors whether any
    # captures exist for the active brief (kept for tests +
    # tooling) but no longer flips ``aria-hidden`` to ``true``.
    # When no captures exist the overlay surfaces an
    # empty-state panel ("No captures yet") instead of hiding
    # the button entirely, which the user perceived as the
    # button being broken.
    r.setAttribute(button, "data-history-visible",
                   if hasHistory: "true" else: "false")
    r.setAttribute(button, "aria-hidden", "false")
    r.setAttribute(button, "aria-pressed",
                   if isOpen: "true" else: "false")
    r.setAttribute(button, "data-gallery-open",
                   if isOpen: "true" else: "false")

  r.appendChild(parent, button)
