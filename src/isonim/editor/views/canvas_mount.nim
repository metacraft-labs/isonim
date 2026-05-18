## IsoNim Editor — Pattern A canvas mount helper.
##
## Centralises the canvas + overlay DOM construction and the reactive
## overlay-positioning effect used by `component_detail.nim`,
## `page_preview.nim`, and `foundations_page.nim`.
##
## The helper *intentionally* does not own iframe-vs-canvas visibility
## toggling or `attachBridgeClient` lifetime — those depend on
## per-view sibling elements (iframe refs differ per view) so the
## caller drives them. What this helper does own:
##
##   * the canvas + overlay DOM (canvas, hover label, selection
##     outline, breadcrumb host, 8 edit-mode handles);
##   * the reactive overlay-positioning effect (hover label position,
##     selection outline + breadcrumb + edit handles);
##   * the fit-to-pane CSS hooks. Use ``applyCanvasFitStyle`` to flip
##     the canvas + wrapper to the no-stretch display mode (canvas
##     rendered at intrinsic pixel size, centered in a flex wrapper
##     that letterboxes / crops as needed — the screen-capture
##     automation is responsible for matching the launcher's emitted
##     pixel size to the preview pane's rendered size).
##
## See M-EVP-13 in
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.status.org``
## for the acceptance criteria this helper exists to satisfy.

import std/options
import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/streaming_preview

when defined(js):
  from std/dom import Element

const
  accentBlue* = "#3B82F6"
  handleNames* = [
    "nw", "n", "ne", "e", "se", "s", "sw", "w",
  ]

type
  CanvasMount*[E] = object
    ## Refs to the canvas + overlay DOM the helper constructed. The
    ## ``wrapper`` is positioned (``position: relative``) so the
    ## absolute-positioned ``overlay`` paints on top of ``canvas``.
    ## ``breadcrumb`` is mounted by the caller separately (it lives
    ## outside the wrapper — see component_detail's M-EVP-12
    ## fix-cycle 2 note).
    wrapper*: E
    canvas*: E
    overlay*: E
    hoverLabel*: E
    hoverLabelText*: E
    selectionOutline*: E
    breadcrumb*: E
    breadcrumbText*: E
    handlesGroup*: E
    handleElems*: array[8, E]

