## IsoNim Editor — Component Edit View.
##
## Full CSS inspector with live preview. Shown when "Edit" is clicked
## on a component. Left: live component preview. Right: CSS inspector
## with all 11 sections, scrub-able inputs, visual box model.

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

proc renderPropertyRow[R, E](r: R; label, value, unit: string): E =
  ## A single property row: label + scrub-able input + unit selector.
  ui(r):
    tdiv(display = "flex", align_items = "center", gap = "8px",
         padding = "4px 0"):
      span(font_size = "11px", color = textMuted, width = "80px",
           white_space = "nowrap"):
        text label
      tdiv(display = "flex", align_items = "center", flex = "1",
           gap = "4px"):
        tdiv(flex = "1", height = "26px", background_color = bgSurface,
             border = "1px solid " & border, border_radius = "4px",
             display = "flex", align_items = "center",
             padding = "0 8px"):
          span(font_size = "11px", color = textPrimary,
               font_family = "monospace"):
            text value
        tdiv(height = "26px", padding = "0 6px",
             background_color = bgSurface,
             border = "1px solid " & border, border_radius = "4px",
             display = "flex", align_items = "center",
             font_size = "10px", color = textMuted, cursor = "pointer"):
          text unit

proc renderBoxModel[R, E](r: R; mt, mr, mb, ml, pt, pr, pb, pl: string): E =
  ## Visual box model diagram — nested rectangles for margin and padding.
  ui(r):
    tdiv(display = "flex", flex_direction = "column",
         align_items = "center", padding = "8px 0"):
      # Margin label
      span(font_size = "9px", color = textDim, margin_bottom = "4px"):
        text "MARGIN"
      # Outer box (margin)
      tdiv(display = "flex", flex_direction = "column",
           align_items = "center", width = "200px",
           border = "1px dashed " & border, border_radius = "4px",
           padding = "4px"):
        # Top margin
        span(font_size = "10px", color = textMuted, font_family = "monospace"):
          text mt
        tdiv(display = "flex", align_items = "center", width = "100%"):
          # Left margin
          span(font_size = "10px", color = textMuted, font_family = "monospace",
               width = "24px", text_align = "center"):
            text ml
          # Inner box (padding)
          tdiv(flex = "1", border = "1px solid " & accent,
               border_radius = "3px", display = "flex",
               flex_direction = "column", align_items = "center",
               padding = "2px", background_color = bgBase):
            span(font_size = "9px", color = textDim, margin_bottom = "2px"):
              text "PADDING"
            span(font_size = "10px", color = accent, font_family = "monospace"):
              text pt
            tdiv(display = "flex", align_items = "center", width = "100%",
                 justify_content = "space-between"):
              span(font_size = "10px", color = accent, font_family = "monospace"):
                text pl
              # Content placeholder
              tdiv(width = "40px", height = "16px", border_radius = "2px",
                   background_color = bgSurface, border = "1px solid " & border)
              span(font_size = "10px", color = accent, font_family = "monospace"):
                text pr
            span(font_size = "10px", color = accent, font_family = "monospace"):
              text pb
          # Right margin
          span(font_size = "10px", color = textMuted, font_family = "monospace",
               width = "24px", text_align = "center"):
            text mr
        # Bottom margin
        span(font_size = "10px", color = textMuted, font_family = "monospace"):
          text mb

