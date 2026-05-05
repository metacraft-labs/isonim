## IsoNim Editor — shell View (three-panel layout).
##
## Fully dogfoods IsoNim: all elements via ui macro with if/for/case.
## Only uses manual setStyle for reactive effects (createRenderEffect).

import std/strutils

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/storyboard
import isonim/editor/views/component_detail
import isonim/editor/views/component_edit
import isonim/editor/views/foundations_page
import isonim/editor/views/page_preview
import isonim/editor/views/vector_editor
import isonim/editor/views/chat_panel

# ---------------------------------------------------------------------------
# Theme tokens
# ---------------------------------------------------------------------------
const
  editorProductName = "IsoNim Editor"
  editorVersion = "0.1.0"
  bgBase = "#0B1120"
  bgSurface = "#1E293B"
  bgSidebar = "#111827"
  bgToolbar = "#151D2E"
  border = "#334155"
  borderStrong = "#475569"
  borderFaint = "#1E293B"
  textPrimary = "#F1F5F9"
  textSecondary = "#94A3B8"
  textMuted = "#64748B"
  textDim = "#475569"
  accent = "#3B82F6"
  accentSoft = "#1E3A5F"

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
  of ssComponents, ssGuidelines:
    evComponentDetail
  of ssFoundations:
    evFoundationsPage

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

func groupShowsStoriesInSidebar(group: StoryGroup): bool =
  ## User Journeys are opened as journey rows; their step/page cards live on
  ## the storyboard canvas and navigate to the matching Pages story.
  group.kind != skFlow

proc makeButton[R, E](r: R; node: E; label: string) =
  r.setAttribute(node, "role", "button")
  r.setAttribute(node, "tabindex", "0")
  r.setAttribute(node, "aria-label", label)

proc groupToggleHandler(vm: EditorVM; groupName: string): proc() =
  let captured = groupName
  result = proc() = vm.sidebar.toggleGroup(captured)

proc journeyOpenHandler(vm: EditorVM): proc() =
  result = proc() =
    vm.setActiveView(evStoryboard)
    vm.sidebar.setSectionExpanded(ssUserJourneys, true)

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

proc editModeHandler(vm: EditorVM; mode: EditMode): proc() =
  let captured = mode
  result = proc() =
    case captured
    of emView:
      discard vm.runEditorCommand(eckInspect)
    of emComment:
      discard vm.runEditorCommand(eckComment)
    of emEdit:
      discard vm.runEditorCommand(eckEdit)

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

proc bindStatusPanelButton[R, E](r: R; node: E; vm: EditorVM;
    panel: EditorPanel) =
  let captured = panel
  createRenderEffect proc() =
    let panels = vm.panels.val
    let active =
      case captured
      of epSidebar: panels.sidebar
      of epInspector: panels.inspector
    r.setAttribute(node, "aria-pressed", if active: "true" else: "false")
    r.setStyle(node, "background-color", if active: bgSurface else: "transparent")
    r.setStyle(node, "color", if active: textSecondary else: textDim)

proc bindRightPanelWidth[R, E](r: R; node: E; vm: EditorVM) =
  createRenderEffect proc() =
    let width = $vm.rightPanelWidth.val & "px"
    r.setStyle(node, "width", width)
    r.setStyle(node, "min-width", width)
    r.setStyle(node, "max-width", width)
    r.setAttribute(node, "data-right-panel-width", $vm.rightPanelWidth.val)

proc statusPanelButton[R, E](r: R; vm: EditorVM; panel: EditorPanel;
    label, glyph: string): E =
  result = ui(r):
    tdiv(width = "24px", height = "22px", border_radius = "4px",
          display = "flex", align_items = "center", justify_content = "center",
          font_size = "12px", font_weight = "700",
          cursor = "pointer", transition = "all 0.12s"):
      text glyph
  r.makeButton(result, label)
  r.addEventListener(result, "click", proc() = vm.togglePanel(panel))
  r.addEventListener(result, "keydown", proc() = vm.togglePanel(panel))
  r.bindStatusPanelButton(result, vm, panel)

proc statusBreadcrumbParts(vm: EditorVM): seq[string] =
  let story = vm.selectedStory.val
  if story.group.len > 0:
    result.add story.group
  if story.name.len > 0:
    result.add story.name
  let element = vm.inspector.selectedElement.val
  if element.ancestors.len > 0:
    result.add element.ancestors
  elif element.tag.len > 0:
    result.add element.tag

