## IsoNim Editor — Page Preview View.
##
## Renders a project-neutral page frame inside the editor preview area.
## Uses a phone-frame or desktop-frame wrapper around the actual page.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types

const
  bgBase = "#0B1120"
  bgCard = "#151D2E"
  border = "#334155"
  textPrimary = "#F1F5F9"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"

proc renderPagePreview*[R, E](r: R; vm: EditorVM): E =
  let container = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase):

      # Header
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            height = "44px", min_height = "44px", padding = "0 20px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "11px", color = textDim):
            text "Pages"
          span(font_size = "11px", color = textDim):
            text "\xE2\x80\xBA"
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text "Home / Discover"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          # Viewport size selector
          for size in ["Mobile", "Tablet", "Desktop"]:
            let isActive = (size == "Desktop")
            tdiv(padding = "4px 10px", border_radius = "4px",
                  font_size = "11px", font_weight = "500", cursor = "pointer",
                  background_color = (if isActive: accent else: "transparent"),
                  color = (if isActive: textPrimary else: textMuted)):
              text size

  # Page content in a scrollable frame
  let frame = ui(r):
    tdiv(flex = "1", overflow_y = "auto", overflow_x = "hidden",
          display = "flex", justify_content = "center",
          padding = "16px",
          background_color = "#0D1525",
          background_image = "radial-gradient(circle, #1a2236 1px, transparent 1px)",
          background_size = "20px 20px")

  # Render the actual page inside a device frame
  let deviceFrame = ui(r):
    tdiv(width = "100%", max_width = "520px",
          background_color = "#FFFFFF",
          border_radius = "16px",
          box_shadow = "0 20px 60px rgba(0,0,0,0.4), 0 0 0 1px rgba(255,255,255,0.05)",
          overflow = "hidden",
          display = "flex", flex_direction = "column")

  # Phone status bar
  let statusBar = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          padding = "6px 20px",
          background_color = "#FFFFFF",
          font_size = "11px", color = "#1C1917"):
      span(font_weight = "600"):
        text "9:41"
      tdiv(display = "flex", align_items = "center", gap = "4px"):
        span(font_size = "10px"):
          text "\xE2\x96\x82\xE2\x96\x82\xE2\x96\x82\xE2\x96\x82"
        span(font_size = "10px"):
          text "WiFi"
        span(font_size = "10px"):
          text "\xF0\x9F\x94\x8B"
  r.appendChild(deviceFrame, statusBar)

  let pageName =
    if vm.selectedStory.val.name.len > 0:
      vm.selectedStory.val.name
    else:
      "Project page"
  let homePage = ui(r):
    tdiv(flex = "1", overflow_y = "auto",
          padding = "24px", display = "flex",
          flex_direction = "column", gap = "18px",
          background_color = "#FFFFFF", color = "#111827"):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between"):
        tdiv(display = "flex", flex_direction = "column", gap = "4px"):
          span(font_size = "24px", font_weight = "800"):
            text pageName
          span(font_size = "13px", color = "#64748B"):
            text "Workspace page preview"
        tdiv(width = "36px", height = "36px", border_radius = "999px",
              background_color = "#DBEAFE")
      tdiv(height = "140px", border_radius = "14px",
            background_color = "#E0F2FE")
      tdiv(display = "grid", grid_template_columns = "1fr 1fr",
            gap = "12px"):
        for i in 0 .. 3:
          tdiv(height = "92px", border_radius = "10px",
                background_color = (if i == 0: "#EEF2FF" else: "#F1F5F9"))
      tdiv(display = "flex", flex_direction = "column", gap = "8px"):
        for i in 0 .. 2:
          tdiv(height = "42px", border_radius = "8px",
                background_color = "#F8FAFC",
                border = "1px solid #E2E8F0")
  r.appendChild(deviceFrame, homePage)
  r.appendChild(frame, deviceFrame)
  r.appendChild(container, frame)
  container
