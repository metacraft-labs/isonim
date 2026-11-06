## IsoNim Editor - preview zoom model (PSZ-M1).
##
## A story's device frame is always laid out at its fixed viewport size
## (PSZ-AREQ1). The zoom decides how that frame is shown in the preview area:
## either fitted to it (``pzmFit``) or at a fixed level (``pzmFixed``). The
## zoom scales the frame as a whole, so the story itself never re-lays out.
##
## Pure and headless: no DOM, no signals. The view model holds the state and
## the views read it; the chrome bar and the story URL both go through the
## codecs below.
##
## Decisions with exactly one home each:
## - Fit never scales a frame above its real size: ``previewFitMaxScale``.
## - The fixed levels the zoom-out and zoom-in buttons step through:
##   ``previewZoomSteps``. Changing either constant changes every consumer.

import std/[math, strutils]

const
  previewFitMaxScale* = 1.0
    ## Fit never shows a frame above 100%. Decision PSZ-M1 (spec
    ## "Authoritative requirements", PSZ-AREQ2): a Laptop frame in a larger
    ## area is shown at its real size, not enlarged.
  previewFitMinScale* = 0.05
    ## Lowest scale Fit will reach for a frame far larger than its area. It
    ## is only a guard against a zero scale; Fit is not bound by the fixed
    ## zoom floor below, so a frame that cannot fit at 25% still fits.
  previewZoomMin* = 0.25
    ## Smallest fixed level. Matches the storyboard's zoom floor.
  previewZoomMax* = 4.0
    ## Largest fixed level. Matches the storyboard's zoom ceiling.
  previewZoomSteps* = [0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 4.0]
    ## The fixed levels that the zoom-out and zoom-in buttons move between.

type
  PreviewZoomMode* = enum
    pzmFit    ## Scale the frame to fit the preview area, never above 100%.
    pzmFixed  ## Show the frame at ``PreviewZoom.level``.

  PreviewZoom* = object
    mode*: PreviewZoomMode
    level*: float
      ## Scale used in ``pzmFixed``. Kept (and written to the URL) while in
      ## ``pzmFit`` too, so leaving Fit does not lose the last fixed level.

  PreviewArea* = object
    ## The preview area's client box in CSS pixels. ``0`` means the view has
    ## not measured it yet; Fit then shows 100% rather than guessing.
    width*, height*: int

func defaultPreviewZoom*(): PreviewZoom =
  PreviewZoom(mode: pzmFit, level: 1.0)

func clampFixedLevel*(level: float): float =
  min(previewZoomMax, max(previewZoomMin, level))

func fixedPreviewZoom*(level: float): PreviewZoom =
  ## A fixed level, clamped to the zoom range.
  PreviewZoom(mode: pzmFixed, level: clampFixedLevel(level))

func fitScale*(frameWidth, frameHeight: int; area: PreviewArea): float =
  ## The largest scale that shows the whole frame in the area, never above
  ## ``previewFitMaxScale``. An unmeasured area or an empty frame returns the
  ## real size.
  if frameWidth <= 0 or frameHeight <= 0 or area.width <= 0 or
      area.height <= 0:
    return 1.0
  let byWidth = area.width.float / frameWidth.float
  let byHeight = area.height.float / frameHeight.float
  max(previewFitMinScale, min(previewFitMaxScale, min(byWidth, byHeight)))

func previewScale*(zoom: PreviewZoom; frameWidth, frameHeight: int;
    area: PreviewArea): float =
  ## The scale the frame is drawn at for the given zoom.
  case zoom.mode
  of pzmFit: fitScale(frameWidth, frameHeight, area)
  of pzmFixed: zoom.level

func percentLabel*(scale: float): string =
  ## The readout text: the scale as a whole percentage, e.g. ``69%``.
  ## Shared with the storyboard zoom readout.
  $int(round(scale * 100)) & "%"

func stepPreviewZoom*(zoom: PreviewZoom; frameWidth, frameHeight: int;
    area: PreviewArea; direction: int): PreviewZoom =
  ## One zoom step from the scale currently shown. ``direction`` > 0 zooms in
  ## to the next fixed step above it; < 0 zooms out to the next step below.
  ## The result is always fixed. From Fit, the step starts from the fitted
  ## scale, so the first press lands on the level next to what was shown.
  let current = previewScale(zoom, frameWidth, frameHeight, area)
  const epsilon = 1e-9
  if direction > 0:
    for step in previewZoomSteps:
      if step > current + epsilon:
        return fixedPreviewZoom(step)
    return fixedPreviewZoom(previewZoomSteps[^1])
  for i in countdown(previewZoomSteps.high, 0):
    if previewZoomSteps[i] < current - epsilon:
      return fixedPreviewZoom(previewZoomSteps[i])
  fixedPreviewZoom(previewZoomSteps[0])

func previewZoomRouteParam*(zoom: PreviewZoom): string =
  ## The story URL value: ``fit``, or the fixed level as a whole percentage.
  case zoom.mode
  of pzmFit: "fit"
  of pzmFixed: $int(round(zoom.level * 100))

func previewZoomFromRouteParam*(value: string;
    current: PreviewZoom): PreviewZoom =
  ## Parses a story URL value. ``fit`` selects Fit; a whole number selects a
  ## fixed level in percent. Anything else keeps ``current``, so a damaged
  ## link opens with the zoom the reviewer already had.
  let text = value.strip().toLowerAscii()
  if text.len == 0:
    return current
  if text == "fit":
    return PreviewZoom(mode: pzmFit, level: current.level)
  try:
    let percent = parseInt(text)
    return PreviewZoom(mode: pzmFixed,
      level: clampFixedLevel(percent.float / 100.0))
  except ValueError:
    return current