proc dispatchPreviewAncestorSelection(index: int) =
  when defined(js):
    {.emit: ["""
      window.dispatchEvent(new CustomEvent('isonim-select-preview-ancestor', {
        detail: { index: """, index, """ }
      }));
    """].}
  else:
    discard index

proc dispatchPreviewElementSelection(id: string) =
  when defined(js):
    {.emit: ["""
      (function () {
      const toJsString = (raw) => Array.isArray(raw)
        ? String.fromCharCode.apply(null, raw)
        : String(raw || '');
      window.dispatchEvent(new CustomEvent('isonim-select-preview-element-id', {
        detail: { id: toJsString(""", id, """) }
      }));
      })();
    """].}
  else:
    discard id

proc previewAncestorSelectionHandler(vm: EditorVM; index: int; id: string): proc() =
  let captured = index
  let capturedId = id
  result = proc() =
    dispatchPreviewAncestorSelection(captured)
  if capturedId.len > 0:
    result = proc() =
      discard vm.selectInspectorElementById(capturedId)
      dispatchPreviewAncestorSelection(captured)
      dispatchPreviewElementSelection(capturedId)

func selectedOriginLabel(element: ElementRef): string =
  if element.properties.len == 0:
    return "none"
  case element.properties[0].origin
  of poTailwindClass: "class"
  of poSetStyle: "style"
  of poThemeToken: "token"
  of poConstant: "const"
  of poInherited: "inherited"

func selectedScopeLabel(element: ElementRef): string =
  for prop in element.properties:
    if prop.sharedCount > 0:
      return "shared"
  if element.tag.len > 0: "local" else: "none"

proc renderStatusBar[R, E](r: R; vm: EditorVM): E =
  var breadcrumbNode: E
  var leftControls: E
  var rightControls: E
  var statusBadges: E
  result = ui(r):
    tdiv(class = "editor-statusbar",
          height = "26px", min_height = "26px",
          display = "flex", align_items = "center",
          justify_content = "space-between",
          gap = "10px", padding = "0 8px",
          background_color = bgToolbar,
          border_top = "1px solid " & border,
          color = textMuted, font_size = "11px"):
      tdiv(ref = leftControls,
            display = "flex", align_items = "center", gap = "6px"):
        discard
      tdiv(display = "flex", align_items = "center", gap = "6px",
            min_width = "0", flex = "1"):
        span(font_size = "10px", color = textDim):
          text "\xE2\x80\xA2"
        tdiv(ref = breadcrumbNode,
              display = "flex", align_items = "center", gap = "4px",
              min_width = "0", overflow = "hidden"):
          discard
      tdiv(ref = rightControls,
            display = "flex", align_items = "center", gap = "6px"):
        tdiv(ref = statusBadges,
              display = "flex", align_items = "center", gap = "5px",
              min_width = "0", overflow = "hidden"):
          discard
        span(color = textDim):
          text editorProductName & " v" & editorVersion
  r.appendChild(leftControls,
    statusPanelButton[R, E](r, vm, epSidebar, "Toggle left sidebar",
      "\xE2\x87\xA4"))
  r.appendChild(rightControls,
    statusPanelButton[R, E](r, vm, epInspector, "Toggle right sidebar",
      "\xE2\x87\xA5"))
  createRenderEffect proc() =
    r.clearChildren(statusBadges)
    let selected = vm.inspector.selectedElement.val
    let dirty = if vm.inspector.isDirty.val: "dirty" else: "clean"
    let write =
      if not vm.workspacePermissions.val.writeSource:
        "read-only"
      elif vm.workspaceEditAdapter != nil and vm.workspaceEditAdapter.stagingOnly:
        "staging-only"
      elif vm.sourceAdapterReady.val:
        "writable"
      else:
        "bridge missing"
    let mode = case vm.editMode.val
      of emView: "View"
      of emComment: "Comment"
      of emEdit: "Edit"
    for badge in [
      "mode " & mode,
      "element " & (if selected.tag.len > 0: selected.tag else: "none"),
      dirty,
      "scope " & selectedScopeLabel(selected),
      "binding " & selectedOriginLabel(selected),
      "write " & write
    ]:
      let node = ui(r):
        span(white_space = "nowrap", color = textDim,
              font_size = "10px"):
          text badge
      r.appendChild(statusBadges, node)

    r.clearChildren(breadcrumbNode)
    let parts = statusBreadcrumbParts(vm)
    if parts.len == 0:
      let empty = ui(r):
        span(white_space = "nowrap", overflow = "hidden",
              text_overflow = "ellipsis"):
          text "No selection"
      r.appendChild(breadcrumbNode, empty)
    else:
      let storyDepth = (if vm.selectedStory.val.group.len > 0: 1 else: 0) +
        (if vm.selectedStory.val.name.len > 0: 1 else: 0)
      for i, part in parts:
        let label = part
        let chip = ui(r):
          tdiv(`role` = "button", tabindex = "0",
                `aria-label` = "Select breadcrumb " & label,
                padding = "2px 5px", border_radius = "4px",
                white_space = "nowrap", overflow = "hidden",
                text_overflow = "ellipsis", max_width = "180px",
                cursor = "pointer",
                background_color = (if i >= storyDepth: bgSurface else: "transparent"),
                color = (if i == parts.high: textPrimary else: textMuted)):
            text label
        let ancestorIndex = i - storyDepth
        if ancestorIndex >= 0:
          let ids = vm.inspector.selectedElement.val.ancestorIds
          let id =
            if ancestorIndex >= 0 and ancestorIndex < ids.len: ids[ancestorIndex]
            else: ""
          let selectAncestor = previewAncestorSelectionHandler(vm,
            ancestorIndex, id)
          r.addEventListener(chip, "click", selectAncestor)
          r.addEventListener(chip, "keydown", selectAncestor)
        r.appendChild(breadcrumbNode, chip)
        if i < parts.high:
          let sep = ui(r):
            span(color = textDim):
              text "/"
          r.appendChild(breadcrumbNode, sep)

