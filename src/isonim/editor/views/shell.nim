## IsoNim Editor — shell View (three-panel layout).
##
## Fully dogfoods IsoNim: all elements via ui macro with if/for/case.
## Only uses manual setStyle for reactive effects (createRenderEffect).

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/storyboard
import isonim/editor/views/component_detail
import isonim/editor/views/component_edit
import isonim/editor/views/page_preview
import isonim/editor/views/vector_editor

# ---------------------------------------------------------------------------
# Theme tokens
# ---------------------------------------------------------------------------
const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgToolbar = "#151D2E"
  bgCard = "#151D2E"
  border = "#334155"
  borderStrong = "#475569"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  accentSoft = "#1E3A5F"
  gold = "#F59E0B"

proc renderSidebar*[R, E](r: R; vm: EditorVM): E =
  ## Left panel: storyboard navigation tree.
  ## Built entirely with the ui DSL — if/for inside the body.
  ui(r):
    tdiv(class = "editor-sidebar",
         display = "flex", flex_direction = "column",
         width = "260px", min_width = "260px", height = "100%",
         background_color = bgSidebar,
         border_right = "1px solid " & borderStrong,
         overflow_y = "auto", overflow_x = "hidden"):

      # Header
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           padding = "14px 16px 10px 16px",
           border_bottom = "1px solid " & borderFaint):
        span(font_size = "13px", font_weight = "700",
             color = gold, letter_spacing = "0.3px"):
          text "IsoNim Editor"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "10px", color = textDim):
            text "v0.1"
          tdiv(class = "editor-mobile-toggle",
               width = "28px", height = "28px",
               align_items = "center", justify_content = "center",
               border_radius = "4px", background_color = bgSurface,
               color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "\xE2\x98\xB0"

      # Search input
      tdiv(padding = "10px 12px"):
        tdiv(display = "flex", align_items = "center",
             background_color = bgSurface,
             border = "1px solid " & border,
             border_radius = "6px", padding = "0 10px", height = "32px"):
          span(font_size = "11px", opacity = "0.5", margin_right = "6px"):
            text "\xF0\x9F\x94\x8D"
          input(class = "editor-input",
                background_color = "transparent", border = "none",
                font_size = "12px", color = textSecondary,
                outline = "none", flex = "1",
                placeholder = "Search stories\xE2\x80\xA6")

      # Story groups
      tdiv(display = "flex", flex_direction = "column",
           gap = "2px", padding = "0 8px 16px 8px"):
        for group in vm.sidebar.groups.val:
          let gName = group.name
          let gKind = group.kind
          let gExpanded = group.expanded
          let gItems = group.items
          # Consistent-weight outlined Unicode icons
          let icon = case gKind
            of skFoundation: "\xE2\x97\x87"    # ◇ diamond outline
            of skComponent: "\xE2\x97\xBB"      # ◻ square outline
            of skPattern: "\xE2\x97\xA8"         # ◨ half-filled square
            of skPage: "\xE2\x96\xA1"            # □ square
            of skFlow: "\xE2\x96\xB7"            # ▷ triangle outline
            of skGuideline: "\xE2\x97\x8B"       # ○ circle outline
          let chevronText = if gExpanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8"

          tdiv(display = "flex", flex_direction = "column",
               margin_bottom = "2px"):
            # Group header
            tdiv(display = "flex", align_items = "center",
                 gap = "6px", padding = "5px 8px",
                 border_radius = "4px", cursor = "pointer"):
              span(font_size = "11px"):
                text icon
              span(font_size = "10px", font_weight = "600",
                   color = textSecondary, text_transform = "uppercase",
                   letter_spacing = "0.8px"):
                text gName
              span(font_size = "9px", color = textMuted, margin_left = "auto"):
                text chevronText

            # Items (if expanded)
            if gExpanded:
              var itemIdx = 0
              for item in gItems:
                let iName = item.name
                let iDesc = item.description
                let isSelected = (gKind == skComponent and itemIdx == 0)

                tdiv(display = "flex", flex_direction = "column",
                     padding = (if isSelected: "4px 12px 4px 28px" else: "4px 12px 4px 30px"),
                     border_radius = "4px", cursor = "pointer",
                     transition = "background-color 0.1s",
                     background_color = (if isSelected: accentSoft else: "transparent"),
                     border_left = (if isSelected: "2px solid " & accent else: "none")):
                  span(font_size = "12px", line_height = "1.4",
                       color = textPrimary,
                       font_weight = (if isSelected: "500" else: "400")):
                    text iName
                  if iDesc.len > 0:
                    span(font_size = "11px", color = textMuted,
                         line_height = "1.3", margin_top = "2px"):
                      text iDesc
                inc itemIdx

proc renderPreviewPane*[R, E](r: R; vm: EditorVM): E =
  ## Center panel: component preview with toolbar.
  ## viewBtn/editBtn need refs for reactive effect, so we extract them.
  let pane = ui(r):
    tdiv(class = "editor-preview",
         display = "flex", flex_direction = "column",
         flex = "1", min_width = "0", height = "100%",
         background_color = bgBase)

  # Toolbar — mode toggle buttons need refs for reactive styling
  let toolbar = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between",
         height = "44px", min_height = "44px", padding = "0 16px",
         background_color = bgToolbar,
         border_bottom = "1px solid " & border)

  let modeToggle = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
         background_color = bgSurface, border_radius = "6px",
         padding = "3px")

  let viewBtn = ui(r):
    tdiv(padding = "4px 14px", border_radius = "4px",
         font_size = "12px", font_weight = "500",
         cursor = "pointer", transition = "all 0.15s"):
      text "View"

  let editBtn = ui(r):
    tdiv(padding = "4px 14px", border_radius = "4px",
         font_size = "12px", font_weight = "500",
         cursor = "pointer", transition = "all 0.15s"):
      text "Edit"

  # Reactive effect — only place we need manual setStyle
  createRenderEffect proc() =
    if vm.editMode.val == emView:
      r.setStyle(viewBtn, "background-color", accent)
      r.setStyle(viewBtn, "color", textPrimary)
      r.setStyle(editBtn, "background-color", "transparent")
      r.setStyle(editBtn, "color", textMuted)
    else:
      r.setStyle(editBtn, "background-color", accent)
      r.setStyle(editBtn, "color", textPrimary)
      r.setStyle(viewBtn, "background-color", "transparent")
      r.setStyle(viewBtn, "color", textMuted)

  r.appendChild(modeToggle, viewBtn)
  r.appendChild(modeToggle, editBtn)
  r.appendChild(toolbar, modeToggle)

  # Breadcrumb + platform selector — built inline
  let breadcrumb = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px"):
      span(font_size = "8px", color = textDim):
        text "\xE2\x97\x8B"
      span(font_size = "12px", color = textMuted):
        text "No selection"
  r.appendChild(toolbar, breadcrumb)

  let platformSel = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
         background_color = bgSurface, border_radius = "6px",
         padding = "3px"):
      for i, plat in [pfWeb, pfIOS, pfAndroid]:
        let label = case plat
          of pfWeb: "Web"
          of pfIOS: "iOS"
          of pfAndroid: "Android"
        let isFirst = (i == 0)
        tdiv(padding = "4px 10px", border_radius = "4px",
             font_size = "11px", font_weight = "500",
             cursor = "pointer", transition = "all 0.15s",
             background_color = (if isFirst: accent else: "transparent"),
             color = (if isFirst: textPrimary else: textMuted)):
          text label
  r.appendChild(toolbar, platformSel)

  r.appendChild(pane, toolbar)

  # Preview area — fully inline
  let previewArea = ui(r):
    tdiv(flex = "1", display = "flex",
         align_items = "center", justify_content = "center",
         background_color = bgBase, position = "relative",
         background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
         background_size = "24px 24px"):
      tdiv(display = "flex", flex_direction = "column",
           align_items = "center", gap = "10px",
           padding = "32px", background_color = bgBase,
           border_radius = "12px"):
        tdiv(font_size = "40px", opacity = "0.25"):
          text "\xF0\x9F\x8E\xA8"
        span(font_size = "14px", color = textMuted, font_weight = "500"):
          text "Select a story from the sidebar"
        span(font_size = "12px", color = textDim):
          text "Components render here with live preview"
  r.appendChild(pane, previewArea)
  pane

