## IsoNim Editor — Vector Graphics Editor View.
##
## Embedded SVG editor for design system symbols (icons, illustrations).
## Left: tool palette. Center: SVG canvas with grid. Right: properties
## (stroke, fill, transform). Bottom: layers panel.

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types

when defined(js):
  import isonim/editor/browser_vector_adapter

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgCard = "#151D2E"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"

type
  ToolDef = object
    name: string
    icon: string
    shortcut: string

proc vectorTools(): seq[ToolDef] =
  @[
    ToolDef(name: "Select", icon: "\xE2\x86\x96", shortcut: "V"), # ↖
    ToolDef(name: "Pen", icon: "\xE2\x9C\x8F", shortcut: "P"), # ✏
    ToolDef(name: "Pencil", icon: "\xE2\x9C\x8E", shortcut: "N"), # ✎
    ToolDef(name: "Rectangle", icon: "\xE2\x96\xAD", shortcut: "R"), # ▭
    ToolDef(name: "Ellipse", icon: "\xE2\x97\x8B", shortcut: "O"), # ○
    ToolDef(name: "Polygon", icon: "\xE2\xAC\xA0", shortcut: "Y"), # ⬠
    ToolDef(name: "Star", icon: "\xE2\x98\x86", shortcut: "S"), # ☆
    ToolDef(name: "Line", icon: "\xE2\x95\xB1", shortcut: "L"), # ╱
    ToolDef(name: "Text", icon: "T", shortcut: "T"),
    ToolDef(name: "Path Edit", icon: "\xE2\x97\x87", shortcut: "A"), # ◇
  ]

func vectorToolAt(index: int): VectorTool =
  case index
  of 0: vtSelect
  of 1: vtPen
  of 2: vtPencil
  of 3: vtRectangle
  of 4: vtEllipse
  of 5: vtPolygon
  of 6: vtStar
  of 7: vtLine
  of 8: vtText
  else: vtPathEdit

proc vectorToolHandler(vm: EditorVM; tool: VectorTool): proc() =
  let captured = tool
  result = proc() = vm.setVectorTool(captured)

proc vectorLayerHandler(vm: EditorVM; index: int): proc() =
  let captured = index
  result = proc() = discard vm.selectVectorSymbol(captured)

proc isActiveVectorTool(vm: EditorVM; tool: VectorTool): bool =
  vm.vectorEditor.activeTool.val == tool

proc isSelectedVectorLayer(vm: EditorVM; index: int): bool =
  vm.vectorEditor.selectedSymbol.val == index

proc bindVectorToolState[R, E](r: R; node: E; vm: EditorVM;
    tool: VectorTool) =
  let captured = tool
  createRenderEffect proc() =
    let isActive = vm.isActiveVectorTool(captured)
    r.setAttribute(node, "aria-pressed", if isActive: "true" else: "false")
    r.setStyle(node, "background-color",
        if isActive: accent else: "transparent")
    r.setStyle(node, "color", if isActive: textPrimary else: textMuted)

proc bindVectorLayerState[R, E](r: R; node: E; vm: EditorVM; index: int) =
  let captured = index
  createRenderEffect proc() =
    let isSelected = vm.isSelectedVectorLayer(captured)
    r.setAttribute(node, "aria-selected", if isSelected: "true" else: "false")
    r.setStyle(node, "background-color",
      if isSelected: accent & "22" else: "transparent")

proc bindVectorSaveState[R, E](r: R; node: E; vm: EditorVM) =
  createRenderEffect proc() =
    let command = vm.evaluateCommand(eckSave)
    let disabled = command.status == ecsDisabled
    r.setAttribute(node, "aria-disabled", if disabled: "true" else: "false")
    r.setAttribute(node, "data-vector-source-stage",
      $vm.workspaceEditStage.val)
    r.setAttribute(node, "data-vector-pending-source-edits",
      $vm.inspector.pendingSourceEdits.val.len)
    r.setStyle(node, "opacity", if disabled: "0.5" else: "1")

