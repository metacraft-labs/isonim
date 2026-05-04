## IsoNim Editor — shell View (three-panel layout).
##
## Fully dogfoods IsoNim: all elements via ui macro with if/for/case.
## Only uses manual setStyle for reactive effects (createRenderEffect).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/storyboard
import isonim/editor/views/component_detail
import isonim/editor/views/component_edit
import isonim/editor/views/page_preview
import isonim/editor/views/vector_editor
import isonim/editor/views/chat_panel

# ---------------------------------------------------------------------------
# Theme tokens
# ---------------------------------------------------------------------------
const
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgToolbar = "#151D2E"
  bgCard = "#151D2E"
  border = "#334155"
  borderStrong = "#475569"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  accentSoft = "#1E3A5F"
  gold = "#F59E0B"

const inspectorSections = [
  isLayout, isSize, isSpacing, isPosition, isFill, isStroke, isTypography,
  isEffects, isTransitions, isFilters, isState]

const inspectorSectionNames = [
  "Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type", "FX", "Trans",
  "Filter", "State"]

const sidebarSections = [
  ssUserJourneys, ssPages, ssComponents, ssFoundations, ssGuidelines]

func sectionLabel(section: SidebarSection): string =
  case section
  of ssUserJourneys:
    "User Journeys"
  of ssPages:
    "Pages"
  of ssComponents:
    "Components"
  of ssFoundations:
    "Foundations"
  of ssGuidelines:
    "Guidelines"

func sectionIcon(section: SidebarSection): string =
  case section
  of ssUserJourneys:
    "\xE2\x96\xB7"
  of ssPages:
    "\xE2\x96\xA1"
  of ssComponents:
    "\xE2\x97\xBB"
  of ssFoundations:
    "\xE2\x97\x87"
  of ssGuidelines:
    "\xE2\x97\x8B"

func sectionView(section: SidebarSection): EditorView =
  case section
  of ssUserJourneys:
    evStoryboard
  of ssPages:
    evPagePreview
  of ssComponents, ssFoundations, ssGuidelines:
    evComponentDetail

func groupInSection(group: StoryGroup; section: SidebarSection): bool =
  case section
  of ssUserJourneys:
    group.kind == skFlow
  of ssPages:
    group.kind == skPage
  of ssComponents:
    group.kind in {skComponent, skPattern}
  of ssFoundations:
    group.kind == skFoundation
  of ssGuidelines:
    group.kind == skGuideline

proc makeButton[R, E](r: R; node: E; label: string) =
  r.setAttribute(node, "role", "button")
  r.setAttribute(node, "tabindex", "0")
  r.setAttribute(node, "aria-label", label)

proc groupToggleHandler(vm: EditorVM; groupName: string): proc() =
  let captured = groupName
  result = proc() = vm.sidebar.toggleGroup(captured)

proc sectionToggleHandler(vm: EditorVM; section: SidebarSection): proc() =
  let captured = section
  result = proc() =
    vm.sidebar.toggleSection(captured)

proc sectionOpenHandler(vm: EditorVM; section: SidebarSection): proc() =
  let captured = section
  result = proc() =
    vm.setActiveView(sectionView(captured))
    vm.sidebar.setSectionExpanded(captured, true)

proc storySelectHandler(vm: EditorVM; story: StoryRef): proc() =
  let captured = story
  result = proc() = discard vm.sidebar.selectStory(vm, captured)

proc platformHandler(vm: EditorVM; platform: Platform): proc() =
  let captured = platform
  result = proc() = vm.changePlatform(captured)

proc inspectorSectionHandler(vm: EditorVM; section: InspectorSection): proc() =
  let captured = section
  result = proc() = vm.switchInspectorSection(captured)

proc inspectorPropertyEditHandler[R, E](r: R; vm: EditorVM; input: E;
    property: string): proc() =
  let capturedProperty = property
  let capturedInput = input
  result = proc() =
    discard vm.editCssProperty(capturedProperty, r.inputValue(capturedInput),
      pesLocal, peoInspector)

