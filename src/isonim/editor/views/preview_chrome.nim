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
  # Phase O (2026-05-29): the History button now joins the chip
  # cluster family. It renders as a single ChoiceItem-style pill
  # inside a transparent trough container, matching the Backend /
  # Viewport / Mode clusters that already use ``cgvTransparent``
  # ChoiceGroup styling. Colour tokens are pulled from the shared
  # chip palette (mirrored here so this module stays free of the
  # ``choice_group`` import) — keep these in sync with
  # ``views/widgets/choice_group.nim`` constants ``cgGroupBg``,
  # ``cgPillBgOn``, ``cgPillBorderOn``, ``cgTextOn``, ``cgTextDim``.
  hbTroughBg      = "#22232e"   # cgGroupBg — strip background
  hbPillBg        = "transparent"
  hbPillBgOn      = "#7c7aed"   # cgPillBgOn — active accent fill
  hbPillBorder    = "transparent"
  hbPillBorderOn  = "#7c7aed"   # cgPillBorderOn
  hbTextDim       = "#A0A2B0"   # cgTextDim — inactive label
  hbTextOn        = "#FFFFFF"   # cgTextOn — active label
  hbPillRadius    = "4px"
  hbPillPadding   = "2px"
  hbPillMinHeight = "22px"
  hbPillIconWidth = "32px"      # cgPillIconMinWidth — single-pill width
  hbIconSize      = "18px"      # cgPillIconSize — inner SVG host

proc mountHistoryButton*[R, E](r: R; parent: E; vm: HistoryButtonVM;
                                onActivate: proc()) =
  ## Mount the history button into ``parent``.  ``onActivate`` is the
  ## click handler that opens the gallery overlay (provided by the
  ## preview-pane glue — REV-M7's gallery is the only consumer at
  ## this milestone).  The button is data-tagged so e2e selectors can
  ## find it without scraping emoji bytes.
  ##
  ## Phase O (2026-05-29) — the button is now wrapped in a single-
  ## pill trough that matches the ``cgvTransparent`` ChoiceGroup
  ## styling used by Backend / Viewport / Mode. The outer trough
  ## carries ``data-chrome-history-trough="true"``; the inner pill
  ## (the actual click target) still carries the legacy
  ## ``data-design-review-history-button`` /
  ## ``data-preview-chrome-history-button`` selectors so existing
  ## tests and tooling resolve unchanged. The pill flips between an
  ## inactive "dim text" treatment and an accent-filled "active"
  ## treatment when the gallery overlay is open — same hover/active
  ## visual contract as the cluster pills.
  let capturedVm = vm
  let capturedOnActivate = onActivate

  var button: E
  let trough = ui(r):
    tdiv(
      `data-chrome-history-trough` = "true",
      `data-toolbar-cluster` = "history",
      display = "inline-flex",
      align_items = "center",
      gap = "2px",
      padding = hbPillPadding,
      background_color = hbTroughBg,
      border = "none",
      border_radius = "6px",
      user_select = "none"):
      tdiv(
        ref = button,
        `role` = "button",
        tabindex = "0",
        `aria-label` = "Open design-review gallery",
        `data-preview-chrome-history-button` = "true",
        `data-design-review-history-button` = "true",
        `data-choice-group-pill` = "0",
        display = "inline-flex",
        align_items = "center",
        justify_content = "center",
        width = hbPillIconWidth, min_width = hbPillIconWidth,
        min_height = hbPillMinHeight,
        padding = "0",
        font_size = "12px",
        color = hbTextDim,
        background_color = hbPillBg,
        border = "1px solid " & hbPillBorder,
        border_radius = hbPillRadius,
        cursor = "pointer",
        transition = "background-color 120ms ease-out, " &
          "border-color 120ms ease-out, color 120ms ease-out")
  # Paint the SVG glyph into the pill via ``setInnerHtml``. The icon
  # is rendered at ``hbIconSize`` (matching ``cgPillIconSize`` used
  # by the cluster pills) so the chrome bar reads as a uniform row
  # of equally-weighted glyphs.
  r.setInnerHtml(button, historySvg)
  discard hbIconSize  # kept as documentation; the SVG sizes itself

  proc activate() =
    capturedVm.galleryOpen.val = not capturedVm.galleryOpen.val
    if capturedOnActivate != nil:
      capturedOnActivate()

  r.addEventListener(button, "click", activate)
  r.addEventListener(button, "keydown", activate)

  # Reactive bind — gallery-open flips the pill to the accent fill
  # treatment (matching the cluster pills' active state). When the
  # overlay is closed the pill reverts to the muted "inactive"
  # treatment. Driven entirely through ``setAttribute("style", ...)``
  # so this stays inside the ``createRenderEffect`` envelope and
  # respects the no-setStyle-outside-effect rule.
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
    r.setAttribute(button, "data-active",
                   if isOpen: "true" else: "false")
    let layoutCss =
      "display: inline-flex; align-items: center; " &
      "justify-content: center; " &
      "width: " & hbPillIconWidth & "; min-width: " & hbPillIconWidth &
      "; min-height: " & hbPillMinHeight & "; padding: 0; " &
      "border-radius: " & hbPillRadius & "; " &
      "border-width: 1px; border-style: solid; " &
      "font-size: 12px; font-family: inherit; line-height: 1; " &
      "text-align: center; white-space: nowrap; " &
      "flex: 0 0 auto; cursor: pointer; " &
      "transition: background-color 120ms ease-out, " &
      "border-color 120ms ease-out, color 120ms ease-out;"
    let inline =
      if isOpen:
        layoutCss &
          " background-color: " & hbPillBgOn &
          "; color: " & hbTextOn &
          "; border-color: " & hbPillBorderOn & ";"
      else:
        layoutCss &
          " background-color: " & hbPillBg &
          "; color: " & hbTextDim &
          "; border-color: " & hbPillBorder & ";"
    r.setAttribute(button, "style", inline)

  r.appendChild(parent, trough)
