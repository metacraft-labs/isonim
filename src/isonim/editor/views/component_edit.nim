## IsoNim Editor — Component Edit View.
##
## Split view: live component preview (left) + CSS inspector (right).
## Uses the ui DSL. Manual setStyle/appendChild only for composing
## the inspector's dynamic property rows.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/controls
import isonim/editor/views/inspector_sections

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
  ui(r):
    tdiv(display = "flex", flex_direction = "column",
          align_items = "center", padding = "8px 0"):
      span(font_size = "9px", color = textDim, margin_bottom = "4px"):
        text "MARGIN"
      tdiv(display = "flex", flex_direction = "column",
            align_items = "center", width = "200px",
            border = "1px dashed " & border, border_radius = "4px",
            padding = "4px"):
        span(font_size = "10px", color = textMuted, font_family = "monospace"):
          text mt
        tdiv(display = "flex", align_items = "center", width = "100%"):
          span(font_size = "10px", color = textMuted, font_family = "monospace",
                width = "24px", text_align = "center"):
            text ml
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
              span(font_size = "10px", color = accent,
                  font_family = "monospace"):
                text pl
              tdiv(width = "40px", height = "16px", border_radius = "2px",
                    background_color = bgSurface, border = "1px solid " & border)
              span(font_size = "10px", color = accent,
                  font_family = "monospace"):
                text pr
            span(font_size = "10px", color = accent, font_family = "monospace"):
              text pb
          span(font_size = "10px", color = textMuted, font_family = "monospace",
                width = "24px", text_align = "center"):
            text mr
        span(font_size = "10px", color = textMuted, font_family = "monospace"):
          text mb

