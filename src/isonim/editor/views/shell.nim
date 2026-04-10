## IsoNim Editor — shell View (three-panel layout).
##
## Maps EditorVM state to visual output via the `ui` DSL.
## All styling via Tailwind classes and theme tokens.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/viewmodels
import isonim/editor/types

proc renderSidebar*[R, E](r: R; vm: EditorVM): E =
  ## Left panel: storyboard navigation tree.
  let sidebar = ui(r):
    tdiv(class = "flex flex-col h-full bg-gray-900 border-gray-700")
  r.setStyle(sidebar, "width", "280")
  r.setStyle(sidebar, "border-right", "1px solid")
  r.setStyle(sidebar, "border-color", "#1E293B")
  r.setStyle(sidebar, "overflow-y", "auto")

  # Header
  let header = ui(r):
    tdiv(class = "flex items-center justify-between p-4")
  let logo = ui(r):
    span(class = "text-sm font-bold")
  r.setTextContent(logo, "isonim editor")
  r.setStyle(logo, "color", "#E6A817")
  r.appendChild(header, logo)
  r.appendChild(sidebar, header)

  # Search input
  let searchRow = ui(r):
    tdiv(class = "px-3 pb-3")
  let searchInput = r.createElement("input")
  r.setStyle(searchInput, "width", "100%")
  r.setStyle(searchInput, "height", "32")
  r.setStyle(searchInput, "background-color", "#1E293B")
  r.setStyle(searchInput, "border-radius", "6")
  r.setStyle(searchInput, "padding", "8")
  r.setStyle(searchInput, "font-size", "13")
  r.setStyle(searchInput, "color", "#CBD5E1")
  r.setAttribute(searchInput, "placeholder", "Search stories...")
  r.appendChild(searchRow, searchInput)
  r.appendChild(sidebar, searchRow)

  # Story groups
  let groupList = ui(r):
    tdiv(class = "flex flex-col gap-1 px-2")

  createRenderEffect proc() =
    # Clear and rebuild group list on filter change
    let groups = vm.sidebar.filteredItems.val
    # In a real implementation, forEachKeyed would handle this reactively.
    # For the static layout milestone, we render from initial state.

  # Render initial groups
  for group in vm.sidebar.groups.val:
    let groupEl = ui(r):
      tdiv(class = "flex flex-col")

    # Group header
    let groupHeader = ui(r):
      tdiv(class = "flex items-center gap-2 px-2 py-1")
    r.setStyle(groupHeader, "cursor", "pointer")

    let kindIcon = ui(r):
      span(class = "text-xs")
    let icon = case group.kind
      of skFoundation: "\u{1F4E6}"
      of skComponent: "\u{1F9E9}"
      of skPage: "\u{1F4C4}"
      of skFlow: "\u{1F3AC}"
    r.setTextContent(kindIcon, icon)
    r.appendChild(groupHeader, kindIcon)

    let groupName = ui(r):
      span(class = "text-xs font-medium")
    r.setTextContent(groupName, group.name)
    r.setStyle(groupName, "color", "#94A3B8")
    r.appendChild(groupHeader, groupName)
    r.appendChild(groupEl, groupHeader)

    # Items (if expanded)
    if group.expanded:
      for item in group.items:
        let itemEl = ui(r):
          tdiv(class = "flex flex-col px-6 py-1")
        r.setStyle(itemEl, "cursor", "pointer")

        let itemName = ui(r):
          span(class = "text-xs")
        r.setTextContent(itemName, item.name)
        r.setStyle(itemName, "color", "#64748B")
        r.appendChild(itemEl, itemName)

        if item.description.len > 0:
          let itemDesc = ui(r):
            span(class = "text-xs")
          r.setTextContent(itemDesc, item.description)
          r.setStyle(itemDesc, "color", "#475569")
          r.setStyle(itemDesc, "font-size", "11")
          r.appendChild(itemEl, itemDesc)

        r.appendChild(groupEl, itemEl)

    r.appendChild(groupList, groupEl)

  r.appendChild(sidebar, groupList)
  sidebar

