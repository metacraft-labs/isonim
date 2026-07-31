## IsoNim Editor - Page Preview View.
##
## Renders project-owned preview documents in an editor-owned responsive frame.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/streaming_preview
import isonim/editor/views/canvas_mount
import isonim/editor/views/component_edit  # editablePreviewDocument (edit overlay)

const
  bgBase = "#0B1120"

proc vectorTargetDblclickHandler(vm: EditorVM; symbolName: string): proc() =
  ## M-EVP-8: open the vector editor for the symbol whose hit-test
  ## handle was double-clicked. The handler refuses the open when the
  ## active mode is not ``emEdit`` so the same handle works as a
  ## read-only marker in View / Comment modes.
  let captured = symbolName
  result = proc() =
    if vm.editMode.val != emEdit:
      return
    for group in vm.sidebar.groups.val:
      if group.kind == skVectorSymbol:
        var idx = 0
        for item in group.items:
          if item.name == captured:
            discard vm.openVectorEditor(StoryRef(
              group: item.group, name: item.name,
              kind: skVectorSymbol, index: idx))
            return
          inc idx

proc renderPagePreview*[R, E](r: R; vm: EditorVM): E =
  ## M-EVP-6: per-view inner toolbar removed. The canonical chrome bar
  ## lives in `renderPreviewChromeBar` above the view stack; the page
  ## preview body starts directly at the preview canvas.
  let container = ui(r):
    tdiv(class = "editor-preview",
          `data-page-preview` = "true",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase):
      discard

  var frameHost: E
  let frameHostNode = ui(r):
    tdiv(ref = frameHost,
          flex = "1", overflow = "auto", display = "flex",
          align_items = "flex-start", justify_content = "flex-start",
          padding = "16px", background_color = "#0D1525",
          background_image = "radial-gradient(circle, #1a2236 1px, transparent 1px)",
          background_size = "20px 20px"):
      discard

  var deviceFrame: E
  var fallbackPanel: E
  var fallbackTitle: E
  var fallbackBody: E
  var previewFrame: E
  let frame = ui(r):
    tdiv(ref = deviceFrame,
          `aria-label` = "Preview device frame",
          background_color = "#FFFFFF",
          border = "1px solid rgba(255,255,255,0.12)",
          box_shadow = "0 20px 60px rgba(0,0,0,0.38)",
          overflow = "hidden", display = "flex",
          flex_direction = "column", flex = "0 0 auto",
          transition = "width 0.15s"):
      tdiv(ref = fallbackPanel,
            class = "editor-preview-fallback",
            padding = "24px", display = "none",
            flex_direction = "column", gap = "10px",
            background_color = "#FFFFFF", color = "#111827"):
        span(ref = fallbackTitle, font_size = "24px", font_weight = "800"):
          text ""
        span(ref = fallbackBody, font_size = "13px", color = "#64748B"):
          text ""
      iframe(ref = previewFrame,
          title = "Project preview",
          width = "100%",
          height = "100%",
          border = "0",
          `data-page-project-frame` = "true")
  # ERV-M1: Pattern A canvas mount for Pages. When the active
  # backend is non-Web, the iframe hides and the canvas (fed by
  # `attachBridgeClient`) takes over. The canvas wrapper now mounts
  # as a sibling of the iframe deviceFrame inside `frameHostNode` so
  # it inherits the same dotted-grid preview pane chrome and is
  # sized to the user's chosen viewport — matching the iframe
  # deviceFrame's white-card / hairline-border / drop-shadow look
  # and eliminating the dark letterbox bands the old `canvasPaneEl`
  # produced.
  #
  # The launcher's surface size matches the wrapper exactly: the
  # ``publishResize`` call at the bottom of the render effect
  # advertises viewport dims; the JS shim scales by
  # ``window.devicePixelRatio`` so the launcher renders at physical
  # pixels; ``ensureSize`` reseeds ``canvas.style.width =
  # intrinsic_px / dpr`` = viewport_px, which equals the wrapper's
  # CSS px. The canvas therefore fills the wrapper edge-to-edge with
  # no letterbox or stretching.
  #
  # TUI special case: cell viewports (80×24) would size the wrapper
  # to 80×24 px and make xterm.js unreadable. For those we fall back
  # to filling the preview pane (``flex: 1``).
  let pageCanvasMnt = renderCanvasMount[R, E](r, "data-page-project-canvas")
  r.appendChild(frameHostNode, frame)
  r.appendChild(frameHostNode, pageCanvasMnt.wrapper)
  # M-EVP-13: breadcrumb sits in the host scroll region directly below
  # the device frame so the canvas selection's componentPath is always
  # readable, even when the device frame is sized to a small viewport
  # (e.g. phone). Keep it inside `frameHostNode` so drag-scroll still
  # works.
  r.setStyle(pageCanvasMnt.breadcrumb, "margin", "12px 16px 0 16px")
  r.setStyle(pageCanvasMnt.breadcrumb, "align-self", "flex-start")
  r.appendChild(frameHostNode, pageCanvasMnt.breadcrumb)
  r.appendChild(container, frameHostNode)
  r.enableDragScroll(frameHost)

  # M-EVP-8: vector-symbol hit-test handles. The Nim-rendered tree gets
  # one handle per symbol referenced by the current story. Each handle:
  #   * carries ``data-isonim-vector-symbol="<name>"`` so the iframe's
  #     internal dblclick handler can stencil-match the same marker;
  #   * carries ``data-vector-symbol-target="<name>"`` so headless
  #     tests can find and double-click it directly;
  #   * is mounted inside the device frame's fallback panel surface so
  #     it inherits the editor mode and doesn't compete with the
  #     iframe's render path.
  var hitTestRoot: E
  let hitTestNode = ui(r):
    tdiv(ref = hitTestRoot,
          `data-vector-hittest-host` = "true",
          position = "absolute", top = "0", left = "0",
          width = "1px", height = "1px", overflow = "hidden")
  r.appendChild(deviceFrame, hitTestNode)

  createRenderEffect proc() =
    r.clearChildren(hitTestRoot)
    let story = vm.selectedStory.val
    var handles: seq[string]
    for group in vm.sidebar.groups.val:
      if group.kind == story.kind:
        for item in group.items:
          if item.group == story.group and item.name == story.name:
            for sym in item.usesVectorSymbols:
              if sym notin handles:
                handles.add sym
    for symName in handles:
      let captured = symName
      var handleEl: E
      let handle = ui(r):
        tdiv(ref = handleEl,
              `data-isonim-vector-symbol` = captured,
              `data-vector-symbol-target` = captured,
              `aria-label` = "Vector symbol " & captured & " hit test",
              width = "1px", height = "1px")
      let onDblClick = vectorTargetDblclickHandler(vm, captured)
      r.addEventListener(handleEl, "dblclick", onDblClick)
      r.appendChild(hitTestRoot, handle)

  # M-EVP-13: bridge attach/detach for the page-preview canvas.
  when defined(js):
    let pageBridgeBinding = newBridgeBinding()

  createRenderEffect proc() =
    let preview = vm.preview.current.val
    let viewport = vm.viewport.val
    let width = previewViewportWidth(viewport)
    let height = previewViewportHeight(viewport)
    let title =
      if preview.title.len > 0:
        preview.title
      elif vm.selectedStory.val.name.len > 0:
        vm.selectedStory.val.group & " / " & vm.selectedStory.val.name
      else:
        "Project preview"

    # M-EVP-13: non-Web backend → canvas takes over for the page-
    # preview view. Gate on the active story being a Page (skPage)
    # so the page-preview module does not race with
    # component_detail.nim / foundations_page.nim for the same
    # bridge URL when another view is active (all three view roots
    # are mounted concurrently in the editor's view stack and
    # display-toggled, so unconditional attach would open three
    # WebSockets to the same launcher).
    let isPageStory = vm.selectedStory.val.kind == skPage
    let useCanvas = isPageStory and vm.platform.val != pbWeb

    r.setTextContent(fallbackTitle, title)
    r.setTextContent(fallbackBody,
      if preview.bodyText.len > 0: preview.bodyText else: "Workspace page preview")
    r.setStyle(deviceFrame, "width", $width & "px")
    r.setStyle(deviceFrame, "height", $height & "px")
    r.setStyle(deviceFrame, "min-width", $width & "px")
    r.setStyle(deviceFrame, "min-height", $height & "px")
    let borderRadius =
      case viewport.kind
      of pvkDesktop, pvkLaptop, pvkWide, pvkUltrawide,
          pvkTui80x24, pvkTui120x40: "8px"
      else: "18px"
    r.setStyle(deviceFrame, "border-radius", borderRadius)
    r.setStyle(previewFrame, "width", "100%")
    r.setStyle(previewFrame, "height", "100%")
    # M-EVP-13: hide the viewport-sized device frame when the canvas
    # takes over.
    r.setStyle(deviceFrame, "display", if useCanvas: "none" else: "flex")
    if useCanvas:
      # Hide iframe + fallback; the canvas wrapper takes over.
      r.setAttribute(previewFrame, "srcdoc", "")
      r.setStyle(fallbackPanel, "display", "none")
      r.setStyle(previewFrame, "display", "none")
    elif vm.platform.val == pbWeb and preview.documentHtml.len > 0:
      # CHRM-M5 Fix B: ``documentHtml`` is now Web-only. The Web
      # composition root renders inside the iframe via srcdoc
      # because there's no streaming launcher for Web (the editor
      # itself is HTML — see isonim-examples/CLAUDE.md "Try the
      # editor"). For every non-Web backend the canvas path above
      # is the live stream; if it's not active the fallback panel
      # is the empty-state surface (no more HTML-themed iframe).
      #
      # Layout-invariance fix: entering Comment/Edit no longer swaps a
      # page story to the source-edit canvas (see ``setEditMode`` in
      # viewmodels.nim). Instead this SAME device-frame render stays up
      # and — in emComment/emEdit — the editor's selection bridge is
      # injected into the SAME ``documentHtml`` via
      # ``editablePreviewDocument`` (overlay-only CSS/JS; it does not
      # alter the base page layout). The window-level selection bridge
      # is already installed by ``renderComponentEditView`` at shell
      # build time, so the injected script's ``isonim-preview-element-
      # selected`` events flow straight into ``vm.inspector`` and the
      # property inspector lights up on the same viewport-sized page
      # render the operator saw in View mode.
      let srcdoc =
        if vm.editMode.val == emView:
          preview.documentHtml
        else:
          editablePreviewDocument(preview.documentHtml, preview.metadata,
            vm.editMode.val)
      r.setAttribute(previewFrame, "srcdoc", srcdoc)
      r.setStyle(fallbackPanel, "display", "none")
      r.setStyle(previewFrame, "display", "block")
    else:
      r.setAttribute(previewFrame, "srcdoc", "")
      r.setStyle(fallbackPanel, "display", "flex")
      r.setStyle(previewFrame, "display", "none")

    # ERV-M1: canvas + overlay visibility + device-frame chrome.
    r.applyCanvasFitStyle(pageCanvasMnt, useCanvas)
    if useCanvas:
      # Size the canvas wrapper exactly like the iframe deviceFrame
      # so the canvas (sized by ``ensureSize`` to intrinsic_px / dpr
      # = viewport_px in CSS terms) lands flush against the wrapper
      # edges, replacing the previous dark letterbox bands.
      #
      # TUI cell viewports (80×24) are too small for an 80×24 px
      # wrapper to be readable — fall back to filling the preview
      # pane (the legacy ``canvasPaneEl`` behaviour) so xterm.js has
      # room to pick a usable font size.
      if viewport.isCells:
        r.setStyle(pageCanvasMnt.wrapper, "width", "100%")
        r.setStyle(pageCanvasMnt.wrapper, "height", "100%")
        r.setStyle(pageCanvasMnt.wrapper, "min-width", "320px")
        r.setStyle(pageCanvasMnt.wrapper, "min-height", "320px")
        r.setStyle(pageCanvasMnt.wrapper, "flex", "1 1 auto")
        r.setStyle(pageCanvasMnt.wrapper, "border-radius", "8px")
      else:
        r.setStyle(pageCanvasMnt.wrapper, "width", $width & "px")
        r.setStyle(pageCanvasMnt.wrapper, "height", $height & "px")
        r.setStyle(pageCanvasMnt.wrapper, "min-width", $width & "px")
        r.setStyle(pageCanvasMnt.wrapper, "min-height", $height & "px")
        r.setStyle(pageCanvasMnt.wrapper, "flex", "0 0 auto")
        r.setStyle(pageCanvasMnt.wrapper, "border-radius", borderRadius)

    when defined(js):
      pageBridgeBinding.attachIfNeeded(vm, pageCanvasMnt.canvas, useCanvas)
      # VRS-M2: tell the launcher to re-render at the user-selected
      # viewport. The publisher closure (installed by
      # ``installStoryPublisher`` inside ``attachIfNeeded``) routes
      # to ``sendResize`` over the F/M/I bridge; the launcher's
      # ``StoryDispatchSink → resizingSink`` chain mutates its
      # ``AnyFrameSource`` width/height and the next F frame
      # carries the new dimensions, which the JS shim's
      # ``ensureSize`` then reseeds onto ``canvas.width`` /
      # ``canvas.height``. Web short-circuits in ``publishResize``
      # because Web has no streaming bridge.
      if useCanvas and vm.streamingPreview != nil:
        publishResize(vm.streamingPreview, width, height)

  # M-EVP-13: overlay positioning effect — hover label, selection
  # outline, breadcrumb, edit-mode handles. Shared with component_detail
  # and foundations_page via canvas_mount.nim.
  bindCanvasOverlayEffect(r, vm, pageCanvasMnt)

  container