proc renderCanvasMount*[R, E](r: R; canvasDataAttr: string = ""):
    CanvasMount[E] =
  ## Build the canvas + overlay DOM tree once and return refs.
  ##
  ## ``canvasDataAttr`` is an optional ``data-*-canvas`` marker the
  ## caller appends to the canvas element so existing CSS / tests can
  ## continue to address the per-view canvas (e.g.
  ## ``data-component-project-canvas``). The shared
  ## ``data-canvas-active`` attribute is wired by the helper's
  ## visibility binding below; this slot is for per-view legacy
  ## selectors.
  var wrapper: E
  var canvasEl: E
  var overlay: E
  var hoverLabel: E
  var hoverLabelText: E
  var selectionOutline: E
  var breadcrumb: E
  var breadcrumbText: E
  var handlesGroup: E
  var handleElems: array[8, E]

  let tree = ui(r):
    tdiv(ref = wrapper,
          `data-canvas-wrapper` = "true",
          position = "relative",
          display = "none",
          width = "100%",
          height = "100%",
          min_height = "1px"):
      canvas(ref = canvasEl,
          width = "1280",
          height = "1",
          display = "none",
          background_color = "#000000")
      tdiv(ref = overlay,
            `data-canvas-overlay` = "true",
            position = "absolute",
            left = "0", top = "0", right = "0", bottom = "0",
            pointer_events = "none",
            display = "none"):
        tdiv(ref = selectionOutline,
              `data-canvas-selection-outline` = "true",
              position = "absolute",
              border = "3px solid " & accentBlue,
              border_radius = "3px",
              box_shadow = "0 0 0 6px rgba(59,130,246,.32)",
              pointer_events = "none",
              box_sizing = "border-box",
              display = "none")
        tdiv(ref = hoverLabel,
              `data-canvas-hover-label` = "true",
              position = "absolute",
              pointer_events = "none",
              padding = "5px 9px",
              border_radius = "5px",
              border = "1px solid " & accentBlue,
              background_color = "rgba(15,23,42,.96)",
              color = "#F8FAFC",
              font_family = "ui-monospace, SFMono-Regular, Menlo, monospace",
              font_size = "13px",
              font_weight = "600",
              line_height = "1.3",
              box_shadow = "0 6px 18px rgba(15,23,42,.45)",
              white_space = "nowrap",
              display = "none"):
          span(ref = hoverLabelText):
            text ""
        tdiv(ref = handlesGroup,
              position = "absolute",
              left = "0", top = "0", right = "0", bottom = "0",
              pointer_events = "none",
              display = "none"):
          for hi in 0 ..< 8:
            tdiv(ref = handleElems[hi],
                  `data-canvas-selection-handle` = "true",
                  `data-handle-position` = handleNames[hi],
                  position = "absolute",
                  width = "12px", height = "12px",
                  margin_left = "-6px", margin_top = "-6px",
                  border = "2px solid #FFFFFF",
                  border_radius = "3px",
                  background_color = accentBlue,
                  box_shadow = "0 1px 3px rgba(15,23,42,.5)",
                  pointer_events = "auto",
                  box_sizing = "border-box")
  discard tree

  if canvasDataAttr.len > 0:
    r.setAttribute(canvasEl, canvasDataAttr, "true")

  # Breadcrumb panel — kept in this helper but the caller is
  # responsible for appending it where it makes sense in their
  # layout. M-EVP-12 fix-cycle 2 lifted the breadcrumb out of the
  # overlay so it never overlaps the selection outline.
  let breadcrumbNode = ui(r):
    tdiv(ref = breadcrumb,
          `data-canvas-selection-breadcrumb` = "true",
          position = "relative",
          margin = "8px 0 0 0",
          padding = "6px 12px",
          border_radius = "6px",
          border = "1px solid " & accentBlue,
          background_color = "rgba(59,130,246,0.18)",
          color = accentBlue,
          font_family = "ui-monospace, SFMono-Regular, Menlo, monospace",
          font_size = "12px",
          font_weight = "600",
          line_height = "1.3",
          max_width = "100%",
          overflow = "hidden",
          text_overflow = "ellipsis",
          white_space = "nowrap",
          display = "none"):
      span(ref = breadcrumbText):
        text ""
  discard breadcrumbNode

  CanvasMount[E](
    wrapper: wrapper,
    canvas: canvasEl,
    overlay: overlay,
    hoverLabel: hoverLabel,
    hoverLabelText: hoverLabelText,
    selectionOutline: selectionOutline,
    breadcrumb: breadcrumb,
    breadcrumbText: breadcrumbText,
    handlesGroup: handlesGroup,
    handleElems: handleElems)

