## IsoNim Editor — Component Detail View.
##
## Shown when a component is selected in the sidebar.
## Follows the standard component page anatomy:
## 1. Hero example (default state, large)
## 2. Variant gallery (all states side by side)
## 3. Props/API table
## 4. Usage guidelines (Do/Don't pairs)
## 5. Accessibility notes
## 6. Related components

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
  green = "#22C55E"
  red = "#EF4444"

# Mock data for the component detail page
type
  MockVariant = object
    name: string
    description: string
    accent: string  # border color hint

proc mockTaskRowVariants(): seq[MockVariant] =
  @[
    MockVariant(name: "Active", description: "Normal uncompleted task", accent: accent),
    MockVariant(name: "Completed", description: "Strikethrough, dimmed", accent: green),
    MockVariant(name: "Long Title", description: "Text overflow behavior", accent: gold),
    MockVariant(name: "Saving", description: "Loading state, dimmed", accent: textMuted),
    MockVariant(name: "Error", description: "Save failed indicator", accent: red),
  ]

proc mockProps(): seq[ComponentProp] =
  @[
    ComponentProp(name: "text", propType: "string", defaultVal: "\"\"", description: "Task display text"),
    ComponentProp(name: "completed", propType: "bool", defaultVal: "false", description: "Whether the task is checked off"),
    ComponentProp(name: "saveStatus", propType: "AsyncState", defaultVal: "asIdle", description: "Network save state"),
    ComponentProp(name: "onToggle", propType: "proc()", defaultVal: "nil", description: "Called when checkbox is toggled"),
    ComponentProp(name: "onDelete", propType: "proc()", defaultVal: "nil", description: "Called when delete button is pressed"),
  ]

proc mockUsageExamples(): seq[UsageExample] =
  @[
    UsageExample(description: "Use TaskRow for individual items in a task list", isDo: true),
    UsageExample(description: "Use TaskRow for navigation items or menu entries", isDo: false),
    UsageExample(description: "Show a loading indicator when save is in progress", isDo: true),
    UsageExample(description: "Disable the entire row while saving — keep it interactive", isDo: false),
  ]

proc mockA11yNotes(): seq[AccessibilityNote] =
  @[
    AccessibilityNote(topic: "Keyboard", description: "Space/Enter toggles checkbox, Delete removes task"),
    AccessibilityNote(topic: "ARIA", description: "role=\"checkbox\" with aria-checked on the toggle"),
    AccessibilityNote(topic: "Screen Reader", description: "Announces task text followed by completion state"),
  ]