proc activeViewHandler(vm: EditorVM; view: EditorView): proc() =
  let captured = view
  result = proc() = vm.setActiveView(captured)

proc searchInputHandler[R, E](r: R; vm: EditorVM; input: E): proc() =
  let capturedInput = input
  result = proc() = vm.sidebar.setSearch(r.inputValue(capturedInput))

proc matchesSidebarSearch(query: string; group: StoryGroup): bool =
  if query.len == 0:
    return true
  let q = query.toLowerAscii()
  if q in group.name.toLowerAscii() or q in group.description.toLowerAscii():
    return true
  for item in group.items:
    if q in item.name.toLowerAscii() or q in item.description.toLowerAscii():
      return true

proc matchesSidebarSearch(query: string; group: StoryGroup;
    item: StoryItem): bool =
  if query.len == 0:
    return true
  let q = query.toLowerAscii()
  if q in group.name.toLowerAscii() or q in group.description.toLowerAscii():
    return true
  q in item.name.toLowerAscii() or q in item.description.toLowerAscii()

proc isSelectedStory(vm: EditorVM; story: StoryRef): bool =
  let selected = vm.selectedStory.val
  selected.group == story.group and selected.name == story.name and
    selected.kind == story.kind

proc isActivePlatform(vm: EditorVM; platform: Platform): bool =
  vm.platform.val == platform

proc isActiveInspectorSection(vm: EditorVM; section: InspectorSection): bool =
  vm.inspector.activeSection.val == section

proc bindActiveViewStyle[R, E](r: R; node: E; vm: EditorVM;
    view: EditorView) =
  let captured = view
  createRenderEffect proc() =
    let isActive = vm.activeView.val == captured
    r.setStyle(node, "background-color",
        if isActive: accent else: "transparent")
    r.setStyle(node, "color", if isActive: textPrimary else: textMuted)

proc bindSidebarStoryState[R, E](r: R; node: E; vm: EditorVM;
    story: StoryRef) =
  let captured = story
  createRenderEffect proc() =
    let isSelected = vm.isSelectedStory(captured)
    r.setAttribute(node, "aria-current", if isSelected: "true" else: "false")
    r.setStyle(node, "padding",
      if isSelected: "4px 12px 4px 28px" else: "4px 12px 4px 30px")
    r.setStyle(node, "background-color",
        if isSelected: accentSoft else: "transparent")
    r.setStyle(node, "border-left", if isSelected: "2px solid " &
        accent else: "none")

proc bindSidebarGroupFilter[R, E](r: R; node: E; vm: EditorVM;
    group: StoryGroup) =
  let captured = group
  createRenderEffect proc() =
    r.setStyle(node, "display",
      if matchesSidebarSearch(vm.sidebar.searchFilter.val, captured): "flex"
      else: "none")