proc renderComponentEditView*[R, E](r: R; vm: EditorVM): E =
  let container = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex",
          min_width = "0", height = "100%",
          background_color = bgBase)

  # Left: Live Preview
  var editModeButton: E
  var viewModeButton: E
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
            text "DestinationCard"
          span(font_size = "11px", color = textDim):
            text "\xE2\x80\xBA"
          span(font_size = "12px", font_weight = "500", color = textPrimary):
            text "Default (Santorini)"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(ref = editModeButton,
                padding = "4px 12px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                cursor = "pointer",
                background_color = accent, color = textPrimary):
            text "Edit"
          tdiv(ref = viewModeButton,
                padding = "4px 12px", border_radius = "4px",
                font_size = "11px", font_weight = "500",
                cursor = "pointer",
                background_color = bgSurface, color = textMuted):
            text "View"

      # Canvas — darker bg for contrast with component
      tdiv(flex = "1", display = "flex",
            align_items = "center", justify_content = "center",
            background_color = "#0D1525",
            background_image = "radial-gradient(circle, #1a2236 1px, transparent 1px)",
            background_size = "20px 20px")

      # Breadcrumb
      tdiv(display = "flex", align_items = "center",
            height = "32px", padding = "0 16px",
            background_color = bgSurface,
            border_top = "1px solid " & border,
            font_size = "11px", color = textMuted, gap = "4px"):
        span(color = textDim): text "DiscoverPage"
        span: text "\xE2\x80\xBA"
        span(color = textDim): text "DestinationGrid"
        span: text "\xE2\x80\xBA"
        span(color = accent, font_weight = "500"): text "DestinationCard"
  # Insert real DestinationCard into the canvas area with selection highlight
  let canvasArea = r.nextSibling(r.firstChild(preview)) # second child = canvas
  let selectionWrapper = ui(r):
    tdiv(border = "2px solid " & accent, border_radius = "16px",
          box_shadow = "0 0 0 4px " & accent & "33, 0 8px 30px rgba(0,0,0,0.4)",
          overflow = "hidden")
  let previewCard = ui(r):
    tdiv(width = "280px", padding = "20px",
          background_color = "#FFFFFF", color = "#0F172A",
          border_radius = "14px",
          box_shadow = "0 12px 36px rgba(0,0,0,0.24)",
          display = "flex", flex_direction = "column", gap = "12px"):
      tdiv(height = "120px", border_radius = "10px",
            background_color = "#DBEAFE")
      span(font_size = "18px", font_weight = "700"):
        text (if vm.selectedStory.val.kind == skComponent:
            vm.selectedStory.val.name else: "Component preview")
      span(font_size = "13px", color = "#64748B", line_height = "1.4"):
        text "Project component preview"
      tdiv(display = "flex", gap = "8px"):
        tdiv(height = "24px", width = "72px", border_radius = "999px",
              background_color = "#E0E7FF")
        tdiv(height = "24px", width = "56px", border_radius = "999px",
              background_color = "#F1F5F9")
  r.appendChild(selectionWrapper, previewCard)
  r.appendChild(canvasArea, selectionWrapper)

  r.setAttribute(editModeButton, "role", "button")
  r.setAttribute(editModeButton, "tabindex", "0")
  r.setAttribute(editModeButton, "aria-label", "Switch to edit mode")
  r.setAttribute(viewModeButton, "role", "button")
  r.setAttribute(viewModeButton, "tabindex", "0")
  r.setAttribute(viewModeButton, "aria-label", "Switch to view mode")
  r.addEventListener(editModeButton, "click", proc() =
    discard vm.runEditorCommand(eckEdit))
  r.addEventListener(editModeButton, "keydown", proc() =
    discard vm.runEditorCommand(eckEdit))
  r.addEventListener(viewModeButton, "click", proc() =
    discard vm.runEditorCommand(eckInspect))
  r.addEventListener(viewModeButton, "keydown", proc() =
    discard vm.runEditorCommand(eckInspect))
  createRenderEffect proc() =
    let editing = vm.editMode.val == emEdit
    let editState = vm.evaluateCommand(eckEdit)
    let inspectState = vm.evaluateCommand(eckInspect)
    r.setAttribute(editModeButton, "aria-pressed",
      if editing: "true" else: "false")
    r.setAttribute(viewModeButton, "aria-pressed",
      if editing: "false" else: "true")
    r.setAttribute(editModeButton, "aria-disabled",
      if editState.status == ecsDisabled: "true" else: "false")
    r.setAttribute(viewModeButton, "aria-disabled",
      if inspectState.status == ecsDisabled: "true" else: "false")
    if editState.diagnostic.len > 0:
      r.setAttribute(editModeButton, "title", editState.diagnostic)
    else:
      r.removeAttribute(editModeButton, "title")
    r.setStyle(editModeButton, "background-color",
      if editing: accent else: bgSurface)
    r.setStyle(editModeButton, "color",
      if editing: textPrimary else: textMuted)
    r.setStyle(viewModeButton, "background-color",
      if editing: bgSurface else: accent)
    r.setStyle(viewModeButton, "color",
      if editing: textMuted else: textPrimary)

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
        for i, name in ["Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type"]:
          let isActive = (i == 2)
          tdiv(display = "flex", align_items = "center",
                padding = "0 10px", font_size = "11px", font_weight = "500",
                cursor = "pointer", white_space = "nowrap",
                color = (if isActive: accent else: textMuted),
                box_shadow = (if isActive: "inset 0 -2px 0 " &
                    accent else: "none")):
            text name

  r.appendChild(container, inspector)

  # Inspector section content — show the active section
  # Default: Spacing with box model + scrub inputs
  let activeTab = vm.inspector.activeSection.val

  case activeTab
  of isLayout:
    let layoutSec = renderLayoutSection[R, E](r, vm)
    r.appendChild(inspector, layoutSec)
  of isFill:
    let fillSec = renderFillSection[R, E](r, vm)
    r.appendChild(inspector, fillSec)
  of isEffects:
    let effectsSec = renderEffectsSection[R, E](r, vm)
    r.appendChild(inspector, effectsSec)
  of isStroke:
    let strokeSec = renderStrokeSection[R, E](r, vm)
    r.appendChild(inspector, strokeSec)
  of isTransitions:
    let transSec = renderTransitionsSection[R, E](r, vm)
    r.appendChild(inspector, transSec)
  else:
    # Spacing section (default)
    let spacingHeader = ui(r):
      tdiv(padding = "12px 12px 0 12px", display = "flex",
            align_items = "center", justify_content = "space-between"):
        span(font_size = "11px", font_weight = "600", color = textSecondary,
              text_transform = "uppercase", letter_spacing = "0.5px"):
          text "Spacing"
        span(font_size = "10px", color = accent, font_family = "monospace"):
          text "class: p-4"
    r.appendChild(inspector, spacingHeader)

    let boxModel = renderBoxModel[R, E](r, "0", "0", "0", "0", "16", "16", "16", "16")
    r.appendChild(inspector, boxModel)

    let propsSection = ui(r):
      tdiv(padding = "0 12px 12px 12px", display = "flex",
            flex_direction = "column", gap = "3px")
    r.appendChild(inspector, propsSection)

    for (label, val) in [("padding-top", "16"), ("padding-right", "16"),
                          ("padding-bottom", "16"), ("padding-left", "16"),
                          ("margin-top", "0"), ("margin-bottom", "0")]:
      let row = renderScrubInput[R, E](r, label, val, "px")
      r.appendChild(propsSection, row)

  container
