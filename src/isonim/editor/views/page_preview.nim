## IsoNim Editor - Page Preview View.
##
## Renders project-owned preview documents in an editor-owned responsive frame.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  bgBase = "#0B1120"

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
  r.appendChild(frameHostNode, frame)
  r.appendChild(container, frameHostNode)
  r.enableDragScroll(frameHost)

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
    if preview.documentHtml.len > 0:
      r.setAttribute(previewFrame, "srcdoc", preview.documentHtml)
      r.setStyle(fallbackPanel, "display", "none")
      r.setStyle(previewFrame, "display", "block")
    else:
      r.setAttribute(previewFrame, "srcdoc", "")
      r.setStyle(fallbackPanel, "display", "flex")
      r.setStyle(previewFrame, "display", "none")

  container