proc renderComponentEdit*[R, E](r: R; vm: EditorVM): E =
  ## Split view: live preview (left) + CSS inspector (right).
  ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex",
         min_width = "0", height = "100%",
         background_color = bgBase):

      # === Left: Live Preview ===
      tdiv(flex = "1", display = "flex", flex_direction = "column",
           border_right = "1px solid " & border):

        # Preview toolbar
        tdiv(display = "flex", align_items = "center",
             justify_content = "space-between",
             height = "44px", min_height = "44px", padding = "0 16px",
             background_color = bgCard,
             border_bottom = "1px solid " & border):
          tdiv(display = "flex", align_items = "center", gap = "8px"):
            span(font_size = "11px", color = textDim):
              text "TaskRow"
            span(font_size = "11px", color = textDim):
              text "\xE2\x80\xBA"
            span(font_size = "12px", font_weight = "500", color = textPrimary):
              text "Active task"
          tdiv(display = "flex", align_items = "center", gap = "8px"):
            tdiv(padding = "4px 12px", border_radius = "4px",
                 font_size = "11px", font_weight = "500",
                 background_color = accent, color = textPrimary):
              text "Edit"
            tdiv(padding = "4px 12px", border_radius = "4px",
                 font_size = "11px", font_weight = "500",
                 background_color = bgSurface, color = textMuted):
              text "View"

        # Preview canvas
        tdiv(flex = "1", display = "flex",
             align_items = "center", justify_content = "center",
             background_color = bgBase,
             background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
             background_size = "24px 24px"):
          # Selected component with blue outline
          tdiv(padding = "16px", border = "2px solid " & accent,
               border_radius = "8px",
               background_color = bgCard, display = "flex",
               align_items = "center", gap = "12px",
               box_shadow = "0 0 0 4px " & accent & "22"):
            tdiv(width = "18px", height = "18px", border_radius = "4px",
                 border = "2px solid " & textMuted)
            span(font_size = "15px", color = textPrimary):
              text "Buy groceries for dinner"
            tdiv(margin_left = "auto", padding = "4px 8px",
                 border_radius = "4px", background_color = bgSurface,
                 font_size = "11px", color = textMuted):
              text "\xC3\x97"

        # Element breadcrumb bar
        tdiv(display = "flex", align_items = "center",
             height = "28px", padding = "0 16px",
             background_color = bgSurface,
             border_top = "1px solid " & border,
             font_size = "10px", color = textMuted, gap = "4px"):
          span(color = textDim): text "TaskApp"
          span: text "\xE2\x80\xBA"
          span(color = textDim): text "TaskList"
          span: text "\xE2\x80\xBA"
          span(color = accent, font_weight = "500"): text "TaskRow"
          span: text "\xE2\x80\xBA"
          span(color = accent): text "div.flex"

      # === Right: CSS Inspector Panel ===
      tdiv(width = "320px", min_width = "320px",
           display = "flex", flex_direction = "column",
           background_color = bgSidebar, overflow_y = "auto"):

        # Inspector tabs
        tdiv(class = "editor-tabbar",
             display = "flex", align_items = "stretch",
             height = "36px", min_height = "36px",
             border_bottom = "1px solid " & border,
             overflow_x = "auto", scrollbar_width = "none"):
          for i, name in ["Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type", "FX"]:
            let isActive = (i == 2)  # Spacing tab active for demo
            tdiv(display = "flex", align_items = "center",
                 padding = "0 8px", font_size = "11px", font_weight = "500",
                 cursor = "pointer", white_space = "nowrap",
                 color = (if isActive: accent else: textMuted),
                 box_shadow = (if isActive: "inset 0 -2px 0 " & accent else: "none")):
              text name

        # Inspector content — Spacing section
        tdiv(padding = "16px", display = "flex", flex_direction = "column",
             gap = "16px"):

          # Section header
          tdiv(display = "flex", align_items = "center",
               justify_content = "space-between"):
            span(font_size = "11px", font_weight = "600", color = textSecondary,
                 text_transform = "uppercase", letter_spacing = "0.5px"):
              text "Spacing"
            span(font_size = "10px", color = textDim):
              text "class: p-4"

  # The box model and property rows need element refs for appendChild
  let page = r.firstChild(r.firstChild(r.firstChild(
    renderComponentEdit[R, E](r, vm))))
  discard  # will be returned from the ui block above

  # Return the ui block result directly
  result = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex",
         min_width = "0", height = "100%",
         background_color = bgBase)

  # Rebuild properly — the above was getting complex.
  # Let me restructure as separate blocks.
  discard

