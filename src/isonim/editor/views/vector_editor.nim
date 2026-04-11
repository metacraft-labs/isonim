## IsoNim Editor — Vector Graphics Editor View.
##
## Embedded SVG editor for design system symbols (icons, illustrations).
## Left: tool palette. Center: SVG canvas with grid. Right: properties
## (stroke, fill, transform). Bottom: layers panel.

import std/strutils
import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/viewmodels
import isonim/editor/types

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
  gold = "#F59E0B"

type
  ToolDef = object
    name: string
    icon: string
    shortcut: string

proc vectorTools(): seq[ToolDef] =
  @[
    ToolDef(name: "Select", icon: "\xE2\x86\x96", shortcut: "V"),     # ↖
    ToolDef(name: "Pen", icon: "\xE2\x9C\x8F", shortcut: "P"),        # ✏
    ToolDef(name: "Pencil", icon: "\xE2\x9C\x8E", shortcut: "N"),     # ✎
    ToolDef(name: "Rectangle", icon: "\xE2\x96\xAD", shortcut: "R"),   # ▭
    ToolDef(name: "Ellipse", icon: "\xE2\x97\x8B", shortcut: "O"),     # ○
    ToolDef(name: "Polygon", icon: "\xE2\xAC\xA0", shortcut: "Y"),     # ⬠
    ToolDef(name: "Star", icon: "\xE2\x98\x86", shortcut: "S"),        # ☆
    ToolDef(name: "Line", icon: "\xE2\x95\xB1", shortcut: "L"),        # ╱
    ToolDef(name: "Text", icon: "T", shortcut: "T"),
    ToolDef(name: "Path Edit", icon: "\xE2\x97\x87", shortcut: "A"),   # ◇
  ]

proc renderVectorEditor*[R, E](r: R; vm: EditorVM): E =
  let tools = vectorTools()

  let container = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex", flex_direction = "column",
         min_width = "0", height = "100%",
         background_color = bgBase):

      # Top toolbar
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           height = "44px", min_height = "44px", padding = "0 16px",
           background_color = bgCard,
           border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "10px"):
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text "Vector Editor"
          span(font_size = "11px", color = textDim):
            text "\xE2\x80\x94 check-icon.svg"
        # Boolean operations (grouped)
        tdiv(display = "flex", align_items = "center", gap = "2px",
             background_color = bgSurface, border_radius = "6px",
             padding = "3px", border = "1px solid " & border):
          for op in ["Union", "Sub", "Inter", "Excl"]:
            tdiv(padding = "4px 8px", border_radius = "4px",
                 font_size = "10px", font_weight = "500",
                 color = textMuted, cursor = "pointer"):
              text op
        # Zoom / export
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "11px", color = textMuted):
            text "100%"
          tdiv(padding = "4px 10px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = accent, color = textPrimary,
               cursor = "pointer"):
            text "Export SVG"

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
    let isActive = (i == 0)  # Select tool active
    let toolBtn = ui(r):
      tdiv(width = "32px", height = "32px",
           display = "flex", align_items = "center", justify_content = "center",
           border_radius = "6px", cursor = "pointer",
           font_size = "14px",
           transition = "background-color 0.1s",
           background_color = (if isActive: accent else: "transparent"),
           color = (if isActive: textPrimary else: textMuted)):
        text tIcon
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
  r.appendChild(toolPalette, gridBtn)

  let snapBtn = ui(r):
    tdiv(width = "32px", height = "32px",
         display = "flex", align_items = "center", justify_content = "center",
         border_radius = "6px", cursor = "pointer",
         font_size = "11px", color = textMuted):
      text "\xE2\xAF\xAE"  # magnet
  r.appendChild(toolPalette, snapBtn)

  r.appendChild(mainArea, toolPalette)

  # Center: SVG Canvas
  let canvas = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
         overflow = "hidden"):

      # Canvas area with grid
      tdiv(flex = "1", position = "relative",
           background_color = bgBase,
           background_image = "linear-gradient(" & borderFaint & " 1px, transparent 1px), linear-gradient(90deg, " & borderFaint & " 1px, transparent 1px)",
           background_size = "16px 16px",
           overflow = "hidden"):

        # Artboard
        tdiv(position = "absolute", left = "80px", top = "60px",
             width = "300px", height = "300px",
             background_color = bgCard, border = "1px solid " & border,
             border_radius = "4px"):

          # Mock SVG shapes on the artboard
          # Circle
          tdiv(position = "absolute", left = "100px", top = "80px",
               width = "80px", height = "80px", border_radius = "40px",
               border = "2px solid " & accent, background_color = "transparent")
          # Rectangle
          tdiv(position = "absolute", left = "40px", top = "180px",
               width = "120px", height = "60px", border_radius = "4px",
               border = "2px solid " & gold, background_color = "transparent")
          # Line
          tdiv(position = "absolute", left = "180px", top = "100px",
               width = "80px", height = "2px",
               background_color = textSecondary,
               transform = "rotate(30deg)")
          # Selected shape indicator (blue handles)
          tdiv(position = "absolute", left = "96px", top = "76px",
               width = "88px", height = "88px",
               border = "1px dashed " & accent):
            # Corner handles
            for pos in ["top: -3px; left: -3px", "top: -3px; right: -3px",
                        "bottom: -3px; left: -3px", "bottom: -3px; right: -3px"]:
              tdiv(position = "absolute", width = "6px", height = "6px",
                   background_color = accent, border_radius = "1px")

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
            let isSelected = (i == 0)
            tdiv(display = "flex", align_items = "center", gap = "8px",
                 padding = "4px 12px", cursor = "pointer",
                 background_color = (if isSelected: accent & "22" else: "transparent")):
              span(font_size = "10px", color = textMuted):
                text "\xE2\x97\x8B"
              span(font_size = "11px",
                   color = (if isSelected: textPrimary else: textSecondary)):
                text lName
              tdiv(margin_left = "auto", font_size = "10px",
                   color = textDim, cursor = "pointer"):
                text "\xF0\x9F\x91\x81"

  r.appendChild(mainArea, canvas)

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

  r.appendChild(container, mainArea)
  container