proc applyCanvasFitStyle*[R, E](r: R; mount: CanvasMount[E];
                                 active: bool) =
  ## No-stretch rule: when the canvas is the active surface, we render
  ## it at its **intrinsic pixel size** (no CSS scaling). The wrapper
  ## becomes a flex container that centers the canvas; if the canvas
  ## is smaller than the pane, the wrapper letterboxes the surround
  ## with its ``#0a101e`` background. If the canvas is larger than the
  ## pane, ``overflow: hidden`` crops it centered.
  ##
  ## Image-rendering safety net: ``pixelated`` is set on the canvas so
  ## that if any code path ever re-introduces CSS scaling, the
  ## resampler is nearest-neighbour rather than bilinear (bilinear
  ## scaling of UI screenshots reads as a stretched/softened image,
  ## which the no-stretch rule exists to prevent).
  ##
  ## The screen-capture automation is responsible for matching the
  ## launcher's emitted pixel size to the preview pane's rendered size
  ## (``--width`` / ``--height`` CLI flags on software backends). On
  ## real-device backends (e.g. iOS) where the device dictates the
  ## frame size, this proc lets the wrapper crop/letterbox naturally
  ## rather than stretching.
  ##
  ## Visibility of the per-affordance overlay children (hover label,
  ## selection outline, breadcrumb, handles) is *not* set here — that
  ## belongs to ``bindCanvasOverlayEffect`` whose reactive chain
  ## already hides them when the active backend is pbWeb.
  ##
  ## We also paint a 1px hairline border + subtle inner shadow on the
  ## wrapper so the rendered demo box reads as a framed surface
  ## against the surrounding pane chrome (and the letterbox bands
  ## around an undersized canvas have a visible edge instead of
  ## bleeding into the pane background).
  if active:
    r.setStyle(mount.wrapper, "display", "flex")
    r.setStyle(mount.wrapper, "align-items", "center")
    r.setStyle(mount.wrapper, "justify-content", "center")
    r.setStyle(mount.wrapper, "border", "1px solid rgba(148,163,184,.45)")
    r.setStyle(mount.wrapper, "border-radius", "6px")
    r.setStyle(mount.wrapper, "box-shadow",
               "0 0 0 1px rgba(15,23,42,.6), " &
               "0 4px 12px rgba(15,23,42,.35)")
    r.setStyle(mount.wrapper, "background-color", "#0a101e")
    r.setStyle(mount.wrapper, "overflow", "hidden")
    r.setStyle(mount.wrapper, "box-sizing", "border-box")
    r.setStyle(mount.canvas, "display", "block")
    r.setStyle(mount.overlay, "display", "block")
    # Intrinsic pixel size — no CSS scaling. Setting width/height to
    # auto lets the canvas's ``width``/``height`` HTML attributes
    # drive its rendered size (1 CSS px per source pixel).
    r.setStyle(mount.canvas, "width", "auto")
    r.setStyle(mount.canvas, "height", "auto")
    r.setStyle(mount.canvas, "object-fit", "")
    r.setStyle(mount.canvas, "flex-shrink", "0")
    # Safety net: if any path ever re-introduces CSS scaling, use
    # nearest-neighbour (never bilinear) so the stretching is obvious
    # instead of silently softening pixels.
    r.setStyle(mount.canvas, "image-rendering", "pixelated")
    r.setAttribute(mount.canvas, "data-canvas-active", "true")
  else:
    r.setStyle(mount.wrapper, "display", "none")
    r.setStyle(mount.wrapper, "align-items", "")
    r.setStyle(mount.wrapper, "justify-content", "")
    r.setStyle(mount.wrapper, "border", "")
    r.setStyle(mount.wrapper, "border-radius", "")
    r.setStyle(mount.wrapper, "box-shadow", "")
    r.setStyle(mount.wrapper, "background-color", "")
    r.setStyle(mount.wrapper, "overflow", "")
    r.setStyle(mount.canvas, "display", "none")
    r.setStyle(mount.overlay, "display", "none")
    r.setStyle(mount.canvas, "image-rendering", "")
    r.setStyle(mount.canvas, "flex-shrink", "")
    r.setAttribute(mount.canvas, "data-canvas-active", "false")

