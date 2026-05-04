## IsoNim Editor — Component Detail View.
##
## Storybook-style: each variant gets its own section with title,
## description, and full-width rendering.

import isonim/core/[computation, signals]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types

const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgCard = "#151D2E"
  bgPreview = "#0D1525"
  border = "#334155"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  green = "#22C55E"
  red = "#EF4444"

proc renderGenericComponentPreview[R, E](r: R; title, description: string): E =
  ui(r):
    tdiv(width = "320px", padding = "18px",
          background_color = "#FFFFFF", color = "#0F172A",
          border_radius = "12px",
          display = "flex", flex_direction = "column", gap = "10px"):
      tdiv(height = "96px", border_radius = "10px",
            background_color = "#DBEAFE")
      span(font_size = "17px", font_weight = "700"):
        text title
      span(font_size = "13px", color = "#64748B", line_height = "1.4"):
        text description
      tdiv(display = "flex", gap = "8px"):
        tdiv(height = "24px", width = "72px", border_radius = "999px",
              background_color = "#E0E7FF")
        tdiv(height = "24px", width = "56px", border_radius = "999px",
              background_color = "#F1F5F9")

proc sectionLabel[R, E](r: R; title: string): E =
  ui(r):
    span(font_size = "11px", font_weight = "700", color = textSecondary,
          text_transform = "uppercase", letter_spacing = "1px"):
      text title

proc renderVariantSection[R, E](r: R; name, description: string;
                                  component: E): E =
  ## A single variant: header annotation + full-width preview area.
  let section = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          border = "1px solid " & border, border_radius = "8px",
          overflow = "hidden")

  # Annotation header
  let header = ui(r):
    tdiv(display = "flex", align_items = "baseline", gap = "12px",
          padding = "12px 16px",
          background_color = bgCard,
          border_bottom = "1px solid " & border):
      span(font_size = "14px", font_weight = "600", color = textPrimary):
        text name
      span(font_size = "12px", color = textMuted):
        text description
  r.appendChild(section, header)

  # Preview area (light bg to contrast with the component)
  let preview = ui(r):
    tdiv(padding = "24px", display = "flex",
          justify_content = "center",
          background_color = bgPreview,
          min_height = "120px")
  r.appendChild(preview, component)
  r.appendChild(section, preview)
  section