proc bindSidebarSectionState[R, E](r: R; header, disclosure, body: E;
    vm: EditorVM; section: SidebarSection) =
  let captured = section
  createRenderEffect proc() =
    let expanded = vm.sidebar.sections.val.isExpanded(captured)
    let active = vm.activeView.val == sectionView(captured)
    r.setAttribute(disclosure, "aria-expanded",
        if expanded: "true" else: "false")
    r.setTextContent(disclosure, if expanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
    r.setStyle(header, "background-color",
      if active: accentSoft elif expanded: bgSurface else: "transparent")
    r.setStyle(body, "display", if expanded: "flex" else: "none")

proc bindSidebarGroupState[R, E](r: R; header, body, chevron: E;
    vm: EditorVM; groupName: string) =
  let captured = groupName
  createRenderEffect proc() =
    var expanded = false
    for group in vm.sidebar.groups.val:
      if group.name == captured:
        expanded = group.expanded
    r.setAttribute(header, "aria-expanded", if expanded: "true" else: "false")
    r.setTextContent(chevron, if expanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8")
    r.setStyle(body, "display", if expanded: "flex" else: "none")

proc bindSidebarItemFilter[R, E](r: R; node: E; vm: EditorVM;
    group: StoryGroup; item: StoryItem) =
  let capturedGroup = group
  let capturedItem = item
  createRenderEffect proc() =
    r.setStyle(node, "display",
      if matchesSidebarSearch(vm.sidebar.searchFilter.val, capturedGroup,
          capturedItem): "flex" else: "none")

proc bindPlatformState[R, E](r: R; node: E; vm: EditorVM;
    platform: Platform) =
  let captured = platform
  createRenderEffect proc() =
    let isActive = vm.isActivePlatform(captured)
    r.setAttribute(node, "aria-pressed", if isActive: "true" else: "false")
    r.setStyle(node, "background-color",
        if isActive: accent else: "transparent")
    r.setStyle(node, "color", if isActive: textPrimary else: textMuted)

proc bindInspectorTabState[R, E](r: R; node: E; vm: EditorVM;
    section: InspectorSection) =
  let captured = section
  createRenderEffect proc() =
    let isActive = vm.isActiveInspectorSection(captured)
    r.setAttribute(node, "aria-selected", if isActive: "true" else: "false")
    r.setStyle(node, "color", if isActive: accent else: textMuted)
    r.setStyle(node, "box-shadow",
      if isActive: "inset 0 -2px 0 " & accent else: "none")

proc renderSidebar*[R, E](r: R; vm: EditorVM): E =
  ## Left panel: storyboard navigation tree.
  ## Built entirely with the ui DSL — if/for inside the body.
  ui(r):
    tdiv(class = "editor-sidebar",
          display = "flex", flex_direction = "column",
          width = "260px", min_width = "260px", height = "100%",
          background_color = bgSidebar,
          border_right = "1px solid " & borderStrong,
          overflow_y = "auto", overflow_x = "hidden"):

      # Header
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between",
            padding = "14px 16px 10px 16px",
            border_bottom = "1px solid " & borderFaint):
        span(font_size = "13px", font_weight = "700",
              color = gold, letter_spacing = "0.3px"):
          text "IsoNim Editor"
        tdiv(display = "flex", align_items = "center", gap = "8px"):
          span(font_size = "10px", color = textDim):
            text "v0.1"
          tdiv(class = "editor-mobile-toggle",
                width = "28px", height = "28px",
                align_items = "center", justify_content = "center",
                border_radius = "4px", background_color = bgSurface,
                color = textSecondary, font_size = "14px", cursor = "pointer"):
            text "\xE2\x98\xB0"

      # Search input
      var searchInput: E
      tdiv(padding = "10px 12px"):
        tdiv(display = "flex", align_items = "center",
              background_color = bgSurface,
              border = "1px solid " & border,
              border_radius = "6px", padding = "0 10px", height = "32px"):
          span(font_size = "11px", opacity = "0.5", margin_right = "6px"):
            text "\xF0\x9F\x94\x8D"
          input(class = "editor-input",
                ref = searchInput,
                background_color = "transparent", border = "none",
                font_size = "12px", color = textSecondary,
                outline = "none", flex = "1",
                `aria-label` = "Search stories",
                placeholder = "Search stories\xE2\x80\xA6")
      block:
        let onSearch = searchInputHandler[R, E](r, vm, searchInput)
        r.addEventListener(searchInput, "input", onSearch)
        r.addEventListener(searchInput, "change", onSearch)
        r.addEventListener(searchInput, "keyup", onSearch)

      # Story sections
      tdiv(display = "flex", flex_direction = "column",
            gap = "2px", padding = "0 8px 16px 8px"):
        for section in sidebarSections:
          let sLabel = sectionLabel(section)
          let sIcon = sectionIcon(section)
          let sExpanded = vm.sidebar.sections.val.isExpanded(section)
          let sChevron = if sExpanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8"
          let openSection = sectionOpenHandler(vm, section)
          let toggleSection = sectionToggleHandler(vm, section)
          var sectionHeader: E
          var sectionDisclosure: E
          var sectionBody: E

          tdiv(display = "flex", flex_direction = "column", gap = "2px",
                margin_bottom = "6px"):
            tdiv(display = "flex", align_items = "center",
                  gap = "4px"):
              tdiv(display = "flex", align_items = "center", flex = "1",
                    ref = sectionHeader,
                    `role` = "button", tabindex = "0",
                    `aria-label` = "Open " & sLabel & " section",
                    onclick = openSection,
                    onkeydown = openSection,
                    gap = "8px", padding = "7px 8px",
                    border_radius = "5px", cursor = "pointer",
                    background_color = (
                        if sExpanded: bgSurface else: "transparent")):
                span(font_size = "12px", color = accent):
                  text sIcon
                span(font_size = "11px", font_weight = "800",
                      color = textPrimary, text_transform = "uppercase",
                      letter_spacing = "0.8px"):
                  text sLabel
              tdiv(ref = sectionDisclosure,
                    display = "flex", align_items = "center",
                    justify_content = "center",
                    width = "24px", min_width = "24px", height = "28px",
                    border_radius = "4px",
                    `role` = "button", tabindex = "0",
                    `aria-label` = "Toggle " & sLabel & " section",
                    `aria-expanded` = (if sExpanded: "true" else: "false"),
                    onclick = toggleSection,
                    onkeydown = toggleSection,
                    font_size = "9px", color = textMuted, cursor = "pointer"):
                text sChevron

            tdiv(ref = sectionBody,
                  display = (if sExpanded: "flex" else: "none"),
                  flex_direction = "column", gap = "2px"):
              for group in vm.sidebar.groups.val:
                if groupInSection(group, section):
                  let gName = $group.name
                  let gItems = group.items
                  let gIcon = case group.kind
                    of skFoundation: "\xE2\x97\x87"
                    of skComponent: "\xE2\x97\xBB"
                    of skPattern: "\xE2\x97\xA8"
                    of skPage: "\xE2\x96\xA1"
                    of skFlow: "\xE2\x96\xB7"
                    of skGuideline: "\xE2\x97\x8B"
                  let gExpanded = group.expanded
                  let gChevron = if gExpanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8"
                  var groupNode: E
                  var groupHeader: E
                  var groupBody: E
                  var groupChevron: E

                  tdiv(display = "flex", flex_direction = "column",
                        ref = groupNode, margin_bottom = "2px"):
                    let toggleGroup = groupToggleHandler(vm, gName)
                    tdiv(display = "flex", align_items = "center",
                          ref = groupHeader,
                          `role` = "button", tabindex = "0",
                          `aria-label` = "Toggle " & gName & " stories",
                          `aria-expanded` = (
                              if gExpanded: "true" else: "false"),
                          onclick = toggleGroup,
                          onkeydown = toggleGroup,
                          gap = "6px", padding = "5px 8px 5px 18px",
                          border_radius = "4px", cursor = "pointer"):
                      span(font_size = "11px", color = textSecondary):
                        text gIcon
                      span(font_size = "10px", font_weight = "700",
                            color = textSecondary, text_transform = "uppercase",
                            letter_spacing = "0.7px"):
                        text gName
                      span(ref = groupChevron,
                            font_size = "9px", color = textMuted,
                            margin_left = "auto"):
                        text gChevron

                    tdiv(ref = groupBody,
                          display = (if gExpanded: "flex" else: "none"),
                          flex_direction = "column", gap = "1px"):
                      var itemIdx = 0
                      for item in gItems:
                        let iName = $item.name
                        let iDesc = $item.description
                        let iGroup = $item.group
                        let iKind = item.kind
                        let story = StoryRef(group: iGroup, name: iName,
                                              kind: iKind, index: itemIdx)
                        let selectStory = storySelectHandler(vm, story)
                        let selected = vm.isSelectedStory(story)
                        let storyPadding =
                          if selected: "4px 12px 4px 28px"
                          else: "4px 12px 4px 30px"
                        let storyBackground =
                          if selected: accentSoft else: "transparent"
                        let storyBorder =
                          if selected: "2px solid " & accent else: "none"
                        let storyWeight =
                          if selected: "500" else: "400"
                        var storyNode: E

                        tdiv(display = "flex", flex_direction = "column",
                              ref = storyNode,
                              `role` = "button", tabindex = "0",
                              `aria-label` = "Select story " & iGroup &
                                " / " & iName,
                              `aria-current` = (
                                  if selected: "true" else: "false"),
                              onclick = selectStory,
                              onkeydown = selectStory,
                              padding = storyPadding,
                              border_radius = "4px", cursor = "pointer",
                              transition = "background-color 0.1s",
                              background_color = storyBackground,
                              border_left = storyBorder):
                          span(font_size = "12px", line_height = "1.4",
                                color = textPrimary,
                                font_weight = storyWeight):
                            text iName
                          if iDesc.len > 0:
                            span(font_size = "11px", color = textMuted,
                                  line_height = "1.3", margin_top = "2px"):
                              text iDesc
                        block:
                          r.bindSidebarStoryState(storyNode, vm, story)
                          r.bindSidebarItemFilter(storyNode, vm, group, item)
                        inc itemIdx
                  block:
                    r.bindSidebarGroupFilter(groupNode, vm, group)
                    r.bindSidebarGroupState(groupHeader, groupBody,
                      groupChevron, vm, gName)
          block:
            r.bindSidebarSectionState(sectionHeader, sectionDisclosure,
              sectionBody, vm, section)

proc renderPreviewPane*[R, E](r: R; vm: EditorVM): E =
  ## Center panel: component preview with toolbar.
  ## viewBtn/editBtn need refs for reactive effect, so we extract them.
  let pane = ui(r):
    tdiv(class = "editor-preview",
          display = "flex", flex_direction = "column",
          flex = "1", min_width = "0", height = "100%",
          background_color = bgBase)

  # Toolbar — mode toggle buttons need refs for reactive styling
  let toolbar = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "space-between",
          height = "44px", min_height = "44px", padding = "0 16px",
          background_color = bgToolbar,
          border_bottom = "1px solid " & border)

  let modeToggle = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px")

  let viewBtn = ui(r):
    tdiv(padding = "4px 14px", border_radius = "4px",
          font_size = "12px", font_weight = "500",
          cursor = "pointer", transition = "all 0.15s"):
      text "View"

  let editBtn = ui(r):
    tdiv(padding = "4px 14px", border_radius = "4px",
          font_size = "12px", font_weight = "500",
          cursor = "pointer", transition = "all 0.15s"):
      text "Edit"
  r.makeButton(viewBtn, "Switch to view mode")
  r.makeButton(editBtn, "Switch to edit mode")
  r.addEventListener(viewBtn, "click", proc() = vm.setEditMode(emView))
  r.addEventListener(editBtn, "click", proc() = vm.setEditMode(emEdit))
  r.addEventListener(viewBtn, "keydown", proc() = vm.setEditMode(emView))
  r.addEventListener(editBtn, "keydown", proc() = vm.setEditMode(emEdit))

  # Reactive effect — only place we need manual setStyle
  createRenderEffect proc() =
    if vm.editMode.val == emView:
      r.setStyle(viewBtn, "background-color", accent)
      r.setStyle(viewBtn, "color", textPrimary)
      r.setStyle(editBtn, "background-color", "transparent")
      r.setStyle(editBtn, "color", textMuted)
    else:
      r.setStyle(editBtn, "background-color", accent)
      r.setStyle(editBtn, "color", textPrimary)
      r.setStyle(viewBtn, "background-color", "transparent")
      r.setStyle(viewBtn, "color", textMuted)

  r.appendChild(modeToggle, viewBtn)
  r.appendChild(modeToggle, editBtn)
  r.appendChild(toolbar, modeToggle)

  let viewSwitcher = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px")

  for option in [
    (evStoryboard, "Flow"),
    (evComponentDetail, "Detail"),
    (evPagePreview, "Page"),
    (evVectorEditor, "Vector")]:
    let targetView = option[0]
    let label = option[1]
    let chooseView = activeViewHandler(vm, targetView)
    let switchBtn = ui(r):
      tdiv(padding = "4px 10px", border_radius = "4px",
            font_size = "11px", font_weight = "500",
            cursor = "pointer", transition = "all 0.15s"):
        text label
    r.makeButton(switchBtn, "Open " & label & " editor view")
    r.addEventListener(switchBtn, "click", chooseView)
    r.addEventListener(switchBtn, "keydown", chooseView)
    r.bindActiveViewStyle(switchBtn, vm, targetView)
    r.appendChild(viewSwitcher, switchBtn)
  r.appendChild(toolbar, viewSwitcher)

  # Breadcrumb + platform selector — built inline
  let breadcrumb = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "6px"):
      span(font_size = "8px", color = textDim):
        text "\xE2\x97\x8B"
      span(font_size = "12px", color = textMuted):
        text "No selection"
  r.appendChild(toolbar, breadcrumb)

  let platformSel = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px"):
      for i, plat in [pfWeb, pfIOS, pfAndroid]:
        let label = case plat
          of pfWeb: "Web"
          of pfIOS: "iOS"
          of pfAndroid: "Android"
        let choosePlatform = platformHandler(vm, plat)
        var platformButton: E
        tdiv(padding = "4px 10px", border_radius = "4px",
              ref = platformButton,
              `role` = "button", tabindex = "0",
              `aria-label` = "Preview " & label & " platform",
              `aria-pressed` = (if vm.isActivePlatform(
                  plat): "true" else: "false"),
              onclick = choosePlatform,
              onkeydown = choosePlatform,
              font_size = "11px", font_weight = "500",
              cursor = "pointer", transition = "all 0.15s",
              background_color = (if vm.isActivePlatform(
                  plat): accent else: "transparent"),
              color = (if vm.isActivePlatform(
                  plat): textPrimary else: textMuted)):
          text label
        block:
          r.bindPlatformState(platformButton, vm, plat)
  r.appendChild(toolbar, platformSel)

  r.appendChild(pane, toolbar)

  # Preview area — fully inline
  let previewArea = ui(r):
    tdiv(flex = "1", display = "flex",
          align_items = "center", justify_content = "center",
          background_color = bgBase, position = "relative",
          background_image = "radial-gradient(circle, " & borderFaint &
          " 1px, transparent 1px)",
          background_size = "24px 24px"):
      tdiv(display = "flex", flex_direction = "column",
            align_items = "center", gap = "10px",
            padding = "32px", background_color = bgBase,
            border_radius = "12px"):
        tdiv(font_size = "40px", opacity = "0.25"):
          text "\xF0\x9F\x8E\xA8"
        span(font_size = "14px", color = textMuted, font_weight = "500"):
          text "Select a story from the sidebar"
        span(font_size = "12px", color = textDim):
          text "Components render here with live preview"
  r.appendChild(pane, previewArea)
  pane

