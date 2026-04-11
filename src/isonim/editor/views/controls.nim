## IsoNim Editor — reusable editing controls.
##
## Figma-grade input affordances: scrub-drag numeric inputs,
## color picker, bezier curve editor, shadow editor, border
## radius editor, rotation dial. All built with the ui DSL.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/types

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgInput = "#0F172A"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  green = "#22C55E"
  red = "#EF4444"
  gold = "#F59E0B"

# ===========================================================================
# Scrub-drag numeric input
# ===========================================================================

proc renderScrubInput*[R, E](r: R; label, value, unit: string;
                              highlighted: bool = false): E =
  ## A numeric property input with scrub-drag label, value field, and unit.
  ## Label: click-drag to scrub. Field: click to type. Unit: click to cycle.
  ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      # Scrub-drag label (cursor: ew-resize)
      span(font_size = "11px", color = textMuted, width = "70px",
           cursor = "ew-resize", white_space = "nowrap",
           font_weight = (if highlighted: "500" else: "400")):
        text label
      # Value input
      tdiv(flex = "1", height = "24px", background_color = bgInput,
           border = "1px solid " & (if highlighted: accent else: border),
           border_radius = "4px",
           display = "flex", align_items = "center",
           padding = "0 6px", cursor = "text"):
        span(font_size = "11px", color = textPrimary,
             font_family = "'SF Mono', 'Cascadia Code', monospace"):
          text value
      # Unit selector
      tdiv(height = "24px", padding = "0 5px",
           background_color = bgSurface,
           border = "1px solid " & border, border_radius = "4px",
           display = "flex", align_items = "center",
           font_size = "10px", color = textMuted, cursor = "pointer",
           min_width = "28px", justify_content = "center"):
        text unit

# ===========================================================================
# Color picker
# ===========================================================================

proc renderColorPicker*[R, E](r: R; hexColor: string; opacity: string = "100"): E =
  ## Full color picker: swatch, 2D field, hue strip, opacity, hex input, swatches.
  ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px",
         padding = "12px", background_color = bgSurface,
         border = "1px solid " & border, border_radius = "6px"):

      # 2D saturation/brightness field
      tdiv(width = "100%", height = "120px", border_radius = "4px",
           position = "relative", cursor = "crosshair",
           background = "linear-gradient(to right, white, " & hexColor & "), linear-gradient(to top, black, transparent)",
           background_size = "100% 100%"):
        # Crosshair picker dot
        tdiv(position = "absolute", right = "20px", top = "30px",
             width = "12px", height = "12px", border_radius = "6px",
             border = "2px solid white",
             box_shadow = "0 0 0 1px rgba(0,0,0,0.3)")

      # Hue strip + Opacity strip
      tdiv(display = "flex", gap = "8px"):
        # Hue strip (rainbow gradient)
        tdiv(flex = "1", height = "14px", border_radius = "7px",
             position = "relative", cursor = "pointer",
             background = "linear-gradient(to right, #f00, #ff0, #0f0, #0ff, #00f, #f0f, #f00)"):
          # Hue slider thumb
          tdiv(position = "absolute", left = "60%", top = "-1px",
               width = "8px", height = "16px", border_radius = "4px",
               background_color = "white",
               border = "1px solid rgba(0,0,0,0.3)",
               box_shadow = "0 1px 3px rgba(0,0,0,0.3)")
        # Opacity strip
        tdiv(width = "40px", height = "14px", border_radius = "7px",
             position = "relative", cursor = "pointer",
             background = "linear-gradient(to right, transparent, " & hexColor & "), repeating-conic-gradient(#808080 0% 25%, transparent 0% 50%) 50% / 8px 8px"):
          tdiv(position = "absolute", right = "2px", top = "-1px",
               width = "8px", height = "16px", border_radius = "4px",
               background_color = "white",
               border = "1px solid rgba(0,0,0,0.3)")

      # Hex + opacity inputs
      tdiv(display = "flex", gap = "6px", align_items = "center"):
        # Color swatch
        tdiv(width = "24px", height = "24px", border_radius = "4px",
             background_color = hexColor,
             border = "1px solid " & border)
        # Hex input
        tdiv(flex = "1", height = "24px", background_color = bgInput,
             border = "1px solid " & border, border_radius = "4px",
             display = "flex", align_items = "center",
             padding = "0 6px"):
          span(font_size = "10px", color = textDim): text "#"
          span(font_size = "11px", color = textPrimary,
               font_family = "monospace"):
            text hexColor[1..^1]  # strip the #
        # Opacity
        tdiv(width = "44px", height = "24px", background_color = bgInput,
             border = "1px solid " & border, border_radius = "4px",
             display = "flex", align_items = "center",
             padding = "0 6px", justify_content = "center"):
          span(font_size = "11px", color = textPrimary,
               font_family = "monospace"):
            text opacity & "%"

      # Eyedropper + swatches row
      tdiv(display = "flex", align_items = "center", gap = "6px"):
        tdiv(width = "24px", height = "24px", border_radius = "4px",
             background_color = bgInput, border = "1px solid " & border,
             display = "flex", align_items = "center", justify_content = "center",
             cursor = "pointer", font_size = "12px"):
          text "\xF0\x9F\x91\x81"  # eyedropper placeholder
        # Saved swatches
        for sw in ["#3B82F6", "#22C55E", "#F59E0B", "#EF4444", "#8B5CF6", "#06B6D4"]:
          tdiv(width = "18px", height = "18px", border_radius = "3px",
               background_color = sw, cursor = "pointer",
               border = "1px solid " & border)