proc renderInspectorPanel*[R, E](r: R; vm: EditorVM): E =
  ## Right panel: property inspector + agent chat.
  ## Fully inline except for tab active-state styling.
  ui(r):
    tdiv(class = "editor-inspector",
         display = "flex", flex_direction = "column",
         width = "300px", min_width = "300px", height = "100%",
         background_color = bgSidebar,
         border_left = "1px solid " & borderStrong):

      # Section tabs
      tdiv(class = "editor-tabbar",
           display = "flex", align_items = "stretch",
           height = "36px", min_height = "36px",
           border_bottom = "1px solid " & border,
           overflow_x = "auto", scrollbar_width = "none"):
        for i, name in ["Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type", "FX", "Trans", "Filter", "State"]:
          let isActive = (i == 0)
          tdiv(display = "flex", align_items = "center",
               padding = "0 8px", font_size = "11px", font_weight = "500",
               cursor = "pointer", white_space = "nowrap",
               transition = "color 0.15s",
               color = (if isActive: accent else: textMuted),
               box_shadow = (if isActive: "inset 0 -2px 0 " & accent else: "none")):
            text name

      # Property content area — empty state
      tdiv(flex = "1", display = "flex", flex_direction = "column",
           align_items = "center", justify_content = "center",
           padding = "24px 16px", overflow_y = "auto"):
        tdiv(font_size = "28px", opacity = "0.25", margin_bottom = "8px"):
          text "\xF0\x9F\x94\x8D"
        span(font_size = "12px", color = textMuted):
          text "Select an element to inspect"
        span(font_size = "11px", color = textDim, margin_top = "4px"):
          text "Click any element in the preview"

      # Agent chat area
      tdiv(display = "flex", flex_direction = "column",
           height = "220px", min_height = "220px",
           border_top = "1px solid " & borderStrong,
           background_color = bgSidebar):

        # Chat header
        tdiv(display = "flex", align_items = "center", gap = "8px",
             padding = "10px 12px",
             border_bottom = "1px solid " & borderFaint):
          span(font_size = "13px"):
            text "\xE2\x9C\xA8"
          span(font_size = "11px", font_weight = "600",
               color = textSecondary, text_transform = "uppercase",
               letter_spacing = "0.5px"):
            text "AI Assistant"

        # Chat messages area
        tdiv(flex = "1", overflow_y = "auto", padding = "12px"):
          tdiv(display = "flex", align_items = "center",
               justify_content = "center", height = "100%"):
            span(font_size = "12px", color = textDim, font_style = "italic"):
              text "Ask the AI to modify components\xE2\x80\xA6"

        # Chat input row
        tdiv(display = "flex", align_items = "center", gap = "8px",
             padding = "8px 12px 12px 12px"):
          input(class = "editor-input",
                flex = "1", height = "34px",
                background_color = bgSurface,
                border = "1px solid " & border,
                border_radius = "8px", padding = "0 12px",
                font_size = "13px", color = textPrimary,
                outline = "none",
                placeholder = "Ask the AI\xE2\x80\xA6")
          tdiv(display = "flex", align_items = "center",
               justify_content = "center",
               width = "34px", height = "34px",
               border_radius = "8px", font_size = "16px", font_weight = "700",
               background_color = accent, color = textPrimary,
               cursor = "pointer", transition = "background-color 0.15s"):
            text "\xE2\x86\x91"