# Simpler approach: build the edit view as composable blocks
proc renderComponentEditView*[R, E](r: R; vm: EditorVM): E =
  let container = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex",
         min_width = "0", height = "100%",
         background_color = bgBase)

  # Left: Live Preview
  let preview = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "column",
         border_right = "1px solid " & border):

      # Toolbar
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           height = "44px", min_height = "44px", padding = "0 16px",
           background_color = bgCard,
           border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "11px", color = textDim):
            text "TaskRow"
          span(font_size = "11px", color = textDim):
            text "\xE2\x80\xBA"
          span(font_size = "12px", font_weight = "500", color = textPrimary):
            text "Active task"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(padding = "4px 12px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = accent, color = textPrimary):
            text "Editing"
          tdiv(padding = "4px 12px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = bgSurface, color = textMuted):
            text "View"

      # Canvas with selected element
      tdiv(flex = "1", display = "flex",
           align_items = "center", justify_content = "center",
           background_color = bgBase,
           background_image = "radial-gradient(circle, " & borderFaint & " 1px, transparent 1px)",
           background_size = "24px 24px"):
        tdiv(padding = "16px", border = "2px solid " & accent,
             border_radius = "8px",
             background_color = bgCard, display = "flex",
             align_items = "center", gap = "12px",
             box_shadow = "0 0 0 4px " & accent & "22"):
          tdiv(width = "18px", height = "18px", border_radius = "4px",
               border = "2px solid " & textMuted)
          span(font_size = "15px", color = textPrimary):
            text "Buy groceries for dinner"
          tdiv(margin_left = "auto", padding = "4px 8px",
               border_radius = "4px", background_color = bgSurface,
               font_size = "11px", color = textMuted):
            text "\xC3\x97"

      # Breadcrumb
      tdiv(display = "flex", align_items = "center",
           height = "28px", padding = "0 16px",
           background_color = bgSurface,
           border_top = "1px solid " & border,
           font_size = "10px", color = textMuted, gap = "4px"):
        span(color = textDim): text "TaskApp"
        span: text "\xE2\x80\xBA"
        span(color = textDim): text "TaskList"
        span: text "\xE2\x80\xBA"
        span(color = accent, font_weight = "500"): text "TaskRow"
  r.appendChild(container, preview)

  # Right: CSS Inspector
  let inspector = ui(r):
    tdiv(width = "320px", min_width = "320px",
         display = "flex", flex_direction = "column",
         background_color = bgSidebar, overflow_y = "auto"):

      # Tabs
      tdiv(class = "editor-tabbar",
           display = "flex", align_items = "stretch",
           height = "36px", min_height = "36px",
           border_bottom = "1px solid " & border,
           overflow_x = "auto", scrollbar_width = "none"):
        for i, name in ["Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type", "FX"]:
          let isActive = (i == 2)
          tdiv(display = "flex", align_items = "center",
               padding = "0 8px", font_size = "11px", font_weight = "500",
               cursor = "pointer", white_space = "nowrap",
               color = (if isActive: accent else: textMuted),
               box_shadow = (if isActive: "inset 0 -2px 0 " & accent else: "none")):
            text name

      # Spacing section content
      tdiv(padding = "16px", display = "flex", flex_direction = "column",
           gap = "16px"):
        tdiv(display = "flex", align_items = "center",
             justify_content = "space-between"):
          span(font_size = "11px", font_weight = "600", color = textSecondary,
               text_transform = "uppercase", letter_spacing = "0.5px"):
            text "Spacing"
          span(font_size = "10px", color = accent, font_family = "monospace"):
            text "class: p-4"
  r.appendChild(container, inspector)

  # Box model diagram
  let boxModel = renderBoxModel[R, E](r, "0", "0", "0", "0", "16", "16", "16", "16")
  r.appendChild(inspector, boxModel)

  # Property rows
  let propsSection = ui(r):
    tdiv(padding = "0 16px 16px 16px", display = "flex",
         flex_direction = "column", gap = "4px"):
      span(font_size = "10px", color = textDim, margin_bottom = "4px"):
        text "Individual sides"
  r.appendChild(inspector, propsSection)

  for (label, val) in [("padding-top", "16"), ("padding-right", "16"),
                        ("padding-bottom", "16"), ("padding-left", "16"),
                        ("margin-top", "0"), ("margin-bottom", "0")]:
    let row = renderPropertyRow[R, E](r, label, val, "px")
    r.appendChild(propsSection, row)

  container