proc renderInspectorPanel*[R, E](r: R; vm: EditorVM): E =
  ## Right panel: property inspector + agent chat.
  ## Fully inline except for tab active-state styling.
  ui(r):
    tdiv(class = "editor-inspector",
          display = "flex", flex_direction = "column",
          width = "300px", min_width = "300px", height = "100%",
          background_color = bgSidebar,
          border_left = "1px solid " & borderStrong):

      # Section tabs
      tdiv(class = "editor-tabbar",
            display = "flex", align_items = "stretch",
            height = "36px", min_height = "36px",
            border_bottom = "1px solid " & border,
            overflow_x = "auto", scrollbar_width = "none"):
        for i, name in inspectorSectionNames:
          let section = inspectorSections[i]
          let chooseSection = inspectorSectionHandler(vm, section)
          var tabNode: E
          tdiv(display = "flex", align_items = "center",
                ref = tabNode,
                `role` = "tab", tabindex = "0",
                `aria-label` = "Show " & name & " inspector section",
                `aria-selected` = (if vm.isActiveInspectorSection(
                    section): "true" else: "false"),
                onclick = chooseSection,
                onkeydown = chooseSection,
                padding = "0 8px", font_size = "11px", font_weight = "500",
                cursor = "pointer", white_space = "nowrap",
                transition = "color 0.15s",
                color = (if vm.isActiveInspectorSection(
                    section): accent else: textMuted),
                box_shadow = (if vm.isActiveInspectorSection(
                    section): "inset 0 -2px 0 " & accent else: "none")):
            text name
          block:
            r.bindInspectorTabState(tabNode, vm, section)

      # Property content area
      if vm.inspector.hasElement.val:
        tdiv(flex = "1", display = "flex", flex_direction = "column",
              padding = "12px", overflow_y = "auto", gap = "10px"):
          tdiv(display = "flex", flex_direction = "column", gap = "3px"):
            span(font_size = "10px", font_weight = "600",
                  color = textSecondary, text_transform = "uppercase",
                  letter_spacing = "0.5px"):
              text "Selection"
            span(font_size = "12px", color = textPrimary,
                  font_family = "monospace"):
              text vm.inspector.selectedElement.val.tag
            span(font_size = "11px", color = textDim):
              text vm.inspector.selectedElement.val.sourceFile & ":" &
                $vm.inspector.selectedElement.val.sourceLine

          for prop in vm.inspector.properties.val:
            let propName = prop.name
            let propValue = prop.value
            var propertyRow: E
            tdiv(display = "flex", flex_direction = "column", gap = "4px",
                  ref = propertyRow):
              label(font_size = "10px", color = textMuted,
                    text_transform = "uppercase", letter_spacing = "0.4px"):
                text propName
            block:
              let inputNode = ui(r):
                input(class = "editor-input",
                      height = "28px",
                      background_color = bgSurface,
                      border = "1px solid " & border,
                      border_radius = "4px", padding = "0 8px",
                      font_size = "12px", color = textPrimary,
                      outline = "none")
              r.setAttribute(inputNode, "aria-label",
                "Edit inspector property " & propName)
              r.setInputValue(inputNode, propValue)
              let editProperty =
                inspectorPropertyEditHandler[R, E](r, vm, inputNode, propName)
              r.addEventListener(inputNode, "change", editProperty)
              r.addEventListener(inputNode, "keydown", editProperty)
              r.appendChild(propertyRow, inputNode)
      else:
        tdiv(flex = "1", display = "flex", flex_direction = "column",
              align_items = "center", justify_content = "center",
              padding = "24px 16px", overflow_y = "auto"):
          tdiv(font_size = "28px", opacity = "0.25", margin_bottom = "8px"):
            text "\xF0\x9F\x94\x8D"
          span(font_size = "12px", color = textMuted):
            text "Select an element to inspect"
          span(font_size = "11px", color = textDim, margin_top = "4px"):
            text "Click any element in the preview"

      # Agent chat area
      tdiv(display = "flex", flex_direction = "column",
            height = "220px", min_height = "220px",
            border_top = "1px solid " & borderStrong,
            background_color = bgSidebar):

        # Chat header
        tdiv(display = "flex", align_items = "center", gap = "8px",
              padding = "10px 12px",
              border_bottom = "1px solid " & borderFaint):
          span(font_size = "13px"):
            text "\xE2\x9C\xA8"
          span(font_size = "11px", font_weight = "600",
                color = textSecondary, text_transform = "uppercase",
                letter_spacing = "0.5px"):
            text "AI Assistant"

        # Chat messages area
        tdiv(flex = "1", overflow_y = "auto", padding = "12px"):
          tdiv(display = "flex", align_items = "center",
                justify_content = "center", height = "100%"):
            span(font_size = "12px", color = textDim, font_style = "italic"):
              text "Ask the AI to modify components\xE2\x80\xA6"

        # Chat input row
        tdiv(display = "flex", align_items = "center", gap = "8px",
              padding = "8px 12px 12px 12px"):
          input(class = "editor-input",
                flex = "1", height = "34px",
                background_color = bgSurface,
                border = "1px solid " & border,
                border_radius = "8px", padding = "0 12px",
                font_size = "13px", color = textPrimary,
                outline = "none",
                placeholder = "Ask the AI\xE2\x80\xA6")
          tdiv(display = "flex", align_items = "center",
                `role` = "button", tabindex = "0",
                `aria-label` = "Send chat prompt",
                onclick = proc() = discard vm.sendAgentPrompt(),
                onkeydown = proc() = discard vm.sendAgentPrompt(),
                justify_content = "center",
                width = "34px", height = "34px",
                border_radius = "8px", font_size = "16px", font_weight = "700",
                background_color = accent, color = textPrimary,
                cursor = "pointer", transition = "background-color 0.15s"):
            text "\xE2\x86\x91"