proc renderComponentDetail*[R, E](r: R; vm: EditorVM): E =
  let page = ui(r):
    tdiv(class = "editor-preview",
          flex = "1", display = "flex", flex_direction = "column",
          min_width = "0", height = "100%",
          background_color = bgBase, overflow_y = "auto")

  # Header bar
  var editButton: E
  var headerTitle: E
  let header = ui(r):
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
        span(ref = headerTitle,
              font_size = "13px", font_weight = "600", color = textPrimary):
          text "Component preview"
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        tdiv(ref = editButton,
              padding = "4px 12px", border_radius = "4px",
              font_size = "11px", font_weight = "500",
              background_color = accent, color = textPrimary,
              cursor = "pointer"):
          text "Edit"
        tdiv(padding = "4px 12px", border_radius = "4px",
              font_size = "11px", font_weight = "500",
              background_color = bgSurface, color = textMuted,
              cursor = "default"):
          text "Code"
  r.appendChild(page, header)
  r.setAttribute(editButton, "role", "button")
  r.setAttribute(editButton, "tabindex", "0")
  r.setAttribute(editButton, "aria-label", "Open selected component in edit mode")
  r.addEventListener(editButton, "click", proc() =
    vm.setEditMode(emEdit)
    vm.setActiveView(evComponentEdit))
  r.addEventListener(editButton, "keydown", proc() =
    vm.setEditMode(emEdit)
    vm.setActiveView(evComponentEdit))

  # Scrollable content
  let content = ui(r):
    tdiv(padding = "24px 32px", display = "flex",
          flex_direction = "column", gap = "24px")

  var projectSection: E
  var projectName: E
  var projectDescription: E
  var projectFrame: E
  let projectPreviewSection = ui(r):
    tdiv(ref = projectSection,
          display = "none", flex_direction = "column",
          border = "1px solid " & border, border_radius = "8px",
          overflow = "hidden"):
      tdiv(display = "flex", align_items = "baseline", gap = "12px",
            padding = "12px 16px",
            background_color = bgCard,
            border_bottom = "1px solid " & border):
        span(ref = projectName,
              font_size = "14px", font_weight = "600", color = textPrimary):
          text ""
        span(ref = projectDescription,
              font_size = "12px", color = textMuted):
          text ""
      tdiv(padding = "24px", display = "flex",
            justify_content = "center",
            background_color = bgPreview,
            min_height = "120px"):
        iframe(ref = projectFrame,
            title = "Component preview",
            width = "1280",
            height = "1",
            border = "0",
            scrolling = "no",
            background_color = "#FFFFFF")
  r.appendChild(content, projectPreviewSection)

  let genericContent = ui(r):
    tdiv(display = "flex", flex_direction = "column", gap = "24px")
  var renderedVariants = false
  for group in vm.sidebar.groups.val:
    if group.kind == skComponent and not renderedVariants:
      for item in group.items:
        let preview = renderGenericComponentPreview[R, E](r, item.name,
          item.description)
        let section = renderVariantSection[R, E](r, item.name,
          item.description, preview)
        r.appendChild(genericContent, section)
      renderedVariants = true

  if not renderedVariants:
    let preview = renderGenericComponentPreview[R, E](r,
      "Component preview",
      "Select a component story from the workspace sidebar.")
    let section = renderVariantSection[R, E](r,
      "Component preview",
      "Project-owned component state",
      preview)
    r.appendChild(genericContent, section)
  r.appendChild(content, genericContent)

  createRenderEffect proc() =
    let story = vm.selectedStory.val
    let preview = vm.preview.current.val
    let title =
      if preview.title.len > 0:
        preview.title
      elif story.group.len > 0 and story.name.len > 0:
        story.group & " / " & story.name
      else:
        "Component preview"
    let showProject = preview.documentHtml.len > 0 and
      story.kind in {skComponent, skPattern}

    r.setTextContent(headerTitle, title)
    r.setTextContent(projectName, story.name)
    r.setTextContent(projectDescription,
      if preview.bodyText.len > 0:
        preview.bodyText
      else:
        "Project-owned component state")
    r.setAttribute(projectFrame, "title", "Component preview " & title)
    r.setAttribute(projectFrame, "height", "1")
    r.setAttribute(projectFrame, "srcdoc",
      if showProject: preview.documentHtml else: "")
    r.setStyle(projectFrame, "width", "100%")
    r.setStyle(projectFrame, "min-height", "1px")
    r.setStyle(projectFrame, "overflow", "hidden")
    r.setStyle(projectSection, "display", if showProject: "flex" else: "none")
    r.setStyle(genericContent, "display", if showProject: "none" else: "flex")

    when defined(js):
      let frame = projectFrame
      {.emit: ["""
        const frame = """, frame, """;
        if (frame && !frame.__isonimAutoHeightInstalled) {
          frame.__isonimAutoHeightInstalled = true;
          frame.style.overflow = 'hidden';
          frame.setAttribute('scrolling', 'no');
          const resizeFrame = () => {
            try {
              const doc = frame.contentDocument;
              if (!doc) return;
              const body = doc.body;
              const html = doc.documentElement;
              if (!body || !html) return;
              body.style.overflow = 'hidden';
              html.style.overflow = 'hidden';
              const height = Math.max(
                body.scrollHeight, body.offsetHeight,
                html.clientHeight, html.scrollHeight, html.offsetHeight
              );
              frame.style.height = `${height}px`;
              frame.setAttribute('height', String(height));
            } catch (_) {
              // Cross-origin frames keep their declared height.
            }
          };
          frame.addEventListener('load', resizeFrame);
          requestAnimationFrame(resizeFrame);
        } else if (frame) {
          requestAnimationFrame(() => {
            try {
              const doc = frame.contentDocument;
              const body = doc?.body;
              const html = doc?.documentElement;
              if (!body || !html) return;
              body.style.overflow = 'hidden';
              html.style.overflow = 'hidden';
              const height = Math.max(
                body.scrollHeight, body.offsetHeight,
                html.clientHeight, html.scrollHeight, html.offsetHeight
              );
              frame.style.height = `${height}px`;
              frame.setAttribute('height', String(height));
            } catch (_) {}
          });
        }
      """].}

  # === Props / API Table ===
  let propsLabel = sectionLabel[R, E](r, "PROPERTIES")
  r.appendChild(content, propsLabel)

  let propsTable = ui(r):
    tdiv(background_color = bgCard, border = "1px solid " & border,
          border_radius = "8px", overflow = "hidden"):
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
  r.appendChild(content, propsTable)

  let propDefs = @[
    ("name", "string", "\"\"", "Destination display name"),
    ("country", "string", "\"\"", "Country name"),
    ("tagline", "string", "\"\"", "Short description shown below name"),
    ("rating", "float", "0.0", "Star rating (0.0 - 5.0)"),
    ("reviewCount", "int", "0", "Number of user reviews"),
    ("pricePerNight", "int", "0", "Average price per night in USD"),
    ("tags", "seq[string]", "@[]", "Category tags (Beach, Culture, etc.)"),
    ("isSaved", "bool", "false", "Whether user has saved this destination"),
  ]
  for prop in propDefs:
    let n = prop[0]; let t = prop[1]; let d = prop[2]; let desc = prop[3]
    let row = ui(r):
      tdiv(display = "flex", padding = "8px 16px",
            border_bottom = "1px solid " & borderFaint):
        span(width = "120px", font_size = "12px", color = accent,
              font_family = "'JetBrains Mono', monospace"):
          text n
        span(width = "100px", font_size = "11px", color = textMuted,
              font_family = "monospace"):
          text t
        span(width = "80px", font_size = "11px", color = textDim,
              font_family = "monospace"):
          text d
        span(flex = "1", font_size = "11px", color = textSecondary):
          text desc
    r.appendChild(propsTable, row)

  # === Usage Guidelines ===
  let guideLabel = sectionLabel[R, E](r, "USAGE GUIDELINES")
  r.appendChild(content, guideLabel)

  let guidelines = @[
    (true, "Use DestinationCard in a scrollable grid or carousel for discovery"),
    (false, "Use DestinationCard for trip itinerary items — use TripCard instead"),
    (true, "Show the save heart icon on all cards to encourage wishlisting"),
    (false, "Truncate the tagline — let it wrap to 2 lines naturally"),
    (true, "Show tags relevant to the user's search filters"),
    (false, "Show more than 4 tags — it clutters the card"),
  ]
  for guideline in guidelines:
    let isDo = guideline[0]; let gdesc = guideline[1]
    let rule = ui(r):
      tdiv(display = "flex", align_items = "center", gap = "10px",
            padding = "10px 16px", background_color = bgCard,
            border_radius = "6px",
            border_left = (if isDo: "3px solid " & green else: "3px solid " & red)):
        span(font_size = "12px", font_weight = "600",
              color = (if isDo: green else: red)):
          text(if isDo: "\xE2\x9C\x93 Do" else: "\xC3\x97 Don't")
        span(font_size = "12px", color = textSecondary):
          text gdesc
    r.appendChild(content, rule)

  # === Accessibility ===
  let a11yLabel = sectionLabel[R, E](r, "ACCESSIBILITY")
  r.appendChild(content, a11yLabel)

  let a11yNotes = @[
    ("Keyboard", "Tab focuses the card, Enter opens detail, Space toggles save"),
    ("ARIA", "role=\"article\" with aria-label for destination name and rating"),
    ("Screen Reader", "Announces: name, country, rating, price, saved status"),
    ("Color", "Rating stars use both color and shape; save uses fill and icon change"),
  ]
  for a11yNote in a11yNotes:
    let atopic = a11yNote[0]; let adesc = a11yNote[1]
    let note = ui(r):
      tdiv(display = "flex", align_items = "flex-start", gap = "10px",
            padding = "10px 16px", background_color = bgCard,
            border_radius = "6px"):
        tdiv(padding = "2px 8px", border_radius = "4px",
              background_color = bgSurface, font_size = "10px",
              font_weight = "600", color = textSecondary,
              white_space = "nowrap"):
          text atopic
        span(font_size = "12px", color = textSecondary, line_height = "1.4"):
          text adesc
    r.appendChild(content, note)

  # === Related ===
  let relLabel = sectionLabel[R, E](r, "RELATED")
  r.appendChild(content, relLabel)

  let relGrid = ui(r):
    tdiv(display = "flex", gap = "12px"):
      for rel in ["TripCard", "SearchBar", "FilterChip", "ReviewCard"]:
        tdiv(padding = "10px 16px", background_color = bgCard,
              border = "1px solid " & border, border_radius = "6px",
              cursor = "pointer"):
          span(font_size = "12px", color = accent):
            text rel
  r.appendChild(content, relGrid)

  r.appendChild(page, content)
  page