# ===========================================================================
# Bezier curve editor (for transition-timing-function)
# ===========================================================================

proc renderBezierEditor*[R, E](r: R; x1, y1, x2, y2: float): E =
  ## Bezier curve editor: square with control points + preset thumbnails.
  let sz = "180"
  let szf = 180.0
  # Compute control point positions from bezier values (0..1 mapped to canvas)
  let cp1x = int(x1 * szf)
  let cp1y = int((1 - y1) * szf)
  let cp2x = int(x2 * szf)
  let cp2y = int((1 - y2) * szf)

  let editor = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px"):
      # Curve canvas
      tdiv(width = sz & "px", height = sz & "px",
           background_color = bgInput,
           border = "1px solid " & border, border_radius = "6px",
           position = "relative", cursor = "crosshair"):
        # Start point (bottom-left)
        tdiv(position = "absolute", left = "-3px", bottom = "-3px",
             width = "6px", height = "6px", border_radius = "3px",
             background_color = textMuted)
        # End point (top-right)
        tdiv(position = "absolute", right = "-3px", top = "-3px",
             width = "6px", height = "6px", border_radius = "3px",
             background_color = textMuted)

  # Position control points dynamically
  let canvas = r.firstChild(r.firstChild(editor))

  # Handle line from start to CP1
  let line1 = ui(r):
    tdiv(position = "absolute", height = "1px",
         background_color = accent, opacity = "0.4")
  r.setStyle(line1, "left", "0px")
  r.setStyle(line1, "bottom", "0px")
  r.setStyle(line1, "width", $cp1x & "px")
  r.setStyle(line1, "transform-origin", "left bottom")
  r.setStyle(line1, "transform", "rotate(" & $(-(float(cp1y) / float(max(cp1x, 1))) * 57.3) & "deg)")
  r.appendChild(canvas, line1)

  # CP1 dot
  let dot1 = ui(r):
    tdiv(position = "absolute",
         width = "10px", height = "10px", border_radius = "5px",
         background_color = accent, cursor = "grab",
         border = "2px solid white")
  r.setStyle(dot1, "left", $(cp1x - 5) & "px")
  r.setStyle(dot1, "top", $(cp1y - 5) & "px")
  r.appendChild(canvas, dot1)

  # Handle line from end to CP2
  let line2 = ui(r):
    tdiv(position = "absolute", height = "1px",
         background_color = accent, opacity = "0.4")
  r.setStyle(line2, "right", "0px")
  r.setStyle(line2, "top", "0px")
  r.setStyle(line2, "width", $(int(szf) - cp2x) & "px")
  r.appendChild(canvas, line2)

  # CP2 dot
  let dot2 = ui(r):
    tdiv(position = "absolute",
         width = "10px", height = "10px", border_radius = "5px",
         background_color = accent, cursor = "grab",
         border = "2px solid white")
  r.setStyle(dot2, "left", $(cp2x - 5) & "px")
  r.setStyle(dot2, "top", $(cp2y - 5) & "px")
  r.appendChild(canvas, dot2)

  # Preset thumbnails
  let presets = ui(r):
    tdiv(display = "flex", gap = "4px", flex_wrap = "wrap"):
      for preset in ["linear", "ease", "ease-in", "ease-out", "ease-in-out"]:
        tdiv(padding = "3px 6px", border_radius = "4px",
             background_color = bgSurface, border = "1px solid " & border,
             display = "flex", align_items = "center", justify_content = "center",
             cursor = "pointer", font_size = "9px", color = textMuted):
          text preset
  r.appendChild(editor, presets)
  editor

