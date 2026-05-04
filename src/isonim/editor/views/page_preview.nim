## IsoNim Editor - Page Preview View.
##
## Renders project-owned preview documents in an editor-owned responsive frame.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/types
import isonim/editor/viewmodels

const
  bgBase = "#0B1120"
  bgCard = "#151D2E"
  bgSurface = "#1E293B"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"

proc makeButton[R, E](r: R; node: E; label: string) =
  r.setAttribute(node, "role", "button")
  r.setAttribute(node, "tabindex", "0")
  r.setAttribute(node, "aria-label", label)

proc bindModeButton[R, E](r: R; node: E; vm: EditorVM; mode: EditMode) =
  createRenderEffect proc() =
    let active = vm.editMode.val == mode
    r.setAttribute(node, "aria-pressed", if active: "true" else: "false")
    r.setStyle(node, "background-color", if active: accent else: "transparent")
    r.setStyle(node, "color", if active: textPrimary else: textMuted)

proc bindViewportButton[R, E](r: R; node: E; vm: EditorVM;
    viewport: PreviewViewport) =
  createRenderEffect proc() =
    let active = vm.viewport.val == viewport
    r.setAttribute(node, "aria-pressed", if active: "true" else: "false")
    r.setStyle(node, "background-color", if active: accent else: "transparent")
    r.setStyle(node, "color", if active: textPrimary else: textMuted)

proc bindPanelButton[R, E](r: R; node: E; vm: EditorVM;
    panel: EditorPanel) =
  let captured = panel
  createRenderEffect proc() =
    let panels = vm.panels.val
    let active =
      case captured
      of epSidebar: panels.sidebar
      of epInspector: panels.inspector
    r.setAttribute(node, "aria-pressed", if active: "true" else: "false")
    r.setStyle(node, "background-color", if active: accent else: "transparent")
    r.setStyle(node, "color", if active: textPrimary else: textMuted)

proc panelButton[R, E](r: R; vm: EditorVM; panel: EditorPanel;
    label, textValue: string): E =
  result = ui(r):
    tdiv(width = "28px", height = "24px", border_radius = "4px",
          display = "flex", align_items = "center", justify_content = "center",
          font_size = "13px", font_weight = "700",
          cursor = "pointer", transition = "all 0.15s"):
      text textValue
  r.makeButton(result, label)
  r.addEventListener(result, "click", proc() = vm.togglePanel(panel))
  r.addEventListener(result, "keydown", proc() = vm.togglePanel(panel))
  r.bindPanelButton(result, vm, panel)

proc viewportButton[R, E](r: R; vm: EditorVM; viewport: PreviewViewport): E =
  let label = previewViewportLabel(viewport)
  result = ui(r):
    tdiv(padding = "4px 10px", border_radius = "4px",
          font_size = "11px", font_weight = "500",
          cursor = "pointer", transition = "all 0.15s"):
      text label
  r.makeButton(result, "Preview " & label & " viewport")
  r.addEventListener(result, "click", proc() = vm.changeViewport(viewport))
  r.addEventListener(result, "keydown", proc() = vm.changeViewport(viewport))
  r.bindViewportButton(result, vm, viewport)

proc renderPagePreview*[R, E](r: R; vm: EditorVM): E =
  let container = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase):
      discard

  let toolbar = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          gap = "12px", height = "44px", min_height = "44px",
          padding = "0 16px", background_color = bgCard,
          border_bottom = "1px solid " & border):
      discard

  var titleNode: E
  var sourceNode: E
  let breadcrumb = ui(r):
    tdiv(display = "flex", flex_direction = "column", min_width = "0",
          gap = "2px"):
      span(ref = titleNode, font_size = "13px", font_weight = "600",
            color = textPrimary, white_space = "nowrap",
            overflow = "hidden", text_overflow = "ellipsis"):
        text ""
      span(ref = sourceNode, font_size = "11px", color = textDim,
            white_space = "nowrap", overflow = "hidden",
            text_overflow = "ellipsis"):
        text ""
  r.appendChild(toolbar, breadcrumb)

  let controls = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px"):
      discard

  let panelToggle = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px"):
      discard
  r.appendChild(panelToggle,
    panelButton[R, E](r, vm, epSidebar, "Toggle left sidebar", "\xE2\x87\xA4"))
  r.appendChild(panelToggle,
    panelButton[R, E](r, vm, epInspector, "Toggle right sidebar",
        "\xE2\x87\xA5"))
  r.appendChild(controls, panelToggle)

  let modeToggle = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px"):
      discard

  let viewBtn = ui(r):
    tdiv(padding = "4px 12px", border_radius = "4px",
          font_size = "11px", font_weight = "500",
          cursor = "pointer", transition = "all 0.15s"):
      text "View"
  let editBtn = ui(r):
    tdiv(padding = "4px 12px", border_radius = "4px",
          font_size = "11px", font_weight = "500",
          cursor = "pointer", transition = "all 0.15s"):
      text "Edit"
  r.makeButton(viewBtn, "Switch to view mode")
  r.makeButton(editBtn, "Switch to edit mode")
  r.addEventListener(viewBtn, "click", proc() = vm.setEditMode(emView))
  r.addEventListener(editBtn, "click", proc() = vm.setEditMode(emEdit))
  r.addEventListener(viewBtn, "keydown", proc() = vm.setEditMode(emView))
  r.addEventListener(editBtn, "keydown", proc() = vm.setEditMode(emEdit))
  r.bindModeButton(viewBtn, vm, emView)
  r.bindModeButton(editBtn, vm, emEdit)
  r.appendChild(modeToggle, viewBtn)
  r.appendChild(modeToggle, editBtn)
  r.appendChild(controls, modeToggle)

  let viewportToggle = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px"):
      discard
  for viewport in [pvDesktop, pvTablet, pvMobile]:
    r.appendChild(viewportToggle, viewportButton[R, E](r, vm, viewport))
  r.appendChild(controls, viewportToggle)
  r.appendChild(toolbar, controls)
  r.appendChild(container, toolbar)

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
          border = "0")
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
    let source =
      if preview.metadata.sourceFile.len > 0:
        preview.metadata.sourceFile & ":" & $preview.metadata.sourceLine
      else:
        previewViewportLabel(viewport) & " preview"

    r.setTextContent(titleNode, title)
    r.setTextContent(sourceNode, source)
    r.setTextContent(fallbackTitle, title)
    r.setTextContent(fallbackBody,
      if preview.bodyText.len > 0: preview.bodyText else: "Workspace page preview")
    r.setStyle(deviceFrame, "width", $width & "px")
    r.setStyle(deviceFrame, "height", $height & "px")
    r.setStyle(deviceFrame, "min-width", $width & "px")
    r.setStyle(deviceFrame, "min-height", $height & "px")
    r.setStyle(deviceFrame, "border-radius",
      if viewport == pvDesktop: "8px" else: "18px")
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