proc renderComponentDetail*[R, E](r: R; vm: EditorVM): E =
  ## Component detail page — hero + variants + props + guidelines.
  let variants = mockTaskRowVariants()
  let props = mockProps()
  let usageExamples = mockUsageExamples()
  let a11yNotes = mockA11yNotes()

  let page = ui(r):
    tdiv(class = "editor-preview",
         flex = "1", display = "flex", flex_direction = "column",
         min_width = "0", height = "100%",
         background_color = bgBase, overflow_y = "auto"):

      # Header bar
      tdiv(display = "flex", align_items = "center",
           justify_content = "space-between",
           height = "44px", min_height = "44px", padding = "0 20px",
           background_color = bgCard,
           border_bottom = "1px solid " & border):
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "11px", color = textDim):
            text "Components"
          span(font_size = "11px", color = textDim):
            text "\xE2\x80\xBA"
          span(font_size = "13px", font_weight = "600", color = textPrimary):
            text "TaskRow"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          tdiv(padding = "4px 12px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = accent, color = textPrimary,
               cursor = "pointer"):
            text "Edit"
          tdiv(padding = "4px 12px", border_radius = "4px",
               font_size = "11px", font_weight = "500",
               background_color = bgSurface, color = textMuted,
               cursor = "pointer"):
            text "Code"

      # Scrollable content
      tdiv(padding = "24px 32px", display = "flex", flex_direction = "column",
           gap = "32px"):

        # === Section 1: Hero Example ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "DEFAULT STATE"
          # Hero card — large preview
          tdiv(background_color = bgCard, border = "1px solid " & border,
               border_radius = "12px", padding = "24px",
               display = "flex", align_items = "center", gap = "12px"):
            # Mock task row at large scale
            tdiv(width = "18px", height = "18px", border_radius = "4px",
                 border = "2px solid " & textMuted)
            span(font_size = "16px", color = textPrimary):
              text "Buy groceries for dinner"
            tdiv(margin_left = "auto", padding = "4px 8px",
                 border_radius = "4px", background_color = bgSurface,
                 font_size = "11px", color = textMuted, cursor = "pointer"):
              text "\xC3\x97"

        # === Section 2: Variants Gallery ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "VARIANTS"
          tdiv(display = "flex", flex_wrap = "wrap", gap = "12px"):
            for v in variants:
              let vName = v.name
              let vDesc = v.description
              let vAccent = v.accent
              tdiv(background_color = bgCard, border = "1px solid " & border,
                   border_radius = "8px", width = "200px",
                   overflow = "hidden", cursor = "pointer",
                   transition = "border-color 0.15s"):
                # Mini preview
                tdiv(padding = "12px", background_color = bgBase,
                     display = "flex", align_items = "center", gap = "8px"):
                  tdiv(width = "12px", height = "12px", border_radius = "3px",
                       border = "1.5px solid " & vAccent)
                  tdiv(height = "6px", flex = "1", border_radius = "3px",
                       background_color = textDim, opacity = "0.3")
                # Label
                tdiv(padding = "8px 12px"):
                  span(font_size = "12px", font_weight = "500", color = textPrimary):
                    text vName
                  tdiv(font_size = "10px", color = textMuted, margin_top = "2px"):
                    text vDesc

        # === Section 3: Props / API Table ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "PROPERTIES"
          tdiv(background_color = bgCard, border = "1px solid " & border,
               border_radius = "8px", overflow = "hidden"):
            # Table header
            tdiv(display = "flex", padding = "8px 16px",
                 background_color = bgSurface,
                 border_bottom = "1px solid " & border):
              span(width = "120px", font_size = "10px", font_weight = "600",
                   color = textSecondary):
                text "Name"
              span(width = "100px", font_size = "10px", font_weight = "600",
                   color = textSecondary):
                text "Type"
              span(width = "80px", font_size = "10px", font_weight = "600",
                   color = textSecondary):
                text "Default"
              span(flex = "1", font_size = "10px", font_weight = "600",
                   color = textSecondary):
                text "Description"
            # Table rows
            for p in props:
              let pName = p.name
              let pType = p.propType
              let pDefault = p.defaultVal
              let pDesc = p.description
              tdiv(display = "flex", padding = "8px 16px",
                   border_bottom = "1px solid " & borderFaint):
                span(width = "120px", font_size = "12px", color = accent,
                     font_family = "monospace"):
                  text pName
                span(width = "100px", font_size = "11px", color = textMuted,
                     font_family = "monospace"):
                  text pType
                span(width = "80px", font_size = "11px", color = textDim,
                     font_family = "monospace"):
                  text pDefault
                span(flex = "1", font_size = "11px", color = textSecondary):
                  text pDesc

        # === Section 4: Usage Guidelines (Do/Don't) ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "USAGE GUIDELINES"
          tdiv(display = "flex", flex_direction = "column", gap = "8px"):
            for ex in usageExamples:
              let exDesc = ex.description
              let exIsDo = ex.isDo
              tdiv(display = "flex", align_items = "center", gap = "10px",
                   padding = "10px 16px", background_color = bgCard,
                   border_radius = "6px",
                   border_left = (if exIsDo: "3px solid " & green else: "3px solid " & red)):
                span(font_size = "12px", font_weight = "600",
                     color = (if exIsDo: green else: red)):
                  text(if exIsDo: "\xE2\x9C\x93 Do" else: "\xC3\x97 Don't")
                span(font_size = "12px", color = textSecondary):
                  text exDesc

        # === Section 5: Accessibility ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "ACCESSIBILITY"
          tdiv(display = "flex", flex_direction = "column", gap = "8px"):
            for note in a11yNotes:
              let nTopic = note.topic
              let nDesc = note.description
              tdiv(display = "flex", align_items = "flex-start", gap = "10px",
                   padding = "10px 16px", background_color = bgCard,
                   border_radius = "6px"):
                tdiv(padding = "2px 8px", border_radius = "4px",
                     background_color = bgSurface, font_size = "10px",
                     font_weight = "600", color = textSecondary,
                     white_space = "nowrap"):
                  text nTopic
                span(font_size = "12px", color = textSecondary,
                     line_height = "1.4"):
                  text nDesc

        # === Section 6: Related Components ===
        tdiv(display = "flex", flex_direction = "column", gap = "12px"):
          span(font_size = "10px", font_weight = "600", color = textDim,
               text_transform = "uppercase", letter_spacing = "1px"):
            text "RELATED"
          tdiv(display = "flex", gap = "12px"):
            for rel in ["FilterBar", "InputRow", "TaskApp"]:
              tdiv(padding = "10px 16px", background_color = bgCard,
                   border = "1px solid " & border, border_radius = "6px",
                   cursor = "pointer", transition = "border-color 0.15s"):
                span(font_size = "12px", color = accent):
                  text rel

  page