proc renderPreviewPane*[R, E](r: R; vm: EditorVM): E =
  ## Center panel: component preview with toolbar.
  let pane = ui(r):
    tdiv(class = "flex flex-col grow")
  r.setStyle(pane, "background-color", "#0F172A")

  # Toolbar
  let toolbar = ui(r):
    tdiv(class = "flex items-center justify-between px-4")
  r.setStyle(toolbar, "height", "48")
  r.setStyle(toolbar, "border-bottom", "1px solid")
  r.setStyle(toolbar, "border-color", "#1E293B")

  # Mode toggle
  let modeToggle = ui(r):
    tdiv(class = "flex items-center gap-2")

  let viewBtn = ui(r):
    tdiv(class = "px-3 py-1 rounded-md text-xs")
  r.setTextContent(viewBtn, "View")
  r.setStyle(viewBtn, "cursor", "pointer")

  let editBtn = ui(r):
    tdiv(class = "px-3 py-1 rounded-md text-xs")
  r.setTextContent(editBtn, "Edit")
  r.setStyle(editBtn, "cursor", "pointer")

  createRenderEffect proc() =
    if vm.editMode.val == emView:
      r.setStyle(viewBtn, "background-color", "#334155")
      r.setStyle(viewBtn, "color", "#E2E8F0")
      r.setStyle(editBtn, "background-color", "transparent")
      r.setStyle(editBtn, "color", "#64748B")
    else:
      r.setStyle(editBtn, "background-color", "#334155")
      r.setStyle(editBtn, "color", "#E2E8F0")
      r.setStyle(viewBtn, "background-color", "transparent")
      r.setStyle(viewBtn, "color", "#64748B")

  r.appendChild(modeToggle, viewBtn)
  r.appendChild(modeToggle, editBtn)
  r.appendChild(toolbar, modeToggle)

  # Platform selector
  let platformSel = ui(r):
    tdiv(class = "flex items-center gap-1")
  for plat in [pfWeb, pfIOS, pfAndroid]:
    let platBtn = ui(r):
      tdiv(class = "px-2 py-1 rounded text-xs")
    let label = case plat
      of pfWeb: "Web"
      of pfIOS: "iOS"
      of pfAndroid: "Android"
    r.setTextContent(platBtn, label)
    r.setStyle(platBtn, "cursor", "pointer")
    r.setStyle(platBtn, "color", "#64748B")
    r.appendChild(platformSel, platBtn)
  r.appendChild(toolbar, platformSel)

  r.appendChild(pane, toolbar)

  # Preview area (iframe placeholder)
  let previewArea = ui(r):
    tdiv(class = "grow flex items-center justify-center")

  createRenderEffect proc() =
    if vm.hasSelection.val:
      discard  # Show story in iframe
    # else show "Select a story" message

  let placeholder = ui(r):
    tdiv(class = "flex flex-col items-center gap-2")
  let placeholderText = ui(r):
    span(class = "text-sm")
  r.setTextContent(placeholderText, "Select a story from the sidebar")
  r.setStyle(placeholderText, "color", "#475569")
  r.appendChild(placeholder, placeholderText)
  r.appendChild(previewArea, placeholder)

  r.appendChild(pane, previewArea)
  pane