proc renderEditorShell*[R, E](r: R; vm: EditorVM): E =
  ## Top-level editor layout: sidebar + storyboard/preview + inspector.
  let shell = ui(r):
    tdiv(display = "flex", width = "100%", height = "100%",
          font_family = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
          font_size = "14px", background_color = bgBase,
          color = textPrimary, overflow = "hidden")

  let sidebarEl = renderSidebar[R, E](r, vm)
  let storyboardEl = renderStoryboardCanvas[R, E](r, vm)
  let componentDetailEl = renderComponentDetail[R, E](r, vm)
  let componentEditEl = renderComponentEditView[R, E](r, vm)
  let pagePreviewEl = renderPagePreview[R, E](r, vm)
  let vectorEditorEl = renderVectorEditor[R, E](r, vm)
  let chatEl = renderChatPanel[R, E](r, vm) # ever-present on all views

  # Default: storyboard visible, everything else hidden
  r.setStyle(componentDetailEl, "display", "none")
  r.setStyle(componentEditEl, "display", "none")
  r.setStyle(pagePreviewEl, "display", "none")
  r.setStyle(vectorEditorEl, "display", "none")

  # Reactive view switching
  createRenderEffect proc() =
    let view = vm.activeView.val
    let panels = vm.panels.val
    r.setStyle(storyboardEl, "display", if view ==
        evStoryboard: "flex" else: "none")
    r.setStyle(componentDetailEl, "display", if view ==
        evComponentDetail: "flex" else: "none")
    r.setStyle(componentEditEl, "display", if view ==
        evComponentEdit: "flex" else: "none")
    r.setStyle(pagePreviewEl, "display", if view ==
        evPagePreview: "flex" else: "none")
    r.setStyle(vectorEditorEl, "display", if view ==
        evVectorEditor: "flex" else: "none")
    r.setStyle(sidebarEl, "display", if panels.sidebar and view !=
        evVectorEditor: "flex" else: "none")
    # Chat always visible
    r.setStyle(chatEl, "display", if panels.inspector: "flex" else: "none")

  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, storyboardEl)
  r.appendChild(shell, componentDetailEl)
  r.appendChild(shell, componentEditEl)
  r.appendChild(shell, pagePreviewEl)
  r.appendChild(shell, vectorEditorEl)
  r.appendChild(shell, chatEl) # always last (right side)
  shell
