## IsoNim Editor - Page Preview View.
##
## Renders project-owned preview documents in an editor-owned responsive frame.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/streaming_preview
import isonim/editor/views/canvas_mount

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
  # M-EVP-13: Pattern A canvas mount for Pages. When the active
  # backend is non-Web, the iframe hides and the canvas (fed by
  # `attachBridgeClient`) takes over. The canvas wrapper does NOT
  # live inside the device frame — the device frame is sized to the
  # user's chosen viewport, which for TUI is 80x24 cells (i.e. 80x24
  # CSS pixels under our `width: <viewport>px` rule). The launcher's
  # 640x288 surface would be a thin stretched strip inside that box
  # (the original M-EVP-13 bug report). Instead we paint the canvas
  # into a sibling pane that fills the available preview area, with
  # `object-fit: contain` preserving the launcher's surface ratio at
  # the maximum readable size.
  let pageCanvasMnt = renderCanvasMount[R, E](r, "data-page-project-canvas")
  var canvasPaneEl: E
  let canvasPaneNode = ui(r):
    tdiv(ref = canvasPaneEl,
          `data-page-canvas-pane` = "true",
          display = "none",
          flex = "1",
          min_width = "0",
          min_height = "0",
          padding = "16px",
          align_items = "stretch",
          justify_content = "stretch",
          flex_direction = "column"):
      discard
  r.setStyle(pageCanvasMnt.wrapper, "flex", "1")
  r.setStyle(pageCanvasMnt.wrapper, "min-height", "320px")
  r.appendChild(canvasPaneEl, pageCanvasMnt.wrapper)
  r.appendChild(frameHostNode, frame)
  r.appendChild(frameHostNode, canvasPaneNode)
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
    r.setStyle(deviceFrame, "border-radius",
      case viewport.kind
      of pvkDesktop, pvkLaptop, pvkWide, pvkUltrawide,
          pvkTui80x24, pvkTui120x40: "8px"
      else: "18px")
    r.setStyle(previewFrame, "width", "100%")
    r.setStyle(previewFrame, "height", "100%")
    # M-EVP-13: hide the viewport-sized device frame when the canvas
    # takes over (TUI cell viewports are 80x24, far too small for the
    # launcher's 640x288 surface to render legibly inside).
    r.setStyle(deviceFrame, "display", if useCanvas: "none" else: "flex")
    r.setStyle(canvasPaneEl, "display", if useCanvas: "flex" else: "none")
    if useCanvas:
      # Hide iframe + fallback; the canvas fills the dedicated pane.
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
      r.setAttribute(previewFrame, "srcdoc", preview.documentHtml)
      r.setStyle(fallbackPanel, "display", "none")
      r.setStyle(previewFrame, "display", "block")
    else:
      r.setAttribute(previewFrame, "srcdoc", "")
      r.setStyle(fallbackPanel, "display", "flex")
      r.setStyle(previewFrame, "display", "none")

    # M-EVP-13: canvas + overlay visibility + fit-to-pane CSS.
    r.applyCanvasFitStyle(pageCanvasMnt, useCanvas)

    when defined(js):
      pageBridgeBinding.attachIfNeeded(vm, pageCanvasMnt.canvas, useCanvas)

  # M-EVP-13: overlay positioning effect — hover label, selection
  # outline, breadcrumb, edit-mode handles. Shared with component_detail
  # and foundations_page via canvas_mount.nim.
  bindCanvasOverlayEffect(r, vm, pageCanvasMnt)

  container