proc bindCanvasOverlayEffect*[R, E](r: R; vm: EditorVM;
                                     mount: CanvasMount[E]) =
  ## Reactive overlay-positioning effect. Mirrors the chain in
  ## ``component_detail.nim`` lines 1140-1290: paints the hover
  ## label, selection outline, breadcrumb, and (in ``emEdit``) the 8
  ## handles. Coordinates are mapped from F-packet pixel space to
  ## CSS pixel space via ``canvas.clientWidth / canvas.width``.
  ##
  ## RS-M13: when the manifest carries ``boundsUnit == "cells"`` (the
  ## TUI D/M/P transport) the surface element is no longer the
  ## ``<canvas>`` — it is the sibling ``<div data-tui-terminal="true">``
  ## host that xterm.js painted into. The CSS-px translation switches
  ## to ``cellW = hostRect.width / surfaceCols`` and the overlay still
  ## paints over the correct rectangle because the host and the
  ## overlay share the wrapper's coordinate space.
  let canvasEl = mount.canvas
  let overlayEl = mount.overlay
  let wrapperEl = mount.wrapper
  let hoverLabel = mount.hoverLabel
  let hoverLabelText = mount.hoverLabelText
  let selectionOutline = mount.selectionOutline
  let breadcrumb = mount.breadcrumb
  let breadcrumbText = mount.breadcrumbText
  let handlesGroup = mount.handlesGroup
  let handleElems = mount.handleElems
  discard overlayEl
  discard wrapperEl

  # Latched bounds for the currently-selected component, used to bridge
  # the mid-reseed gap when the launcher re-emits the element-tree
  # manifest with fresh ids. The window between the chrome bar setting
  # ``emEdit`` and the new manifest landing can leave ``boundsOf`` AND
  # ``boundsOfPath`` both returning none for one or two render ticks
  # (the click-time id is stale; the new manifest hasn't been decoded
  # yet). Without a latch, the overlay effect re-runs in that window,
  # sees both lookups fail, hides the handles, and the user sees them
  # flicker off.
  #
  # The latch is keyed by ``selectedComponentPath`` (stable across re-
  # emissions for the same logical element) and resets on:
  #   * an empty selection — the user explicitly cleared selection,
  #     never paint a ghost outline;
  #   * a path change — the user picked a different element, never
  #     paint stale bounds for the new selection.
  var latchedPath = ""
  var latchedBounds: Option[ElementBounds] = none(ElementBounds)

  createRenderEffect proc() =
    let streaming = vm.streamingPreview
    if streaming == nil:
      return
    let useCanvas = vm.platform.val != pbWeb
    let canvas = streaming.canvas
    let hoverIdOpt = canvas.hoveredElementId.val
    let hoverPathOpt = canvas.hoveredComponentPath.val
    let selectedId = canvas.selectedElementId.val
    let selectedPath = canvas.selectedComponentPath.val
    let mode = vm.editMode.val
    let manifestOpt = canvas.manifest.val
    let isCellUnit =
      manifestOpt.isSome and manifestOpt.get.boundsUnit == "cells"
    let surfaceCols =
      if isCellUnit: manifestOpt.get.surfaceWidth else: 0
    let surfaceRows =
      if isCellUnit: manifestOpt.get.surfaceHeight else: 0
    if not useCanvas:
      r.setStyle(hoverLabel, "display", "none")
      r.setStyle(selectionOutline, "display", "none")
      r.setStyle(breadcrumb, "display", "none")
      r.setStyle(handlesGroup, "display", "none")
      return

    # ----------- Hover label -----------
    if hoverPathOpt.isSome:
      r.setTextContent(hoverLabelText, hoverPathOpt.get)
      r.setStyle(hoverLabel, "display", "block")
      when defined(js):
        let hid = hoverIdOpt
        if hid.isSome:
          var bOpt = canvas.boundsOf(hid.get)
          if bOpt.isNone:
            # Fallback when a manifest re-emission shifted the id.
            bOpt = canvas.boundsOfPath(hoverPathOpt.get)
          if bOpt.isSome:
            let b = bOpt.get
            let bx = b.x
            let by = b.y
            let bw = b.w
            let cnv = canvasEl
            let wrap = wrapperEl
            let lbl = hoverLabel
            let cellMode = if isCellUnit: 1 else: 0
            let cols = surfaceCols
            let rows = surfaceRows
            {.emit: ["""
              try {
                var c = """, cnv, """;
                var w = """, wrap, """;
                var lbl = """, lbl, """;
                if (""", cellMode, """ && w && """, cols, """ > 0 && """, rows, """ > 0) {
                  // RS-M13 cell-coord path: translate via the
                  // xterm.js host's rect (the active TUI surface).
                  var host = w.querySelector('[data-tui-terminal="true"]');
                  if (host && lbl) {
                    var hostRect = host.getBoundingClientRect();
                    var wrapRect = w.getBoundingClientRect();
                    if (hostRect.width > 0 && hostRect.height > 0) {
                      var cellW = hostRect.width / """, cols, """;
                      var cellH = hostRect.height / """, rows, """;
                      var offX = hostRect.left - wrapRect.left;
                      var offY = hostRect.top - wrapRect.top;
                      var leftPx = offX + (""", bx, """ + """, bw, """) * cellW;
                      var topPx = offY + """, by, """ * cellH;
                      lbl.style.left = leftPx + 'px';
                      lbl.style.top = topPx + 'px';
                    }
                  }
                } else if (c && lbl && c.width > 0 && c.height > 0) {
                  var sx = c.clientWidth / c.width;
                  var sy = c.clientHeight / c.height;
                  var leftPx = (""", bx, """ + """, bw, """) * sx;
                  var topPx = """, by, """ * sy;
                  lbl.style.left = leftPx + 'px';
                  lbl.style.top = topPx + 'px';
                }
              } catch (_) {}
            """].}
    else:
      r.setStyle(hoverLabel, "display", "none")

    # ----------- Selection outline + breadcrumb -----------
    if selectedId.len > 0:
      var bOpt = canvas.boundsOf(selectedId)
      if bOpt.isNone and selectedPath.len > 0:
        # Fallback: the manifest may have re-emitted with fresh ids
        # while the selection signals still reference the click-time
        # id. componentPath is stable across re-emissions so it lets
        # the overlay continue painting the rectangle. Without this,
        # the outline + breadcrumb + edit-mode handles all blink off
        # when the launcher reseeds (RS-M12 ``select-story``).
        bOpt = canvas.boundsOfPath(selectedPath)
      # Mid-reseed bounds gap: when the chrome bar flips ``emEdit``
      # the launcher may emit a fresh element-tree manifest with new
      # ids before the new manifest has fully landed in the canvas
      # VM. For that brief reactive window both lookups above return
      # none, and without the latch the overlay effect hides the
      # outline + breadcrumb + handles. We bridge that window by
      # repainting the previous tick's bounds when:
      #   * the selection's ``selectedComponentPath`` is unchanged,
      #     AND
      #   * the previous tick had a valid bounds for that path.
      # Both conditions together guarantee the latch never paints
      # stale bounds for a different element (path differs) or a
      # cleared selection (the ``selectedId.len == 0`` branch below
      # resets the latch before we get here).
      if bOpt.isNone and selectedPath.len > 0 and
         latchedPath == selectedPath and latchedBounds.isSome:
        bOpt = latchedBounds
      if bOpt.isSome and selectedPath.len > 0:
        latchedPath = selectedPath
        latchedBounds = bOpt
      if bOpt.isSome:
        let b = bOpt.get
        r.setAttribute(selectionOutline, "data-element-id", selectedId)
        r.setStyle(selectionOutline, "display", "block")
        when defined(js):
          let bx = b.x
          let by = b.y
          let bw = b.w
          let bh = b.h
          let cnv = canvasEl
          let wrap = wrapperEl
          let outline = selectionOutline
          let cellMode = if isCellUnit: 1 else: 0
          let cols = surfaceCols
          let rows = surfaceRows
          {.emit: ["""
            try {
              var c = """, cnv, """;
              var w = """, wrap, """;
              var o = """, outline, """;
              if (""", cellMode, """ && w && o && """, cols, """ > 0 && """, rows, """ > 0) {
                var host = w.querySelector('[data-tui-terminal="true"]');
                if (host) {
                  var hostRect = host.getBoundingClientRect();
                  var wrapRect = w.getBoundingClientRect();
                  if (hostRect.width > 0 && hostRect.height > 0) {
                    var cellW = hostRect.width / """, cols, """;
                    var cellH = hostRect.height / """, rows, """;
                    var offX = hostRect.left - wrapRect.left;
                    var offY = hostRect.top - wrapRect.top;
                    o.style.left = (offX + """, bx, """ * cellW) + 'px';
                    o.style.top = (offY + """, by, """ * cellH) + 'px';
                    o.style.width = (""", bw, """ * cellW) + 'px';
                    o.style.height = (""", bh, """ * cellH) + 'px';
                  }
                }
              } else if (c && o && c.width > 0 && c.height > 0) {
                var sx = c.clientWidth / c.width;
                var sy = c.clientHeight / c.height;
                o.style.left = (""", bx, """ * sx) + 'px';
                o.style.top = (""", by, """ * sy) + 'px';
                o.style.width = (""", bw, """ * sx) + 'px';
                o.style.height = (""", bh, """ * sy) + 'px';
              }
            } catch (_) {}
          """].}
        r.setTextContent(breadcrumbText, selectedPath)
        r.setStyle(breadcrumb, "display", "block")
        if mode == emEdit:
          r.setStyle(handlesGroup, "display", "block")
          when defined(js):
            let cnv = canvasEl
            let wrap = wrapperEl
            let bx = b.x
            let by = b.y
            let bw = b.w
            let bh = b.h
            let cellMode = if isCellUnit: 1 else: 0
            let cols = surfaceCols
            let rows = surfaceRows
            for hi in 0 ..< 8:
              let hEl = handleElems[hi]
              let pos = handleNames[hi]
              {.emit: ["""
                try {
                  var c = """, cnv, """;
                  var w = """, wrap, """;
                  var h = """, hEl, """;
                  var sx = 0, sy = 0, offX = 0, offY = 0;
                  var ok = false;
                  if (""", cellMode, """ && w && h && """, cols, """ > 0 && """, rows, """ > 0) {
                    var host = w.querySelector('[data-tui-terminal="true"]');
                    if (host) {
                      var hostRect = host.getBoundingClientRect();
                      var wrapRect = w.getBoundingClientRect();
                      if (hostRect.width > 0 && hostRect.height > 0) {
                        sx = hostRect.width / """, cols, """;
                        sy = hostRect.height / """, rows, """;
                        offX = hostRect.left - wrapRect.left;
                        offY = hostRect.top - wrapRect.top;
                        ok = true;
                      }
                    }
                  } else if (c && h && c.width > 0 && c.height > 0) {
                    sx = c.clientWidth / c.width;
                    sy = c.clientHeight / c.height;
                    ok = true;
                  }
                  if (ok) {
                    var bx = offX + """, bx, """ * sx;
                    var by = offY + """, by, """ * sy;
                    var bw = """, bw, """ * sx;
                    var bh = """, bh, """ * sy;
                    var pos = """, pos.cstring, """;
                    var x = bx, y = by;
                    if (pos === 'nw') { x = bx; y = by; }
                    else if (pos === 'n') { x = bx + bw / 2; y = by; }
                    else if (pos === 'ne') { x = bx + bw; y = by; }
                    else if (pos === 'e') { x = bx + bw; y = by + bh / 2; }
                    else if (pos === 'se') { x = bx + bw; y = by + bh; }
                    else if (pos === 's') { x = bx + bw / 2; y = by + bh; }
                    else if (pos === 'sw') { x = bx; y = by + bh; }
                    else if (pos === 'w') { x = bx; y = by + bh / 2; }
                    h.style.left = x + 'px';
                    h.style.top = y + 'px';
                  }
                } catch (_) {}
              """].}
        else:
          r.setStyle(handlesGroup, "display", "none")
      else:
        r.setStyle(selectionOutline, "display", "none")
        r.setStyle(breadcrumb, "display", "none")
        r.setStyle(handlesGroup, "display", "none")
    else:
      # Selection explicitly cleared — drop the latch so a future
      # selection at the same componentPath doesn't briefly paint
      # the previous bounds before the new manifest lands.
      latchedPath = ""
      latchedBounds = none(ElementBounds)
      r.setStyle(selectionOutline, "display", "none")
      r.setStyle(breadcrumb, "display", "none")
      r.setStyle(handlesGroup, "display", "none")

