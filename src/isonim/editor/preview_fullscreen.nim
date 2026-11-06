## IsoNim Editor - preview full screen (PSZ-M2).
##
## A story's web page preview can take the whole editor window, without the
## sidebars, the inspector, the chrome bar or the status bar. The zoom and the
## viewport are not touched, so leaving full screen returns the same story,
## size and zoom (spec Preview-Sizing-And-Zoom.md, PSZ-AREQ3).
##
## Pure and headless: no DOM, no signals. The view model holds the state, the
## shell renders it, the keyboard handler in browser.nim reads the key below,
## and the story URL goes through the codec at the bottom.
##
## Decisions with exactly one home each:
## - The key that toggles full screen (open decision D1): ``previewFullScreenKey``.
##   Changing it changes the binding everywhere.
## - The corner in which the floating zoom cluster is revealed by the pointer:
##   ``previewFullScreenRevealWidth`` and ``previewFullScreenRevealHeight``, and
##   the test ``inRevealZone``.

import std/strutils

const
  previewFullScreenKey* = "f"
    ## D1 (spec Preview-Sizing-And-Zoom.md, Open decisions): the key toggles
    ## full screen while the preview has keyboard focus. Compared against the
    ## lower-cased ``KeyboardEvent.key``, with no modifier held. Escape always
    ## leaves full screen and is not configurable here.
  previewFullScreenRevealWidth* = 360
  previewFullScreenRevealHeight* = 120
    ## The corner zone, measured from the top-right of the preview area, in
    ## CSS pixels. Entering it reveals the floating controls. It covers the
    ## cluster's width with margin, so the pointer can reach the cluster
    ## without leaving the zone.

func inRevealZone*(x, y, areaWidth: int): bool =
  ## True when the point ``(x, y)``, measured from the top-left of the preview
  ## area, lies in the top-right reveal corner of an area ``areaWidth`` wide.
  ## A point left of the zone, or below it, is outside.
  x >= areaWidth - previewFullScreenRevealWidth and x <= areaWidth and
    y >= 0 and y < previewFullScreenRevealHeight

func previewFullScreenRouteParam*(on: bool): string =
  ## The story URL value: ``1`` in full screen, ``0`` otherwise. It is written on
  ## every route write, so Back leaves full screen with the entry it returns to.
  if on: "1" else: "0"

func previewFullScreenFromRouteParam*(value: string;
    current: bool): bool =
  ## Parses the story URL value. Anything unrecognised keeps ``current``, so a
  ## damaged link does not change the screen the reviewer is on.
  case value.strip().toLowerAscii()
  of "1", "true", "yes", "on": true
  of "0", "false", "no", "off": false
  else: current
