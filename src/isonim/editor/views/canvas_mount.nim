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
##     the canvas + wrapper to "fill the available preview area"
##     (Approach A: ``width: 100%; height: 100%; object-fit:
##     contain;``).
##
## See M-EVP-13 in
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.status.org``
## for the acceptance criteria this helper exists to satisfy.

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
  ## Approach A from M-EVP-13: when the canvas is the active surface,
  ## let it fill its parent (``width: 100%; height: 100%; object-fit:
  ## contain``) so the rendered box matches the pane size while the
  ## launcher's surface ratio is preserved. The parent must define a
  ## height — for ``page_preview.nim`` the device-frame supplies it;
  ## for ``component_detail.nim`` we set ``min-height`` on the row
  ## the wrapper lives in.
  ##
  ## Visibility of the per-affordance overlay children (hover label,
  ## selection outline, breadcrumb, handles) is *not* set here — that
  ## belongs to ``bindCanvasOverlayEffect`` whose reactive chain
  ## already hides them when the active backend is pbWeb.
  if active:
    r.setStyle(mount.wrapper, "display", "block")
    r.setStyle(mount.canvas, "display", "block")
    r.setStyle(mount.overlay, "display", "block")
    r.setStyle(mount.canvas, "width", "100%")
    r.setStyle(mount.canvas, "height", "100%")
    r.setStyle(mount.canvas, "object-fit", "contain")
    r.setAttribute(mount.canvas, "data-canvas-active", "true")
  else:
    r.setStyle(mount.wrapper, "display", "none")
    r.setStyle(mount.canvas, "display", "none")
    r.setStyle(mount.overlay, "display", "none")
    r.setAttribute(mount.canvas, "data-canvas-active", "false")

proc bindCanvasOverlayEffect*[R, E](r: R; vm: EditorVM;
                                     mount: CanvasMount[E]) =
  ## Reactive overlay-positioning effect. Mirrors the chain in
  ## ``component_detail.nim`` lines 1140-1290: paints the hover
  ## label, selection outline, breadcrumb, and (in ``emEdit``) the 8
  ## handles. Coordinates are mapped from F-packet pixel space to
  ## CSS pixel space via ``canvas.clientWidth / canvas.width``.
  let canvasEl = mount.canvas
  let overlayEl = mount.overlay
  let hoverLabel = mount.hoverLabel
  let hoverLabelText = mount.hoverLabelText
  let selectionOutline = mount.selectionOutline
  let breadcrumb = mount.breadcrumb
  let breadcrumbText = mount.breadcrumbText
  let handlesGroup = mount.handlesGroup
  let handleElems = mount.handleElems
  discard overlayEl

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
    discard manifestOpt
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
          let bOpt = canvas.boundsOf(hid.get)
          if bOpt.isSome:
            let b = bOpt.get
            let bx = b.x
            let by = b.y
            let bw = b.w
            let cnv = canvasEl
            let lbl = hoverLabel
            {.emit: ["""
              try {
                var c = """, cnv, """;
                var lbl = """, lbl, """;
                if (c && lbl && c.width > 0 && c.height > 0) {
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
      let bOpt = canvas.boundsOf(selectedId)
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
          let outline = selectionOutline
          {.emit: ["""
            try {
              var c = """, cnv, """;
              var o = """, outline, """;
              if (c && o && c.width > 0 && c.height > 0) {
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
            let bx = b.x
            let by = b.y
            let bw = b.w
            let bh = b.h
            for hi in 0 ..< 8:
              let hEl = handleElems[hi]
              let pos = handleNames[hi]
              {.emit: ["""
                try {
                  var c = """, cnv, """;
                  var h = """, hEl, """;
                  if (c && h && c.width > 0 && c.height > 0) {
                    var sx = c.clientWidth / c.width;
                    var sy = c.clientHeight / c.height;
                    var bx = """, bx, """ * sx;
                    var by = """, by, """ * sy;
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
      r.setStyle(selectionOutline, "display", "none")
      r.setStyle(breadcrumb, "display", "none")
      r.setStyle(handlesGroup, "display", "none")

when defined(js):
  type BridgeBinding* = ref object
    ## Lifecycle holder for a per-view bridge attachment. Stored on
    ## the view's closure so the next render-effect tick can detach
    ## and re-attach if the backend changed.
    handle*: BridgeClientHandle
    attachedBackend*: PreviewBackend

  proc newBridgeBinding*(): BridgeBinding =
    BridgeBinding(handle: nil, attachedBackend: pbWeb)

  proc attachIfNeeded*(binding: BridgeBinding; vm: EditorVM;
                       canvas: Element; useCanvas: bool;
                       onVectorDbl: proc(componentPath: string) = nil) =
    ## Idempotent attach/detach reconciliation. Called from the
    ## caller's main render-effect on every tick; detaches when
    ## ``useCanvas`` flips false, re-attaches when the backend
    ## changes.
    let streaming = vm.streamingPreview
    if streaming == nil:
      return
    let activeBackend = vm.platform.val
    if useCanvas:
      if binding.handle == nil or binding.attachedBackend != activeBackend:
        if binding.handle != nil:
          detachBridgeClient(binding.handle)
          binding.handle = nil
        let url = bridgeUrlForBackend(activeBackend)
        if url.len > 0:
          binding.handle = attachBridgeClient(streaming, canvas, url,
                                               onVectorDbl)
          binding.attachedBackend = activeBackend
    else:
      if binding.handle != nil:
        detachBridgeClient(binding.handle)
        binding.handle = nil