proc renderSidebar*[R, E](r: R; vm: EditorVM): E =
  ## Left panel: storyboard navigation tree.
  ## Built entirely with the ui DSL — if/for inside the body.
  ui(r):
    tdiv(class = "editor-sidebar",
          display = "flex", flex_direction = "column",
          width = "260px", min_width = "180px", max_width = "420px",
          resize = "horizontal", height = "100%",
          background_color = bgSidebar,
          border_right = "1px solid " & borderStrong,
          overflow_y = "auto", overflow_x = "hidden"):

      # Search input
      var searchInput: E
      tdiv(padding = "8px 10px",
            border_bottom = "1px solid " & borderFaint):
        tdiv(display = "flex", align_items = "center",
              background_color = bgSurface,
              border = "1px solid " & border,
              border_radius = "5px", padding = "0 8px", height = "28px"):
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
            gap = "2px", padding = "8px 8px 16px 8px"):
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
                  let gShowsStories = groupShowsStoriesInSidebar(group)
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
                    let openJourney = journeyOpenHandler(vm)
                    tdiv(display = "flex", align_items = "center",
                          ref = groupHeader,
                          `role` = "button", tabindex = "0",
                          `aria-label` = (
                              if gShowsStories: "Toggle " & gName & " stories"
                              else: "Open " & gName & " journey"),
                          `aria-expanded` = (
                              if gShowsStories:
                                if gExpanded: "true" else: "false"
                              else: "false"),
                          onclick = (
                              if gShowsStories: toggleGroup else: openJourney),
                          onkeydown = (
                              if gShowsStories: toggleGroup else: openJourney),
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
                        if gShowsStories:
                          text gChevron

                    if gShowsStories:
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
                    else:
                      tdiv(ref = groupBody, display = "none")
                  block:
                    r.bindSidebarGroupFilter(groupNode, vm, group)
                    if gShowsStories:
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

  var modeButtons: seq[(EditMode, E)] = @[]
  for option in [(emView, "View"), (emComment, "Comment"), (emEdit, "Edit")]:
    let capturedMode = option[0]
    let label = option[1]
    let modeBtn = ui(r):
      tdiv(padding = "4px 12px", border_radius = "4px",
            font_size = "12px", font_weight = "500",
            cursor = "pointer", transition = "all 0.15s"):
        text label
    r.makeButton(modeBtn, "Switch to " & label.toLowerAscii() & " mode")
    let chooseMode = editModeHandler(vm, capturedMode)
    r.addEventListener(modeBtn, "click", chooseMode)
    r.addEventListener(modeBtn, "keydown", chooseMode)
    r.appendChild(modeToggle, modeBtn)
    modeButtons.add (capturedMode, modeBtn)

  # Reactive effect — only place we need manual setStyle
  createRenderEffect proc() =
    for (mode, node) in modeButtons:
      let active = vm.editMode.val == mode
      let command = case mode
        of emView: eckInspect
        of emComment: eckComment
        of emEdit: eckEdit
      let state = vm.evaluateCommand(command)
      r.setStyle(node, "background-color", if active: accent else: "transparent")
      r.setStyle(node, "color", if active: textPrimary else: textMuted)
      r.setAttribute(node, "aria-pressed", if active: "true" else: "false")
      r.setAttribute(node, "aria-disabled",
        if state.status == ecsDisabled: "true" else: "false")
      if state.diagnostic.len > 0:
        r.setAttribute(node, "title", state.diagnostic)
      else:
        r.removeAttribute(node, "title")

  r.appendChild(toolbar, modeToggle)

  let viewSwitcher = ui(r):
    tdiv(display = "flex", align_items = "center", gap = "1px",
          background_color = bgSurface, border_radius = "6px",
          padding = "3px")

  for option in [
    (evStoryboard, "Flow"),
    (evComponentDetail, "Detail"),
    (evPagePreview, "Page"),
    (evFoundationsPage, "Foundations"),
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
  result = ui(r):
    tdiv(class = "editor-inspector",
          display = "flex", flex_direction = "column",
          width = "320px", min_width = "320px", max_width = "320px",
          height = "100%",
          background_color = bgSidebar,
          border_left = "1px solid " & borderStrong,
          overflow_x = "hidden"):

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
  r.bindRightPanelWidth(result, vm)

proc renderCommandPalette[R, E](r: R; vm: EditorVM): E =
  var listNode: E
  var searchInput: E
  var diagnosticNode: E
  result = ui(r):
    tdiv(`data-editor-command-palette` = "true",
          role = "dialog",
          `aria-modal` = "true",
          `aria-label` = "Editor command palette",
          position = "fixed", inset = "0", z_index = "50",
          display = "none", align_items = "flex-start",
          justify_content = "center",
          padding_top = "80px",
          background_color = "rgba(2, 6, 23, 0.66)"):
      tdiv(width = "520px", max_width = "calc(100vw - 32px)",
            border = "1px solid " & borderStrong,
            border_radius = "8px",
            background_color = bgSidebar,
            box_shadow = "0 24px 80px rgba(0, 0, 0, 0.42)",
            overflow = "hidden"):
        input(ref = searchInput,
              class = "editor-input",
              height = "42px", width = "100%",
              background_color = bgSurface,
              border = "0",
              border_bottom = "1px solid " & border,
              padding = "0 14px",
              font_size = "13px",
              color = textPrimary,
              outline = "none",
              `aria-label` = "Search editor commands",
              `aria-controls` = "isonim-command-palette-list",
              placeholder = "Search commands")
        tdiv(ref = diagnosticNode,
              id = "isonim-command-palette-diagnostic",
              role = "status",
              `aria-live` = "polite",
              min_height = "18px",
              padding = "6px 10px 0 10px",
              font_size = "10px",
              color = textDim):
          text "Use arrow keys to choose a command."
        tdiv(ref = listNode,
              id = "isonim-command-palette-list",
              role = "listbox",
              `aria-label` = "Editor commands",
              display = "flex", flex_direction = "column",
              max_height = "420px", overflow_y = "auto",
              padding = "6px"):
          discard

  let paletteRoot = result
  when defined(js):
    {.emit: ["""
      (function () {
        const root = """, paletteRoot, """;
        const input = """, searchInput, """;
        const list = """, listNode, """;
        const diagnostic = """, diagnosticNode, """;
        if (!root || root.__isonimPaletteReady) return;
        root.__isonimPaletteReady = true;
        root.__isonimActiveIndex = 0;

        const options = () => Array.from(
          root.querySelectorAll('[data-editor-command-option="true"]')
        );
        const writeDiagnostic = (message) => {
          if (diagnostic) diagnostic.textContent = message || '';
        };
        const setActive = (index, focusOption) => {
          const items = options();
          if (!items.length) {
            root.__isonimActiveIndex = 0;
            if (input) input.removeAttribute('aria-activedescendant');
            return;
          }
          const next = Math.max(0, Math.min(items.length - 1, index));
          root.__isonimActiveIndex = next;
          items.forEach((item, i) => {
            const active = i === next;
            item.setAttribute('tabindex', active ? '0' : '-1');
            item.setAttribute('aria-selected', active ? 'true' : 'false');
          });
          const active = items[next];
          if (input && active.id) {
            input.setAttribute('aria-activedescendant', active.id);
          }
          writeDiagnostic(active.getAttribute('data-command-diagnostic') || 'Ready');
          if (focusOption && active.focus) active.focus({ preventScroll: true });
          if (active.scrollIntoView) active.scrollIntoView({ block: 'nearest' });
        };
        const move = (delta, focusOption) => {
          const items = options();
          if (!items.length) return;
          setActive((root.__isonimActiveIndex || 0) + delta, focusOption);
        };
        const activate = () => {
          const items = options();
          const active = items[root.__isonimActiveIndex || 0];
          if (!active) return;
          if (active.getAttribute('aria-disabled') === 'true') {
            writeDiagnostic(active.getAttribute('data-command-diagnostic') || 'Command unavailable.');
            return;
          }
          active.click();
        };
        const firstFocusable = () => input;
        const lastFocusable = () => options()[root.__isonimActiveIndex || 0] || input;
        const restoreReturnFocus = () => {
          const target = root.__isonimReturnFocus;
          if (target && target.focus) {
            setTimeout(() => target.focus({ preventScroll: true }), 0);
            setTimeout(() => target.focus({ preventScroll: true }), 25);
          }
        };
        root.__isonimPaletteReset = () => setActive(0, false);
        root.addEventListener('focusin', (event) => {
          const item = event.target && event.target.closest
            ? event.target.closest('[data-editor-command-option="true"]')
            : null;
          if (!item) return;
          const index = options().indexOf(item);
          if (index >= 0) setActive(index, false);
        });
        root.addEventListener('keydown', (event) => {
          if (root.getAttribute('aria-hidden') === 'true') return;
          const key = event.key;
          if (key === 'ArrowDown') {
            event.preventDefault();
            move(1, event.target !== input);
          } else if (key === 'ArrowUp') {
            event.preventDefault();
            move(-1, event.target !== input);
          } else if (key === 'Home') {
            event.preventDefault();
            setActive(0, event.target !== input);
          } else if (key === 'End') {
            event.preventDefault();
            setActive(options().length - 1, event.target !== input);
          } else if (key === 'Enter' ||
              ((key === ' ' || key === 'Space' || key === 'Spacebar') && event.target !== input)) {
            event.preventDefault();
            activate();
          } else if (key === 'Escape') {
            event.preventDefault();
            const close = new CustomEvent('isonim-command-palette-close', { bubbles: true });
            root.dispatchEvent(close);
            restoreReturnFocus();
          } else if (key === 'Tab') {
            const first = firstFocusable();
            const last = lastFocusable();
            if (!first || !last) return;
            if (event.shiftKey && document.activeElement === first) {
              event.preventDefault();
              last.focus({ preventScroll: true });
            } else if (!event.shiftKey && document.activeElement === last) {
              event.preventDefault();
              first.focus({ preventScroll: true });
            }
          }
        });
      })();
    """].}
  r.addEventListener(paletteRoot, "isonim-command-palette-close", proc() =
    vm.closeCommandPalette())

  proc bindPaletteItem(item: E; commandKind: EditorCommandKind) =
    let activate = proc() =
      let state = vm.evaluateCommand(commandKind)
      if state.status == ecsDisabled:
        let failed = vm.runEditorCommand(commandKind)
        if failed.diagnostic.len > 0:
          r.setTextContent(diagnosticNode, failed.diagnostic)
      else:
        discard vm.runEditorCommand(commandKind)
        vm.closeCommandPalette()
    r.addEventListener(item, "click", activate)

  createRenderEffect proc() =
    let open = vm.commandPaletteOpen.val
    r.setStyle(paletteRoot, "display", if open: "flex" else: "none")
    r.setAttribute(paletteRoot, "aria-hidden", if open: "false" else: "true")
    r.clearChildren(listNode)
    if not open:
      when defined(js):
        {.emit: ["""
          (function () {
            const root = """, paletteRoot, """;
            if (!root || !root.__isonimWasOpen) return;
            root.__isonimWasOpen = false;
            const target = root.__isonimReturnFocus;
            root.__isonimReturnFocus = null;
            if (target && target.focus) {
              setTimeout(() => target.focus({ preventScroll: true }), 0);
              setTimeout(() => target.focus({ preventScroll: true }), 25);
            }
          })();
        """].}
      return
    r.setTextContent(diagnosticNode, "Use arrow keys to choose a command.")
    var index = 0
    for entry in vm.commandPaletteEntries():
      let disabled = entry.status == ecsDisabled
      let label = entry.label
      let command = entry.kind
      let section = entry.section
      let shortcut = entry.shortcut
      let status = $entry.status
      let diagnostic =
        if entry.diagnostic.len > 0: entry.diagnostic else: "Ready"
      let itemId = "isonim-command-palette-option-" & $index
      let diagnosticId = itemId & "-diagnostic"
      let item = ui(r):
        tdiv(id = itemId,
              `data-editor-command-option` = "true",
              `data-command-kind` = $command,
              `data-command-status` = status,
              `data-command-diagnostic` = diagnostic,
              role = "option", tabindex = (if index == 0: "0" else: "-1"),
              `aria-label` = label & " command, " & diagnostic,
              `aria-describedby` = diagnosticId,
              `aria-disabled` = (if disabled: "true" else: "false"),
              `aria-selected` = (if index == 0: "true" else: "false"),
              display = "grid",
              `grid-template-columns` = "minmax(0, 1fr) auto",
              gap = "10px", align_items = "center",
              padding = "8px 10px",
              border_radius = "6px",
              cursor = (if disabled: "not-allowed" else: "pointer"),
              opacity = (if disabled: "0.56" else: "1"),
              color = textPrimary,
              outline = "none"):
          tdiv(display = "flex", flex_direction = "column",
                min_width = "0", gap = "2px"):
            span(font_size = "12px", font_weight = "700",
                  overflow = "hidden", text_overflow = "ellipsis",
                  white_space = "nowrap"):
              text label
            span(font_size = "10px", color = textDim,
                  overflow = "hidden", text_overflow = "ellipsis",
                  white_space = "nowrap",
                  id = diagnosticId):
              text section & " - " & diagnostic
          span(font_size = "10px", color = textMuted,
                font_family = "monospace", white_space = "nowrap"):
            text shortcut
      bindPaletteItem(item, command)
      r.appendChild(listNode, item)
      inc index
    when defined(js):
      if open:
        {.emit: ["""
          (function () {
            const root = """, paletteRoot, """;
            const input = """, searchInput, """;
            if (root && !root.__isonimWasOpen) {
              const active = document.activeElement;
              root.__isonimReturnFocus = active && !root.contains(active) ? active : root.__isonimReturnFocus;
              root.__isonimWasOpen = true;
            }
            if (root && root.__isonimPaletteReset) root.__isonimPaletteReset();
            if (input && document.activeElement !== input) {
              setTimeout(() => input.focus({ preventScroll: true }), 0);
            }
          })();
        """].}

proc renderTelemetryOverlay[R, E](r: R; vm: EditorVM): E =
  var budgetsNode: E
  var eventsNode: E
  result = ui(r):
    tdiv(`data-editor-telemetry-overlay` = "true",
          role = "status",
          `aria-label` = "Editor performance telemetry",
          position = "fixed", right = "10px", bottom = "34px",
          z_index = "40", width = "320px",
          display = "none", flex_direction = "column", gap = "6px",
          padding = "10px",
          border = "1px solid " & borderStrong,
          border_radius = "8px",
          background_color = "rgba(15, 23, 42, 0.96)",
          color = textSecondary,
          font_size = "10px",
          box_shadow = "0 16px 48px rgba(0, 0, 0, 0.32)"):
      tdiv(display = "flex", align_items = "center",
            justify_content = "space-between", gap = "8px"):
        span(font_weight = "800", color = textPrimary,
              text_transform = "uppercase"):
          text "Telemetry"
        span(color = textDim):
          text "dev"
      tdiv(ref = budgetsNode,
            display = "grid",
            `grid-template-columns` = "1fr auto",
            gap = "3px 8px"):
        discard
      tdiv(ref = eventsNode,
            display = "flex", flex_direction = "column", gap = "2px",
            max_height = "120px", overflow_y = "auto"):
        discard

  let overlayRoot = result
  r.setStyle(overlayRoot, "pointer-events", "none")
  createRenderEffect proc() =
    let visible = vm.telemetryOverlayVisible.val
    r.setStyle(overlayRoot, "display", if visible: "flex" else: "none")
    r.setAttribute(overlayRoot, "aria-hidden", if visible: "false" else: "true")
    r.clearChildren(budgetsNode)
    for budget in vm.performanceBudgets.val:
      let budgetKind = $budget.kind
      let budgetMax = $budget.maxMs
      let budgetLabel = budget.label
      let label = ui(r):
        span(`data-performance-budget-kind` = budgetKind,
              `data-performance-budget-ms` = budgetMax,
              color = textMuted):
          text budgetLabel
      let value = ui(r):
        span(color = textSecondary, font_family = "monospace"):
          text budgetMax & "ms"
      r.appendChild(budgetsNode, label)
      r.appendChild(budgetsNode, value)

    r.clearChildren(eventsNode)
    for event in vm.telemetryEvents.val:
      let eventName = event.name
      let eventDuration = $event.durationMs
      let eventWithinBudget = event.withinBudget
      let eventDetail = event.detail
      let item = ui(r):
        tdiv(`data-editor-telemetry-event` = eventName,
              `data-editor-telemetry-detail` = eventDetail,
              display = "grid",
              `grid-template-columns` = "minmax(0, 1fr) auto",
              gap = "8px",
              color = (if eventWithinBudget: textMuted else: "#FCA5A5")):
          span(overflow = "hidden", text_overflow = "ellipsis",
                white_space = "nowrap"):
            text eventName
          span(font_family = "monospace"):
            text eventDuration & "ms"
      r.appendChild(eventsNode, item)

proc renderEditorShell*[R, E](r: R; vm: EditorVM): E =
  ## Top-level editor layout: sidebar + storyboard/preview + inspector.
  let shellRoot = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          width = "100%", height = "100%",
          font_family = "-apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif",
          font_size = "14px", background_color = bgBase,
          color = textPrimary, overflow = "hidden")
  let shell = ui(r):
    tdiv(display = "flex", flex = "1", min_height = "0",
          width = "100%", overflow = "hidden")

  let sidebarEl = renderSidebar[R, E](r, vm)
  let storyboardEl = renderStoryboardCanvas[R, E](r, vm)
  let componentDetailEl = renderComponentDetail[R, E](r, vm)
  let componentEditEl = renderComponentEditView[R, E](r, vm)
  let pagePreviewEl = renderPagePreview[R, E](r, vm)
  let foundationsEl = renderFoundationsPage[R, E](r, vm)
  let vectorEditorEl = renderVectorEditor[R, E](r, vm)
  let chatEl = renderChatPanel[R, E](r, vm) # ever-present on all views

  # Default: storyboard visible, everything else hidden
  r.setStyle(componentDetailEl, "display", "none")
  r.setStyle(componentEditEl, "display", "none")
  r.setStyle(pagePreviewEl, "display", "none")
  r.setStyle(foundationsEl, "display", "none")
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
    r.setStyle(foundationsEl, "display", if view ==
        evFoundationsPage: "flex" else: "none")
    r.setStyle(vectorEditorEl, "display", if view ==
        evVectorEditor: "flex" else: "none")
    r.setStyle(sidebarEl, "display", if panels.sidebar and view !=
        evVectorEditor: "flex" else: "none")
    let manualEditMode = view == evComponentEdit and vm.editMode.val == emEdit
    r.setStyle(chatEl, "display",
      if panels.inspector and not manualEditMode: "flex" else: "none")

  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, storyboardEl)
  r.appendChild(shell, componentDetailEl)
  r.appendChild(shell, componentEditEl)
  r.appendChild(shell, pagePreviewEl)
  r.appendChild(shell, foundationsEl)
  r.appendChild(shell, vectorEditorEl)
  r.appendChild(shell, chatEl) # always last (right side)
  r.appendChild(shellRoot, shell)
  r.appendChild(shellRoot, renderCommandPalette[R, E](r, vm))
  r.appendChild(shellRoot, renderTelemetryOverlay[R, E](r, vm))
  r.appendChild(shellRoot, renderStatusBar[R, E](r, vm))
  shellRoot
