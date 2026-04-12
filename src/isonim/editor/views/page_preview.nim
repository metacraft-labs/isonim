## IsoNim Editor — Page Preview View.
##
## Renders a full Wanderlust page inside the editor preview area.
## Uses a phone-frame or desktop-frame wrapper around the actual page.

import isonim/core/computation
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import examples/wanderlust/pages/views as wPages

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

  # Render the Home page
  let homePage = wPages.renderHomePage[R, E](r)
  r.setStyle(homePage, "flex", "1")
  r.setStyle(homePage, "overflow-y", "auto")
  r.appendChild(deviceFrame, homePage)
  r.appendChild(frame, deviceFrame)
  r.appendChild(container, frame)
  container