proc renderEditorShell*[R, E](r: R; vm: EditorVM): E =
  ## Top-level editor layout: sidebar + storyboard/preview + inspector.
  let shell = ui(r):
    tdiv(display = "flex", width = "100%", height = "100%",
         font_family = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
         font_size = "14px", background_color = bgBase,
         color = textPrimary, overflow = "hidden")

  let sidebarEl = renderSidebar[R, E](r, vm)
  let storyboardEl = renderStoryboardCanvas[R, E](r, vm)
  let componentDetailEl = renderComponentDetail[R, E](r, vm)
  let componentEditEl = renderComponentEditView[R, E](r, vm)
  let pagePreviewEl = renderPagePreview[R, E](r, vm)
  let vectorEditorEl = renderVectorEditor[R, E](r, vm)
  let inspectorEl = renderInspectorPanel[R, E](r, vm)

  # Default: storyboard visible, everything else hidden
  r.setStyle(componentDetailEl, "display", "none")
  r.setStyle(componentEditEl, "display", "none")
  r.setStyle(pagePreviewEl, "display", "none")
  r.setStyle(vectorEditorEl, "display", "none")
  r.setStyle(inspectorEl, "display", "none")

  # Reactive view switching
  createRenderEffect proc() =
    let view = vm.activeView.val
    r.setStyle(storyboardEl, "display", if view == evStoryboard: "flex" else: "none")
    r.setStyle(componentDetailEl, "display", if view == evComponentDetail: "flex" else: "none")
    r.setStyle(componentEditEl, "display", if view == evComponentEdit: "flex" else: "none")
    r.setStyle(pagePreviewEl, "display", if view == evPagePreview: "flex" else: "none")
    r.setStyle(vectorEditorEl, "display", if view == evVectorEditor: "flex" else: "none")
    r.setStyle(sidebarEl, "display", if view == evVectorEditor: "none" else: "flex")
    r.setStyle(inspectorEl, "display", "none")

  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, storyboardEl)
  r.appendChild(shell, componentDetailEl)
  r.appendChild(shell, componentEditEl)
  r.appendChild(shell, pagePreviewEl)
  r.appendChild(shell, vectorEditorEl)
  r.appendChild(shell, inspectorEl)
  shell
