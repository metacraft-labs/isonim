## IsoNim Editor — inspector section views.
##
## Each CSS inspector section rendered with proper Figma-grade controls.
## These are shown inside the component edit view's right panel.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/controls

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgInput = "#0F172A"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  gold = "#F59E0B"

proc sectionHeader[R, E](r: R; title, origin: string): E =
  ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between", margin_bottom = "8px"):
      span(font_size = "11px", font_weight = "600", color = textSecondary,
           text_transform = "uppercase", letter_spacing = "0.5px"):
        text title
      if origin.len > 0:
        span(font_size = "10px", color = accent, font_family = "monospace"):
          text origin

proc renderLayoutSection*[R, E](r: R; vm: EditorVM): E =
  ## Layout section: display mode, flex direction, alignment, gap.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
         padding = "12px")

  let header = sectionHeader[R, E](r, "Layout", "class: flex")
  r.appendChild(section, header)

  # Display mode toggle row
  let displayRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Display"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, mode in ["Block", "Flex", "Grid", "None"]:
          let isActive = (i == 1)  # Flex active
          tdiv(padding = "3px 8px", border_radius = "3px",
               font_size = "10px", font_weight = "500", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text mode
  r.appendChild(section, displayRow)

  # Flex direction
  let dirRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Direction"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, dir in ["\xE2\x86\x92", "\xE2\x86\x93", "\xE2\x86\x90", "\xE2\x86\x91"]:
          let isActive = (i == 0)  # Row active
          tdiv(padding = "3px 8px", border_radius = "3px",
               font_size = "12px", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text dir
  r.appendChild(section, dirRow)

  # Align items (icon row)
  let alignRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Align"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, al in ["\xE2\xAC\x86", "\xE2\xAC\x8D", "\xE2\xAC\x87", "\xE2\x86\x95", "\xE2\x8E\x8D"]:
          let isActive = (i == 1)  # Center
          tdiv(padding = "3px 6px", border_radius = "3px",
               font_size = "10px", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text al
  r.appendChild(section, alignRow)

  # Gap
  # Justify content
  let justifyRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Justify"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, jc in ["\xE2\xAC\x85", "\xE2\xAC\x8D", "\xE2\xAC\x86", "\xE2\x86\x94", "\xE2\x87\x94"]:
          let isActive = (i == 0)  # Start
          tdiv(padding = "3px 5px", border_radius = "3px",
               font_size = "10px", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text jc
  r.appendChild(section, justifyRow)

  # Wrap
  let wrapRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Wrap"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, w in ["No wrap", "Wrap"]:
          let isActive = (i == 0)
          tdiv(padding = "3px 8px", border_radius = "3px",
               font_size = "10px", font_weight = "500", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text w
  r.appendChild(section, wrapRow)

  # Gap + overflow
  let gap = renderScrubInput[R, E](r, "Gap", "8", "px")
  r.appendChild(section, gap)

  let overflow = renderScrubInput[R, E](r, "Overflow", "visible", "")
  r.appendChild(section, overflow)

  section

proc renderFillSection*[R, E](r: R; vm: EditorVM): E =
  ## Fill section: background color with full color picker.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
         padding = "12px")

  let header = sectionHeader[R, E](r, "Fill", "themeColor(\"surface\")")
  r.appendChild(section, header)

  let picker = renderColorPicker[R, E](r, "#1E293B", "100")
  r.appendChild(section, picker)

  section

proc renderEffectsSection*[R, E](r: R; vm: EditorVM): E =
  ## Effects section: shadows, blur, transforms.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "12px",
         padding = "12px")

  let header = sectionHeader[R, E](r, "Effects", "")
  r.appendChild(section, header)

  # Shadow subsection
  let shadowLabel = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between"):
      span(font_size = "10px", font_weight = "500", color = textSecondary):
        text "Drop Shadow"
      tdiv(padding = "2px 6px", border_radius = "3px",
           background_color = bgSurface, font_size = "9px",
           color = textMuted, cursor = "pointer"):
        text "+ Add"
  r.appendChild(section, shadowLabel)

  let shadow = renderShadowEditor[R, E](r, "0", "2", "8", "0", "#000000")
  r.appendChild(section, shadow)

  # Transform subsection
  let transformLabel = ui(r):
    tdiv(display = "flex", align_items = "center",
         justify_content = "space-between", margin_top = "4px"):
      span(font_size = "10px", font_weight = "500", color = textSecondary):
        text "Transform"
  r.appendChild(section, transformLabel)

  let rotation = renderRotationDial[R, E](r, "0")
  r.appendChild(section, rotation)

  let scaleRow = renderScrubInput[R, E](r, "Scale", "1.0", "x")
  r.appendChild(section, scaleRow)

  section

proc renderStrokeSection*[R, E](r: R; vm: EditorVM): E =
  ## Stroke section: border with radius editor.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
         padding = "12px")

  let header = sectionHeader[R, E](r, "Stroke & Border", "class: rounded-xl")
  r.appendChild(section, header)

  # Border width/color
  let borderWidth = renderScrubInput[R, E](r, "Width", "1", "px")
  r.appendChild(section, borderWidth)

  let borderColorRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Color"
      tdiv(width = "24px", height = "24px", border_radius = "4px",
           background_color = "#334155",
           border = "1px solid " & border, cursor = "pointer")
      tdiv(flex = "1", height = "24px", background_color = bgInput,
           border = "1px solid " & border, border_radius = "4px",
           display = "flex", align_items = "center", padding = "0 6px"):
        span(font_size = "11px", color = textPrimary,
             font_family = "monospace"):
          text "#334155"
  r.appendChild(section, borderColorRow)

  # Style selector
  let styleRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Style"
      tdiv(display = "flex", gap = "1px", background_color = bgSurface,
           border_radius = "4px", padding = "2px"):
        for i, style in ["Solid", "Dashed", "Dotted", "None"]:
          let isActive = (i == 0)
          tdiv(padding = "3px 8px", border_radius = "3px",
               font_size = "10px", font_weight = "500", cursor = "pointer",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: textPrimary else: textMuted)):
            text style
  r.appendChild(section, styleRow)

  # Border radius
  let radiusLabel = ui(r):
    span(font_size = "10px", font_weight = "500", color = textSecondary,
         margin_top = "4px"):
      text "Border Radius"
  r.appendChild(section, radiusLabel)

  let radius = renderBorderRadiusEditor[R, E](r, "12", "12", "12", "12", linked = true)
  r.appendChild(section, radius)

  section

proc renderTransitionsSection*[R, E](r: R; vm: EditorVM): E =
  ## Transitions section: bezier curve editor + duration/delay.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
         padding = "12px")

  let header = sectionHeader[R, E](r, "Transitions", "")
  r.appendChild(section, header)

  let propRow = renderScrubInput[R, E](r, "Property", "all", "")
  r.appendChild(section, propRow)

  let durationRow = renderScrubInput[R, E](r, "Duration", "0.15", "s")
  r.appendChild(section, durationRow)

  let bezier = renderBezierEditor[R, E](r, 0.4, 0.0, 0.2, 1.0)
  r.appendChild(section, bezier)

  let delayRow = renderScrubInput[R, E](r, "Delay", "0", "s")
  r.appendChild(section, delayRow)

  section