# ===========================================================================
# Shadow editor
# ===========================================================================

proc renderShadowEditor*[R, E](r: R; x, y, blur, spread: string;
                                color: string): E =
  ## Shadow editor: 2D offset crosshair + numeric inputs.
  let editor = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px")

  let topRow = ui(r):
    tdiv(display = "flex", gap = "8px")

  # 2D offset crosshair
  let crosshair = ui(r):
    tdiv(width = "80px", height = "80px",
         background_color = bgInput,
         border = "1px solid " & border, border_radius = "4px",
         position = "relative", cursor = "crosshair"):
      tdiv(position = "absolute", left = "50%", top = "0",
           width = "1px", height = "100%",
           background_color = borderFaint)
      tdiv(position = "absolute", top = "50%", left = "0",
           width = "100%", height = "1px",
           background_color = borderFaint)
      tdiv(position = "absolute", left = "52px", top = "36px",
           width = "8px", height = "8px", border_radius = "4px",
           background_color = accent,
           border = "1.5px solid white", cursor = "grab")
  r.appendChild(topRow, crosshair)

  # Value inputs column
  let valCol = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
         gap = "4px")
  for (lbl, val) in [("X", x), ("Y", y), ("Blur", blur), ("Spread", spread)]:
    let row = renderScrubInput[R, E](r, lbl, val, "px")
    r.appendChild(valCol, row)
  r.appendChild(topRow, valCol)
  r.appendChild(editor, topRow)

  # Color row
  let colorRow = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px",
         height = "28px"):
      span(font_size = "11px", color = textMuted, width = "70px"):
        text "Color"
      tdiv(width = "24px", height = "24px", border_radius = "4px",
           background_color = color,
           border = "1px solid " & border, cursor = "pointer")
      tdiv(flex = "1", height = "24px", background_color = bgInput,
           border = "1px solid " & border, border_radius = "4px",
           display = "flex", align_items = "center", padding = "0 6px"):
        span(font_size = "11px", color = textPrimary,
             font_family = "monospace"):
          text color
  r.appendChild(editor, colorRow)
  editor

# ===========================================================================
# Border radius editor (per-corner visual)
# ===========================================================================