proc renderInspectorPanel*[R, E](r: R; vm: EditorVM): E =
  ## Right panel: property inspector + agent chat.
  let panel = ui(r):
    tdiv(class = "flex flex-col h-full")
  r.setStyle(panel, "width", "320")
  r.setStyle(panel, "background-color", "#0F172A")
  r.setStyle(panel, "border-left", "1px solid")
  r.setStyle(panel, "border-color", "#1E293B")
  r.setStyle(panel, "overflow-y", "auto")

  # Section tabs
  let tabs = ui(r):
    tdiv(class = "flex px-2 pt-2 gap-1")
  r.setStyle(tabs, "border-bottom", "1px solid")
  r.setStyle(tabs, "border-color", "#1E293B")

  let sectionNames = ["Layout", "Size", "Spacing", "Fill", "Border", "Type", "Effects", "State"]
  for name in sectionNames:
    let tab = ui(r):
      tdiv(class = "px-2 py-1 text-xs rounded-t")
    r.setTextContent(tab, name)
    r.setStyle(tab, "color", "#64748B")
    r.setStyle(tab, "cursor", "pointer")
    r.appendChild(tabs, tab)
  r.appendChild(panel, tabs)

  # Property content area
  let content = ui(r):
    tdiv(class = "flex flex-col p-3 gap-3 grow")

  createRenderEffect proc() =
    if vm.inspector.hasElement.val:
      discard  # Show properties for selected element
    # else show "No element selected"

  let noSelection = ui(r):
    tdiv(class = "flex flex-col items-center justify-center grow")
  let noSelText = ui(r):
    span(class = "text-xs")
  r.setTextContent(noSelText, "Select an element to inspect")
  r.setStyle(noSelText, "color", "#475569")
  r.appendChild(noSelection, noSelText)
  r.appendChild(content, noSelection)
  r.appendChild(panel, content)

  # Agent chat area (bottom section)
  let chatSection = ui(r):
    tdiv(class = "flex flex-col")
  r.setStyle(chatSection, "height", "200")
  r.setStyle(chatSection, "border-top", "1px solid")
  r.setStyle(chatSection, "border-color", "#1E293B")

  let chatHeader = ui(r):
    tdiv(class = "flex items-center px-3 py-2")
  let chatTitle = ui(r):
    span(class = "text-xs font-medium")
  r.setTextContent(chatTitle, "AI Assistant")
  r.setStyle(chatTitle, "color", "#94A3B8")
  r.appendChild(chatHeader, chatTitle)
  r.appendChild(chatSection, chatHeader)

  # Chat input
  let chatInputRow = ui(r):
    tdiv(class = "flex items-center gap-2 px-3 pb-3")
  let chatInput = r.createElement("input")
  r.setStyle(chatInput, "flex-grow", "1")
  r.setStyle(chatInput, "height", "32")
  r.setStyle(chatInput, "background-color", "#1E293B")
  r.setStyle(chatInput, "border-radius", "6")
  r.setStyle(chatInput, "padding", "8")
  r.setStyle(chatInput, "font-size", "13")
  r.setStyle(chatInput, "color", "#CBD5E1")
  r.setAttribute(chatInput, "placeholder", "Ask the AI...")
  r.appendChild(chatInputRow, chatInput)

  let sendBtn = ui(r):
    tdiv(class = "px-3 py-1 rounded-md text-xs font-medium")
  r.setTextContent(sendBtn, "Send")
  r.setStyle(sendBtn, "background-color", "#E6A817")
  r.setStyle(sendBtn, "color", "#0F172A")
  r.setStyle(sendBtn, "cursor", "pointer")
  r.appendChild(chatInputRow, sendBtn)

  r.appendChild(chatSection, chatInputRow)
  r.appendChild(panel, chatSection)

  panel

proc renderEditorShell*[R, E](r: R; vm: EditorVM): E =
  ## Top-level editor layout: sidebar + preview + inspector.
  let shell = ui(r):
    tdiv(class = "flex h-full")
  r.setStyle(shell, "font-family", "system-ui, -apple-system, sans-serif")
  r.setStyle(shell, "background-color", "#0F172A")
  r.setStyle(shell, "color", "#E2E8F0")

  let sidebarEl = renderSidebar[R, E](r, vm)
  let previewEl = renderPreviewPane[R, E](r, vm)
  let inspectorEl = renderInspectorPanel[R, E](r, vm)

  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, previewEl)
  r.appendChild(shell, inspectorEl)

  shell