when defined(js):
  type BridgeBinding* = ref object
    ## Lifecycle holder for a per-view bridge attachment. Stored on
    ## the view's closure so the next render-effect tick can detach
    ## and re-attach if the backend changed.
    ##
    ## RS-M13: ``tuiHandle`` is set when the active backend is
    ## ``pbTui`` and an xterm.js Terminal is mounted; mutually
    ## exclusive with ``handle`` (the canvas-based F/M/I client).
    handle*: BridgeClientHandle
    tuiHandle*: TuiTerminalHandle
    tuiHost*: Element
    attachedBackend*: PreviewBackend
    lastSentStoryId*: string
      ## RS-M12: dedupes redundant ``select-story`` sends. The
      ## reactive render-effect can fire on signal changes that
      ## don't actually represent a story switch (e.g. backend
      ## change, edit-mode flip); tracking the last-sent id lets us
      ## skip those no-op packets.

  proc newBridgeBinding*(): BridgeBinding =
    BridgeBinding(handle: nil, tuiHandle: nil, tuiHost: nil,
                  attachedBackend: pbWeb,
                  lastSentStoryId: "")

  proc sendCurrentStory*(binding: BridgeBinding; vm: EditorVM) =
    ## RS-M12 / RS-M13: emit the ``select-story`` packet for the
    ## editor's currently-selected story over whichever transport is
    ## attached (F/M/I via ``BridgeClientHandle`` or D/M/P via
    ## ``TuiTerminalHandle``). Idempotent: the second call with the
    ## same story is a no-op. Safe to call without a live socket —
    ## the inner senders guard on ``ws.readyState === OPEN``.
    let story = vm.selectedStory.val
    if story.group.len == 0 or story.name.len == 0: return
    let storyId = storyIdFor(story)
    if storyId == binding.lastSentStoryId: return
    if binding.tuiHandle != nil:
      if not isTuiBridgeOpen(binding.tuiHandle): return
      sendTuiSelectStory(binding.tuiHandle, story.group, story.name,
                         storyKindWire(story.kind), storyId)
      binding.lastSentStoryId = storyId
    elif binding.handle != nil:
      if not isBridgeOpen(binding.handle): return
      sendSelectStory(binding.handle, story.group, story.name,
                      storyKindWire(story.kind), storyId)
      binding.lastSentStoryId = storyId

  proc installStoryPublisher(binding: BridgeBinding;
                              streaming: StreamingPreviewVM) =
    ## RS-M12 / RS-M13: register sender closures on the streaming-
    ## preview VM so the viewmodel layer (inspector edits, story
    ## selection) can publish without taking a transitive dependency
    ## on either handle type. The closures capture ``binding`` by
    ## reference so they pick up handle changes across re-attaches
    ## (including the F/M/I ↔ D/M/P swap when the user toggles TUI).
    let b = binding
    streaming.setStoryPublisher(
      sendStory = proc(storyGroup, storyName, storyKind,
                       storyId: string) =
        if storyId == b.lastSentStoryId: return
        if b.tuiHandle != nil:
          if not isTuiBridgeOpen(b.tuiHandle): return
          sendTuiSelectStory(b.tuiHandle, storyGroup, storyName,
                             storyKind, storyId)
          b.lastSentStoryId = storyId
        elif b.handle != nil:
          if not isBridgeOpen(b.handle): return
          sendSelectStory(b.handle, storyGroup, storyName, storyKind,
                          storyId)
          b.lastSentStoryId = storyId,
      sendMutation = proc(target, key, valueLiteral: string;
                          scope: MutationScopeKind) =
        if b.tuiHandle != nil:
          if not isTuiBridgeOpen(b.tuiHandle): return
          sendTuiApplyMutation(b.tuiHandle, target, key,
                               valueLiteral, scope)
        elif b.handle != nil:
          if not isBridgeOpen(b.handle): return
          sendApplyMutation(b.handle, target, key, valueLiteral, scope))

  proc ensureTuiHost(canvas: Element): Element =
    ## Resolve (or lazily create) the ``<div data-tui-terminal="true">``
    ## host that xterm.js mounts into. The host lives as a sibling of
    ## the canvas inside the shared ``CanvasMount`` wrapper so the
    ## overlay (hover label, selection outline) — which is also a
    ## sibling of the canvas — overlays the terminal correctly.
    ## Returns nil on JS-environment failure.
    var host: Element
    {.emit: ["""
      (function (canvas) {
        if (!canvas) return null;
        var parent = canvas.parentNode;
        if (!parent) return null;
        var existing = parent.querySelector('[data-tui-terminal-host="true"]');
        if (existing) {
          """, host, """ = existing;
          return;
        }
        var div = document.createElement('div');
        div.setAttribute('data-tui-terminal-host', 'true');
        div.style.position = 'absolute';
        div.style.left = '0';
        div.style.top = '0';
        div.style.width = '100%';
        div.style.height = '100%';
        div.style.boxSizing = 'border-box';
        div.style.backgroundColor = '#0a101e';
        div.style.overflow = 'hidden';
        // Insert BEFORE the canvas so any overlay siblings (which the
        // shared canvas-mount inserts as later siblings of the canvas)
        // continue to paint above the terminal.
        parent.insertBefore(div, canvas);
        """, host, """ = div;
      })(""", canvas, ");"].}
    host

  proc setTuiHostVisible(host: Element; visible: bool) =
    if host == nil: return
    {.emit: ["""
      (function (host, visible) {
        if (!host) return;
        host.style.display = visible ? 'block' : 'none';
      })(""", host, ", ", visible, ");"].}

  proc setCanvasHidden(canvas: Element; hidden: bool) =
    if canvas == nil: return
    {.emit: ["""
      (function (canvas, hidden) {
        if (!canvas) return;
        canvas.style.visibility = hidden ? 'hidden' : 'visible';
      })(""", canvas, ", ", hidden, ");"].}

  proc attachIfNeeded*(binding: BridgeBinding; vm: EditorVM;
                       canvas: Element; useCanvas: bool;
                       onVectorDbl: proc(componentPath: string) = nil) =
    ## Idempotent attach/detach reconciliation. Called from the
    ## caller's main render-effect on every tick; detaches when
    ## ``useCanvas`` flips false, re-attaches when the backend
    ## changes.
    ##
    ## RS-M12: after every attach, fire ``sendCurrentStory`` so a
    ## freshly opened bridge always knows which story to mount.
    ## Subsequent story changes are picked up by the same render
    ## effect (the closure subscribes to ``vm.selectedStory``).
    ##
    ## RS-M13: when the active backend is ``pbTui`` the editor
    ## attaches an xterm.js Terminal (``attachTuiTerminalClient``)
    ## inside a sibling ``<div data-tui-terminal="true">`` instead of
    ## the canvas; the F/M/I clients keep using ``canvas`` for every
    ## other non-Web backend.
    let streaming = vm.streamingPreview
    if streaming == nil:
      return
    let activeBackend = vm.platform.val
    if useCanvas:
      let backendChanged = binding.attachedBackend != activeBackend
      let needsAttach = backendChanged or
        (activeBackend == pbTui and binding.tuiHandle == nil) or
        (activeBackend != pbTui and binding.handle == nil)
      if needsAttach:
        # Drop whichever transport (if any) is currently attached.
        if binding.handle != nil:
          detachBridgeClient(binding.handle)
          binding.handle = nil
        if binding.tuiHandle != nil:
          detachTuiTerminalClient(binding.tuiHandle)
          binding.tuiHandle = nil
        binding.lastSentStoryId = ""
        let url = bridgeUrlForBackend(activeBackend)
        if url.len > 0:
          let capturedBinding = binding
          let capturedVm = vm
          let onOpen = proc() =
            sendCurrentStory(capturedBinding, capturedVm)
          if activeBackend == pbTui:
            let host = ensureTuiHost(canvas)
            binding.tuiHost = host
            setTuiHostVisible(host, true)
            setCanvasHidden(canvas, true)
            # Round-10 composition density: the editor preview pane is
            # ~1080x720 px; at 80x24 the TUI filled only ~50-60 % of
            # the pane post-Wave-O font sizing. The launcher
            # (`isonim-examples/editor/backends/tui_term.nim`) defaults
            # to a matching 100x30 cell grid; xterm.js's `pickFontSize`
            # in `attachTuiTerminalClient` adapts the font to the host's
            # pixel dimensions so the denser grid fills the pane.
            binding.tuiHandle = attachTuiTerminalClient(
              streaming, host, url, 100, 30, onOpen)
          else:
            setCanvasHidden(canvas, false)
            if binding.tuiHost != nil:
              setTuiHostVisible(binding.tuiHost, false)
            binding.handle = attachBridgeClient(streaming, canvas, url,
                                                 onVectorDbl, onOpen)
          binding.attachedBackend = activeBackend
          installStoryPublisher(binding, streaming)
      sendCurrentStory(binding, vm)
    else:
      if binding.handle != nil:
        detachBridgeClient(binding.handle)
        binding.handle = nil
      if binding.tuiHandle != nil:
        detachTuiTerminalClient(binding.tuiHandle)
        binding.tuiHandle = nil
      if binding.tuiHost != nil:
        setTuiHostVisible(binding.tuiHost, false)
      setCanvasHidden(canvas, false)
      if binding.lastSentStoryId.len > 0 or binding.handle != nil or
         binding.tuiHandle != nil:
        binding.lastSentStoryId = ""
        streaming.clearStoryPublisher()