proc renderBorderRadiusEditor*[R, E](r: R; tl, tr, br, bl: string;
                                      linked: bool = true): E =
  ## Per-corner border radius with linked/unlinked toggle.
  ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "8px"):
      tdiv(display = "flex", gap = "8px", align_items = "center"):
        # Visual corner preview
        tdiv(width = "60px", height = "60px",
             background_color = bgInput,
             border = "2px solid " & accent,
             position = "relative"):
          # Corner radius indicators
          tdiv(position = "absolute", top = "0", left = "0",
               width = "16px", height = "16px",
               border_top = "2px solid " & accent,
               border_left = "2px solid " & accent,
               border_radius = tl & "px 0 0 0")
          tdiv(position = "absolute", top = "0", right = "0",
               width = "16px", height = "16px",
               border_top = "2px solid " & accent,
               border_right = "2px solid " & accent,
               border_radius = "0 " & tr & "px 0 0")
          tdiv(position = "absolute", bottom = "0", right = "0",
               width = "16px", height = "16px",
               border_bottom = "2px solid " & accent,
               border_right = "2px solid " & accent,
               border_radius = "0 0 " & br & "px 0")
          tdiv(position = "absolute", bottom = "0", left = "0",
               width = "16px", height = "16px",
               border_bottom = "2px solid " & accent,
               border_left = "2px solid " & accent,
               border_radius = "0 0 0 " & bl & "px")

        # Per-corner inputs
        tdiv(flex = "1", display = "flex", flex_direction = "column",
             gap = "3px"):
          tdiv(display = "flex", gap = "4px"):
            tdiv(flex = "1", height = "22px", background_color = bgInput,
                 border = "1px solid " & border, border_radius = "3px",
                 display = "flex", align_items = "center",
                 justify_content = "center"):
              span(font_size = "10px", color = textPrimary,
                   font_family = "monospace"):
                text tl
            tdiv(flex = "1", height = "22px", background_color = bgInput,
                 border = "1px solid " & border, border_radius = "3px",
                 display = "flex", align_items = "center",
                 justify_content = "center"):
              span(font_size = "10px", color = textPrimary,
                   font_family = "monospace"):
                text tr
          # Link toggle
          tdiv(display = "flex", align_items = "center",
               justify_content = "center"):
            tdiv(width = "20px", height = "20px", border_radius = "10px",
                 background_color = (if linked: accent else: bgSurface),
                 border = "1px solid " & border,
                 display = "flex", align_items = "center",
                 justify_content = "center", cursor = "pointer",
                 font_size = "10px",
                 color = (if linked: textPrimary else: textMuted)):
              text "\xF0\x9F\x94\x97"  # link
          tdiv(display = "flex", gap = "4px"):
            tdiv(flex = "1", height = "22px", background_color = bgInput,
                 border = "1px solid " & border, border_radius = "3px",
                 display = "flex", align_items = "center",
                 justify_content = "center"):
              span(font_size = "10px", color = textPrimary,
                   font_family = "monospace"):
                text bl
            tdiv(flex = "1", height = "22px", background_color = bgInput,
                 border = "1px solid " & border, border_radius = "3px",
                 display = "flex", align_items = "center",
                 justify_content = "center"):
              span(font_size = "10px", color = textPrimary,
                   font_family = "monospace"):
                text br

# ===========================================================================
# Rotation dial
# ===========================================================================

proc renderRotationDial*[R, E](r: R; degrees: string): E =
  ## Circular rotation dial with degree input.
  ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px"):
      # Dial
      tdiv(width = "36px", height = "36px", border_radius = "18px",
           background_color = bgInput,
           border = "2px solid " & border,
           position = "relative", cursor = "grab"):
        # Indicator line
        tdiv(position = "absolute", left = "50%", top = "2px",
             width = "1px", height = "14px",
             background_color = accent,
             transform_origin = "bottom center",
             transform = "rotate(" & degrees & "deg)")
        # Center dot
        tdiv(position = "absolute", left = "50%", top = "50%",
             width = "4px", height = "4px", border_radius = "2px",
             background_color = accent,
             margin_left = "-2px", margin_top = "-2px")
      # Degree input
      tdiv(width = "60px", height = "24px", background_color = bgInput,
           border = "1px solid " & border, border_radius = "4px",
           display = "flex", align_items = "center",
           padding = "0 6px", justify_content = "center"):
        span(font_size = "11px", color = textPrimary,
             font_family = "monospace"):
          text degrees & "\xC2\xB0"