proc renderVectorEditor*[R, E](r: R; vm: EditorVM): E =
  ## M-EVP-6 note: the vector editor keeps its own top toolbar (title +
  ## boolean ops + zoom + Save + Export SVG) because the shared chrome
  ## bar is hidden while the vector view is active (`shell.nim` sets
  ## `display: none` on `chromeBarEl` for `evVectorEditor`). The
  ## acceptance "exactly one top bar above the view body" already holds
  ## for the vector editor — there is no duplicate to drop. M-EVP-8
  ## tracks the broader vector-affordance refactor (boolean ops, export,
  ## usage-context panel).
  let tools = vectorTools()
  var fabricHost: E

  let container = ui(r):
    tdiv(class = "editor-preview",
          `data-vector-editor` = "true",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase):

      # Top toolbar
      var backBtn: E
      var symbolNameLabel: E
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            height = "44px", min_height = "44px", padding = "0 16px",
            background_color = bgCard,
            `data-vector-editor-toolbar` = "true",
            border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "10px"):
          # M-EVP-8: back affordance. Only rendered when the vector
          # editor is active; the shell's view-stack effect already
          # gates the whole subtree on ``evVectorEditor`` so the
          # button is intrinsically scoped to the right view.
          tdiv(ref = backBtn,
                `data-vector-editor-back` = "true",
                `role` = "button", tabindex = "0",
                `aria-label` = "Close vector editor",
                display = "flex", align_items = "center",
                justify_content = "center",
                width = "26px", height = "26px",
                border_radius = "4px", cursor = "pointer",
                color = textSecondary, font_size = "16px",
                background_color = bgSurface,
                border = "1px solid " & border):
            text "\xE2\x86\x90" # ←
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text "Vector Editor"
          span(ref = symbolNameLabel,
                font_size = "11px", color = textDim):
            text "\xE2\x80\x94 check-icon.svg"
        # Boolean operations are delegated to Paper.js, a supplemental path backend.
        tdiv(display = "flex", align_items = "center", gap = "2px",
              background_color = bgSurface, border_radius = "6px",
              padding = "3px", border = "1px solid " & border):
          for op in [("Union", "boolean-unite"), ("Sub", "boolean-subtract"),
              ("Inter", "boolean-intersect"), ("Excl", "boolean-exclude")]:
            let opLabel = op[0]
            let opAction = op[1]
            tdiv(padding = "4px 8px", border_radius = "4px",
                  font_size = "10px", font_weight = "500",
                  color = textSecondary, cursor = "pointer",
                  `role` = "button", tabindex = "0",
                  `aria-label` = "Vector " & opLabel,
                  `data-vector-action` = opAction,
                  title = opLabel & " via Paper.js path backend"):
              text opLabel
        # Zoom / export
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "11px", color = textMuted):
            text "100%"
          var saveTop: E
          tdiv(ref = saveTop,
                padding = "4px 10px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                background_color = bgSurface, color = textPrimary,
                border = "1px solid " & border,
                cursor = "pointer",
                `role` = "button", tabindex = "0",
                `aria-label` = "Save vector source edits"):
            text "Save"
          tdiv(padding = "4px 10px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                background_color = accent, color = textPrimary,
                cursor = "pointer"):
            text "Export SVG"
          block:
            let save = proc() =
              let state = vm.runEditorCommand(eckSave)
              when defined(js):
                if state.status == ecsSucceeded:
                  markFabricVectorSourceSaved(fabricHost)
            r.addEventListener(saveTop, "click", save)
            r.addEventListener(saveTop, "keydown", save)
            r.bindVectorSaveState(saveTop, vm)

      block:
        # M-EVP-8: wire the back affordance + reactive symbol-name label.
        let close = proc() = vm.closeVectorEditor()
        r.addEventListener(backBtn, "click", close)
        r.addEventListener(backBtn, "keydown", close)
        let capturedVm = vm
        createRenderEffect proc() =
          let target = capturedVm.vectorEditorTarget.val
          let label =
            if target.isSome:
              "\xE2\x80\x94 " & target.get.name
            else:
              ""
          r.setTextContent(symbolNameLabel, label)

  # Main area: tool palette + canvas + properties
  let mainArea = ui(r):
    tdiv(flex = "1", display = "flex", overflow = "hidden")

  # Left: Tool palette
  let toolPalette = ui(r):
    tdiv(width = "44px", min_width = "44px",
          display = "flex", flex_direction = "column",
          align_items = "center", gap = "2px",
          padding = "8px 0",
          background_color = bgSidebar,
          border_right = "1px solid " & border)

  for i, tool in tools:
    let tIcon = tool.icon
    let tName = tool.name
    let toolKind = vectorToolAt(i)
    let chooseTool = vectorToolHandler(vm, toolKind)
    let toolBtn = ui(r):
      tdiv(width = "32px", height = "32px",
            display = "flex", align_items = "center", justify_content = "center",
            border_radius = "6px", cursor = "pointer",
            font_size = "14px",
            transition = "background-color 0.1s",
            background_color = (if vm.isActiveVectorTool(
                toolKind): accent else: "transparent"),
            color = (if vm.isActiveVectorTool(
                toolKind): textPrimary else: textMuted)):
        text tIcon
    r.setAttribute(toolBtn, "role", "button")
    r.setAttribute(toolBtn, "tabindex", "0")
    r.setAttribute(toolBtn, "aria-label", "Select " & tName & " vector tool")
    r.addEventListener(toolBtn, "click", chooseTool)
    r.addEventListener(toolBtn, "keydown", chooseTool)
    r.bindVectorToolState(toolBtn, vm, toolKind)
    r.appendChild(toolPalette, toolBtn)

  # Separator
  let sep = ui(r):
    tdiv(width = "20px", height = "1px",
          background_color = border, margin = "4px 0")
  r.appendChild(toolPalette, sep)

  # Grid / snap toggles
  let gridBtn = ui(r):
    tdiv(width = "32px", height = "32px",
          display = "flex", align_items = "center", justify_content = "center",
          border_radius = "6px", cursor = "pointer",
          font_size = "10px", color = accent,
          background_color = bgSurface):
      text "#"
  r.setAttribute(gridBtn, "role", "button")
  r.setAttribute(gridBtn, "tabindex", "0")
  r.setAttribute(gridBtn, "aria-label", "Toggle vector grid")
  createRenderEffect proc() =
    r.setAttribute(gridBtn, "aria-pressed",
      if vm.vectorEditor.showGrid.val: "true" else: "false")
    r.setStyle(gridBtn, "background-color",
      if vm.vectorEditor.showGrid.val: bgSurface else: "transparent")
    r.setStyle(gridBtn, "color",
      if vm.vectorEditor.showGrid.val: accent else: textMuted)
  r.addEventListener(gridBtn, "click", proc() =
    vm.vectorEditor.showGrid.val = not vm.vectorEditor.showGrid.val)
  r.addEventListener(gridBtn, "keydown", proc() =
    vm.vectorEditor.showGrid.val = not vm.vectorEditor.showGrid.val)
  r.appendChild(toolPalette, gridBtn)

  let snapBtn = ui(r):
    tdiv(width = "32px", height = "32px",
          display = "flex", align_items = "center", justify_content = "center",
          border_radius = "6px", cursor = "pointer",
          font_size = "11px", color = textMuted):
      text "\xE2\xAF\xAE" # magnet
  r.setAttribute(snapBtn, "role", "button")
  r.setAttribute(snapBtn, "tabindex", "0")
  r.setAttribute(snapBtn, "aria-label", "Toggle vector snap")
  createRenderEffect proc() =
    r.setAttribute(snapBtn, "aria-pressed",
      if vm.vectorEditor.snapToGrid.val: "true" else: "false")
    r.setStyle(snapBtn, "background-color",
      if vm.vectorEditor.snapToGrid.val: bgSurface else: "transparent")
    r.setStyle(snapBtn, "color",
      if vm.vectorEditor.snapToGrid.val: accent else: textMuted)
  r.addEventListener(snapBtn, "click", proc() =
    vm.vectorEditor.snapToGrid.val = not vm.vectorEditor.snapToGrid.val)
  r.addEventListener(snapBtn, "keydown", proc() =
    vm.vectorEditor.snapToGrid.val = not vm.vectorEditor.snapToGrid.val)
  r.appendChild(toolPalette, snapBtn)

  r.appendChild(mainArea, toolPalette)

  # Center: Fabric-backed SVG Canvas
  let canvas = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
          overflow = "hidden"):

      tdiv(flex = "1", position = "relative",
            background_color = bgBase,
            background_image = "linear-gradient(" & borderFaint &
            " 1px, transparent 1px), linear-gradient(90deg, " & borderFaint &
            " 1px, transparent 1px)",
            background_size = "16px 16px",
            overflow = "auto", padding = "28px 28px 40px 28px"):

        tdiv(display = "flex", flex_direction = "column", gap = "8px",
              min_width = "760px", width = "760px"):
          tdiv(display = "flex", align_items = "center",
                justify_content = "space-between"):
            span(font_size = "11px", color = textMuted):
              text "Fabric.js adapter handles selection, hit testing, transforms, grouping, drawing, and SVG export."
            tdiv(display = "flex", gap = "6px"):
              for action in ["import-sample", "zoom-in", "zoom-out", "pan-right",
                  "set-fill", "set-stroke", "duplicate", "delete", "group",
                  "ungroup", "transform-selection", "move-segment",
                  "path-insert", "path-delete-node", "path-convert-smooth",
                  "path-handle-drag", "path-nudge-right", "path-undo",
                  "path-redo", "export"]:
                let actionName = action
                var actionBtn: E
                tdiv(ref = actionBtn,
                      `role` = "button", tabindex = "0",
                      `aria-label` = "Vector " & actionName,
                      `data-vector-action` = actionName,
                      padding = "4px 8px", border_radius = "4px",
                      background_color = bgSurface,
                      border = "1px solid " & border,
                      color = textSecondary, font_size = "11px",
                      cursor = "pointer"):
                  text actionName

          tdiv(ref = fabricHost,
                `data-vector-adapter` = "fabric",
                `data-vector-library-backed` = "pending",
                width = "720px", height = "420px",
                background_color = bgCard,
                border = "1px solid " & border,
                border_radius = "4px",
                overflow = "hidden")

        # Rulers (top + left)
        tdiv(position = "absolute", top = "0", left = "0", right = "0",
              height = "20px", background_color = bgSurface,
              border_bottom = "1px solid " & border, opacity = "0.8")
        tdiv(position = "absolute", top = "0", left = "0", bottom = "0",
              width = "20px", background_color = bgSurface,
              border_right = "1px solid " & border, opacity = "0.8")

      # Bottom: Layers panel
      tdiv(height = "120px", min_height = "120px",
            background_color = bgSidebar,
            border_top = "1px solid " & border,
            display = "flex", flex_direction = "column"):
        tdiv(display = "flex", align_items = "center",
              justify_content = "space-between",
              padding = "6px 12px",
              border_bottom = "1px solid " & borderFaint):
          span(font_size = "10px", font_weight = "600", color = textSecondary,
                text_transform = "uppercase", letter_spacing = "0.5px"):
            text "Layers"
          tdiv(font_size = "12px", color = textMuted, cursor = "pointer"):
            text "+"
        # Layer list
        tdiv(flex = "1", overflow_y = "auto", padding = "4px 0"):
          for i, layer in ["Circle", "Rectangle", "Line"]:
            let lName = layer
            let selectLayer = vectorLayerHandler(vm, i)
            var layerNode: E
            tdiv(display = "flex", align_items = "center", gap = "8px",
                  ref = layerNode,
                  `role` = "button", tabindex = "0",
                  `aria-label` = "Select vector layer " & lName,
                  `aria-selected` = (if vm.isSelectedVectorLayer(
                      i): "true" else: "false"),
                  onclick = selectLayer,
                  onkeydown = selectLayer,
                  padding = "4px 12px", cursor = "pointer",
                  background_color = (if vm.isSelectedVectorLayer(i): accent &
                      "22" else: "transparent")):
              span(font_size = "10px", color = textMuted):
                text "\xE2\x97\x8B"
              span(font_size = "11px",
                    color = (if vm.isSelectedVectorLayer(
                        i): textPrimary else: textSecondary)):
                text lName
              tdiv(margin_left = "auto", font_size = "10px",
                    color = textDim, cursor = "pointer"):
                text "\xF0\x9F\x91\x81"
            block:
              r.bindVectorLayerState(layerNode, vm, i)

  r.appendChild(mainArea, canvas)
  when defined(js):
    r.addEventListener(fabricHost, "isonim-vector-source-change", proc() =
      let exported = currentFabricVectorSvg(fabricHost)
      if exported.len > 0:
        discard vm.commitBrowserVectorSvg(exported))
    createRenderEffect proc() =
      var symbolName = "Vector Symbol"
      var svgContent = ""
      let symbols = vm.vectorEditor.symbols.val
      let selected = vm.vectorEditor.selectedSymbol.val
      if selected >= 0 and selected < symbols.len:
        symbolName = symbols[selected].name
        svgContent = symbols[selected].svgContent
      mountFabricVectorEditor(fabricHost, symbolName, svgContent,
        vm.vectorEditor.activeTool.val.toolSlug)

  # Right: Properties panel
  let propsPanel = ui(r):
    tdiv(width = "220px", min_width = "220px",
          display = "flex", flex_direction = "column",
          background_color = bgSidebar,
          border_left = "1px solid " & border,
          overflow_y = "auto"):

      # Transform section
      tdiv(padding = "12px", display = "flex", flex_direction = "column",
            gap = "8px", border_bottom = "1px solid " & borderFaint):
        span(font_size = "10px", font_weight = "600", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Transform"
        for prop in [("X", "100"), ("Y", "80"), ("W", "80"), ("H", "80"), ("R", "0\xC2\xB0")]:
          let pLabel = prop[0]
          let pVal = prop[1]
          tdiv(display = "flex", align_items = "center", gap = "6px"):
            span(font_size = "10px", color = textMuted, width = "16px"):
              text pLabel
            tdiv(flex = "1", height = "24px", background_color = bgSurface,
                  border = "1px solid " & border, border_radius = "3px",
                  display = "flex", align_items = "center", padding = "0 6px"):
              span(font_size = "10px", color = textPrimary,
                    font_family = "monospace"):
                text pVal

      # Fill section
      tdiv(padding = "12px", display = "flex", flex_direction = "column",
            gap = "8px", border_bottom = "1px solid " & borderFaint):
        span(font_size = "10px", font_weight = "600", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Fill"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(width = "24px", height = "24px", border_radius = "4px",
                background_color = "transparent",
                border = "2px solid " & textDim)
          span(font_size = "11px", color = textMuted):
            text "No fill"

      # Stroke section
      tdiv(padding = "12px", display = "flex", flex_direction = "column",
            gap = "8px", border_bottom = "1px solid " & borderFaint):
        span(font_size = "10px", font_weight = "600", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Stroke"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(width = "24px", height = "24px", border_radius = "4px",
                background_color = accent)
          span(font_size = "11px", color = textPrimary,
                font_family = "monospace"):
            text accent
        for prop in [("Width", "2"), ("Cap", "Round"), ("Join", "Miter")]:
          let pLabel = prop[0]
          let pVal = prop[1]
          tdiv(display = "flex", align_items = "center", gap = "6px"):
            span(font_size = "10px", color = textMuted, width = "36px"):
              text pLabel
            tdiv(flex = "1", height = "24px", background_color = bgSurface,
                  border = "1px solid " & border, border_radius = "3px",
                  display = "flex", align_items = "center", padding = "0 6px"):
              span(font_size = "10px", color = textPrimary):
                text pVal

      # Accessibility section
      tdiv(padding = "12px", display = "flex", flex_direction = "column",
            gap = "8px"):
        span(font_size = "10px", font_weight = "600", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Accessibility"
        tdiv(display = "flex", flex_direction = "column", gap = "4px"):
          span(font_size = "10px", color = textMuted):
            text "Title"
          tdiv(height = "24px", background_color = bgSurface,
                border = "1px solid " & border, border_radius = "3px",
                display = "flex", align_items = "center", padding = "0 6px"):
            span(font_size = "10px", color = textDim, font_style = "italic"):
              text "Check icon"
        tdiv(display = "flex", flex_direction = "column", gap = "4px"):
          span(font_size = "10px", color = textMuted):
            text "Description"
          tdiv(height = "24px", background_color = bgSurface,
                border = "1px solid " & border, border_radius = "3px",
                display = "flex", align_items = "center", padding = "0 6px"):
            span(font_size = "10px", color = textDim, font_style = "italic"):
              text "Indicates completion"

  r.appendChild(mainArea, propsPanel)

  # M-EVP-8: usage-context companion panel. The centre column splits
  # into [vector canvas | usages]. The split is only mounted when the
  # vector editor has a target — until then the canvas fills the full
  # width. The right split is reactive: the layout switches between
  # the stacked variant (<=3 usages) and the carousel variant (>3
  # usages) by toggling display on the two host containers.
  let splitRoot = ui(r):
    tdiv(`data-vector-editor-split` = "true",
          flex = "1", display = "flex", flex_direction = "row",
          min_height = "0", overflow = "hidden")

  let leftSplit = ui(r):
    tdiv(`data-vector-editor-canvas-split` = "true",
          flex = "1.5", display = "flex", flex_direction = "column",
          min_width = "0", overflow = "hidden")
  r.appendChild(leftSplit, mainArea)

  var stackedPanel: E
  var carouselPanel: E
  var carouselPrev: E
  var carouselNext: E
  var carouselDots: E
  var carouselContent: E
  var usagePanelRoot: E
  let rightSplit = ui(r):
    tdiv(ref = usagePanelRoot,
          `data-vector-editor-usage-split` = "true",
          flex = "1", display = "none", flex_direction = "column",
          min_width = "0", overflow_y = "auto",
          background_color = bgSidebar,
          border_left = "1px solid " & border):
      tdiv(padding = "10px 14px",
            border_bottom = "1px solid " & borderFaint,
            color = textSecondary, font_size = "11px",
            font_weight = "600",
            text_transform = "uppercase",
            letter_spacing = "0.5px"):
        text "Usage Context"
      tdiv(ref = stackedPanel,
            `data-vector-usage-layout` = "split",
            display = "none", flex_direction = "column",
            gap = "10px", padding = "10px 12px")
      tdiv(ref = carouselPanel,
            `data-vector-usage-carousel` = "true",
            `data-vector-usage-layout` = "carousel",
            `data-vector-usage-index` = "0",
            display = "none", flex_direction = "column",
            gap = "8px", padding = "10px 12px"):
        tdiv(ref = carouselContent,
              `data-vector-usage-carousel-content` = "true",
              display = "flex", flex_direction = "column",
              gap = "6px", min_height = "120px",
              padding = "8px",
              background_color = bgCard,
              border = "1px solid " & border,
              border_radius = "6px")
        tdiv(display = "flex", align_items = "center",
              justify_content = "space-between",
              gap = "8px"):
          tdiv(ref = carouselPrev,
                `data-vector-usage-prev` = "true",
                `role` = "button", tabindex = "0",
                `aria-label` = "Previous vector usage",
                padding = "4px 8px",
                border_radius = "4px",
                border = "1px solid " & border,
                background_color = bgSurface,
                color = textSecondary, font_size = "11px",
                cursor = "pointer"):
            text "\xE2\x80\xB9 Prev"
          tdiv(ref = carouselDots,
                `data-vector-usage-dots` = "true",
                display = "flex", align_items = "center",
                gap = "6px")
          tdiv(ref = carouselNext,
                `data-vector-usage-next` = "true",
                `role` = "button", tabindex = "0",
                `aria-label` = "Next vector usage",
                padding = "4px 8px",
                border_radius = "4px",
                border = "1px solid " & border,
                background_color = bgSurface,
                color = textSecondary, font_size = "11px",
                cursor = "pointer"):
            text "Next \xE2\x80\xBA"

  r.appendChild(splitRoot, leftSplit)
  r.appendChild(splitRoot, rightSplit)
  r.appendChild(container, splitRoot)

  block:
    let capturedVm = vm
    # Wire prev/next/jump handlers once.
    r.addEventListener(carouselPrev, "click", proc() = capturedVm.prevVectorUsage())
    r.addEventListener(carouselPrev, "keydown", proc() = capturedVm.prevVectorUsage())
    r.addEventListener(carouselNext, "click", proc() = capturedVm.nextVectorUsage())
    r.addEventListener(carouselNext, "keydown", proc() = capturedVm.nextVectorUsage())

    proc renderUsageRow(label: string; usage: VectorSymbolUsage): E =
      ui(r):
        tdiv(`data-vector-usage` = "true",
              `data-vector-usage-label` = label,
              `data-vector-usage-story` =
                usage.story.group & "/" & usage.story.name,
              display = "flex", flex_direction = "column",
              gap = "4px", padding = "10px 12px",
              border = "1px solid " & border,
              border_radius = "6px",
              background_color = bgCard,
              # Read-only — clicks in usage previews must NOT bubble
              # into selection in the main vector editor.
              pointer_events = "none"):
          span(font_size = "10px", font_weight = "600",
                color = textSecondary,
                text_transform = "uppercase",
                letter_spacing = "0.5px"):
            text label
          tdiv(min_height = "80px",
                background_color = bgSurface,
                border_radius = "4px",
                padding = "8px",
                color = textMuted, font_size = "11px"):
            text usage.story.group & " / " & usage.story.name

    createRenderEffect proc() =
      let usages = capturedVm.vectorEditorUsages.val
      let count = usages.len
      let visible = count > 0 and
        capturedVm.activeView.val == evVectorEditor
      r.setStyle(usagePanelRoot, "display", if visible: "flex" else: "none")

      let useCarousel = count > 3
      r.setStyle(stackedPanel, "display",
        if visible and not useCarousel: "flex" else: "none")
      r.setStyle(carouselPanel, "display",
        if visible and useCarousel: "flex" else: "none")

      # Rebuild stacked variant: <=3 usages stacked vertically.
      r.clearChildren(stackedPanel)
      if visible and not useCarousel:
        for usage in usages:
          let label = usage.story.group & " / " & usage.story.name
          let row = renderUsageRow(label, usage)
          r.appendChild(stackedPanel, row)

      # Rebuild carousel variant: only the active index is shown.
      if visible and useCarousel:
        var idx = capturedVm.vectorEditorUsageIndex.val
        if idx < 0: idx = 0
        if idx >= count: idx = count - 1
        # Defensive write-back so the signal reflects the clamped value.
        if capturedVm.vectorEditorUsageIndex.val != idx:
          capturedVm.vectorEditorUsageIndex.val = idx
        r.setAttribute(carouselPanel, "data-vector-usage-index", $idx)
        r.clearChildren(carouselContent)
        let usage = usages[idx]
        let label = usage.story.group & " / " & usage.story.name
        r.appendChild(carouselContent, renderUsageRow(label, usage))
        # Boundary state on prev / next buttons.
        let atFirst = idx <= 0
        let atLast = idx >= count - 1
        r.setAttribute(carouselPrev, "aria-disabled",
          if atFirst: "true" else: "false")
        r.setAttribute(carouselNext, "aria-disabled",
          if atLast: "true" else: "false")
        r.setStyle(carouselPrev, "opacity", if atFirst: "0.4" else: "1")
        r.setStyle(carouselNext, "opacity", if atLast: "0.4" else: "1")
        # Rebuild dot indicators.
        r.clearChildren(carouselDots)
        for i in 0 ..< count:
          let capturedIdx = i
          let isActive = i == idx
          var dotNode: E
          let dot = ui(r):
            tdiv(ref = dotNode,
                  `data-vector-usage-dot` = $i,
                  `role` = "button", tabindex = "0",
                  `aria-label` = "Show usage " & $(i + 1),
                  `aria-current` =
                    (if isActive: "true" else: "false"),
                  width = "8px", height = "8px",
                  border_radius = "4px",
                  cursor = "pointer",
                  background_color =
                    (if isActive: accent else: borderFaint))
          r.addEventListener(dotNode, "click", proc() =
            capturedVm.vectorEditorUsageIndex.val = capturedIdx)
          r.addEventListener(dotNode, "keydown", proc() =
            capturedVm.vectorEditorUsageIndex.val = capturedIdx)
          r.appendChild(carouselDots, dot)

  container
