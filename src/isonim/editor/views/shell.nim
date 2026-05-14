## IsoNim Editor — shell View (three-panel layout).
##
## Fully dogfoods IsoNim: all elements via ui macro with if/for/case.
## Only uses manual setStyle for reactive effects (createRenderEffect).

import std/[options, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/choice_row
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
  bgBase = "#0D0E14"
  bgSurface = "#1A1B26"
  bgSidebar = "#15161F"
  bgToolbar = "#16171F"
  bgEdgeStrip = "#0B0C12"
  # v4: dedicated preview-pane background, ~+4L lighter than bgSidebar so the
  # three panels (sidebar / preview / inspector) read as distinct surfaces
  # rather than one continuous dark slab. The previous bgBase value sat darker
  # than bgSidebar, which made the centre panel disappear into the sidebar.
  bgPreview* = "#1F2030"
    ## M-EVP-5: exported so the preview-canvas surface-contrast test can
    ## compare the canvas background against the surrounding pane without
    ## hardcoding the hex literal.
  bgCanvas* = "#262838"
    ## M-EVP-5: the preview canvas itself sits one luminance step
    ## lighter than `bgPreview` so the canvas reads as the visible focal
    ## area inside the preview pane rather than blending into the panel
    ## surface (or into `bgBase`, the global shell void). Exported so
    ## the surface-contrast test can refer to it without duplicating the
    ## hex.
  border* = "#2A2C3A"
    ## M-EVP-5: exported so the preview-canvas hairline-border test can
    ## refer to the canonical border token rather than hardcoding the
    ## hex; matches the M-EVP-4 export pattern for `accent`.
  borderStrong = "#363849"
  borderFaint = "#1F212C"
  textPrimary = "#ECEDF3"
  textSecondary = "#9CA0B0"
  textMuted = "#6B6F80"
  textDim = "#4A4D5C"
  accent* = "#7C7AED"
    ## M-EVP-4: exported so tests (and any sibling editor view) can refer
    ## to the indigo selection-state token without hardcoding the hex.
  accentSoft* = "#272752"
  accentHot = "#A5A4F3"

const inspectorSections = [
  isLayout, isSize, isSpacing, isPosition, isFill, isStroke, isTypography,
  isEffects, isTransitions, isFilters, isState, isSource]

const inspectorSectionNames = [
  "Layout", "Size", "Space", "Pos", "Fill", "Stroke", "Type", "FX", "Trans",
  "Filter", "State", "Source"]

const sidebarSections = [
  ssUserJourneys, ssPages, ssComponents, ssFoundations, ssGuidelines]

# M-EVP-9: canonical quick-nav category order. One icon per StoryKind
# *category type* (skPattern is folded into the Components section, so
# it doesn't get its own icon). Five icons total, matching the five
# top-level sidebar sections.
const quickNavCategories: array[5, StoryKind] = [
  skFoundation, skComponent, skPage, skFlow, skGuideline]

func quickNavLabel(kind: StoryKind): string =
  case kind
  of skFoundation: "Foundations"
  of skComponent: "Components"
  of skPattern: "Components"
  of skPage: "Pages"
  of skFlow: "User Journeys"
  of skGuideline: "Guidelines"
  of skVectorSymbol: "Foundations" # M-EVP-8: vector symbols fold into Foundations.

func quickNavIcon(kind: StoryKind): string =
  case kind
  of skFoundation: "\xE2\x97\x87"
  of skComponent: "\xE2\x97\xBB"
  of skPattern: "\xE2\x97\xA8"
  of skPage: "\xE2\x96\xA1"
  of skFlow: "\xE2\x96\xB7"
  of skGuideline: "\xE2\x97\x8B"
  of skVectorSymbol: "\xE2\x97\x87" # M-EVP-8: shares the Foundations diamond.

func quickNavSectionId(kind: StoryKind): string =
  ## Slug used in ``data-quicknav-section`` markers on the section
  ## body, so the quick-nav handler can ``scrollIntoView`` the right
  ## section.
  case kind
  of skFoundation: "foundations"
  of skComponent: "components"
  of skPattern: "components"
  of skPage: "pages"
  of skFlow: "user-journeys"
  of skGuideline: "guidelines"
  of skVectorSymbol: "foundations" # M-EVP-8: vector symbols nest inside Foundations.

func sectionToQuickNavKind(section: SidebarSection): StoryKind =
  case section
  of ssUserJourneys: skFlow
  of ssPages: skPage
  of ssComponents: skComponent
  of ssFoundations: skFoundation
  of ssGuidelines: skGuideline

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
    group.kind in {skFoundation, skVectorSymbol}
      # M-EVP-8: vector-symbol groups appear in the Foundations section.
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

proc openVectorEditorHandler*(vm: EditorVM; story: StoryRef): proc() =
  ## M-EVP-8: inline Edit affordance handler. Opens the vector editor
  ## on the supplied vector-symbol story. Defined ``*`` so the page /
  ## component preview hooks (Edit-mode double-click) can re-use it.
  let captured = story
  result = proc() = discard vm.openVectorEditor(captured)

proc closeVectorEditorHandler*(vm: EditorVM): proc() =
  ## M-EVP-8: chrome-bar back affordance handler.
  result = proc() = vm.closeVectorEditor()

proc vectorUsageNextHandler*(vm: EditorVM): proc() =
  result = proc() = vm.nextVectorUsage()

proc vectorUsagePrevHandler*(vm: EditorVM): proc() =
  result = proc() = vm.prevVectorUsage()

proc vectorUsageJumpHandler*(vm: EditorVM; index: int): proc() =
  let captured = index
  result = proc() =
    let total = vm.vectorEditorUsages.val.len
    if captured >= 0 and captured < total:
      vm.vectorEditorUsageIndex.val = captured

proc platformHandler(vm: EditorVM; platform: Platform): proc() =
  let captured = platform
  result = proc() =
    if vm.streamingPreview != nil and
        captured in vm.streamingPreview.availableBackends.val:
      selectBackend(vm.streamingPreview, captured)
    vm.changePlatform(captured)

proc viewportSelectHandler(vm: EditorVM; viewport: PreviewViewport): proc() =
  let captured = viewport
  result = proc() = vm.changeViewport(captured)

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

proc dispatchSidebarSectionScroll(sectionId: string) =
  ## M-EVP-9: ask the host page to scroll the matching sidebar section
  ## into view. Native renderers (and the headless mock) make this a
  ## no-op; only the JS target wires this through to ``scrollIntoView``.
  when defined(js):
    {.emit: ["""
      (function () {
        const toJsString = (raw) => Array.isArray(raw)
          ? String.fromCharCode.apply(null, raw)
          : String(raw || '');
        const id = toJsString(""", sectionId, """);
        if (!id) return;
        const el = document.querySelector('[data-quicknav-section="' + id + '"]');
        if (el && typeof el.scrollIntoView === 'function') {
          el.scrollIntoView({ block: 'start', behavior: 'smooth' });
        }
      })();
    """].}
  else:
    discard sectionId

proc quickNavHandler(vm: EditorVM; kind: StoryKind): proc() =
  ## M-EVP-9: click handler for a quick-nav icon. Empty categories
  ## refuse the click (the icon carries ``aria-disabled="true"`` and
  ## ``tabindex="-1"`` so the affordance is also a11y-disabled). Live
  ## categories activate, collapse siblings, and scroll into view.
  let captured = kind
  result = proc() =
    if not vm.sidebar.categoryHasStories(captured):
      return
    vm.sidebar.setActiveCategory(captured)
    dispatchSidebarSectionScroll(quickNavSectionId(captured))

proc matchesSidebarSearch(query: string; group: StoryGroup): bool =
  ## M-EVP-9: a group is visible if any of its stories matches (or if
  ## the query is empty). We DON'T treat the group description as a
  ## match — story names are the user-facing filter target per the
  ## spec ("Search input filters story names in real time"). Group
  ## name still matches because it functions as the component path.
  if query.len == 0:
    return true
  let q = query.toLowerAscii()
  if q in group.name.toLowerAscii():
    return true
  for item in group.items:
    if q in item.name.toLowerAscii():
      return true

proc matchesSidebarSearch(query: string; group: StoryGroup;
    item: StoryItem): bool =
  ## M-EVP-9: a story is visible if its name matches OR its
  ## component-path (group name) matches OR the query is empty. The
  ## group description is intentionally NOT consulted — otherwise a
  ## stray word in the description ("colors, typography, spacing")
  ## would surface every sibling item under the group as a "match".
  if query.len == 0:
    return true
  let q = query.toLowerAscii()
  if q in group.name.toLowerAscii():
    return true
  q in item.name.toLowerAscii()

proc isSelectedStory(vm: EditorVM; story: StoryRef): bool =
  let selected = vm.selectedStory.val
  selected.group == story.group and selected.name == story.name and
    selected.kind == story.kind

proc isActiveInspectorSection(vm: EditorVM; section: InspectorSection): bool =
  vm.inspector.activeSection.val == section

proc bindSidebarStoryState[R, E](r: R; node: E; vm: EditorVM;
    story: StoryRef) =
  ## M-EVP-4: sidebar row selection state. The selected row carries the
  ## indigo `accent` as a left border AND an accent-tinted background
  ## (`accentSoft`). Every row — selected or not — declares a
  ## ``border-left: <w>px solid <color>`` so the row's left edge does
  ## not shift horizontally when selection toggles. Unselected rows
  ## use ``transparent``, which renders nothing but reserves the same
  ## width.
  ##
  ## M-EVP-12 fix-cycle 1: bumped from 3 px to 4 px so the accent
  ## reads as the dominant selection cue at full-window screenshot
  ## scale; the previous 3 px stripe was easy to miss against the
  ## `accentSoft` background tint at 1920×1080.
  let captured = story
  createRenderEffect proc() =
    let isSelected = vm.isSelectedStory(captured)
    r.setAttribute(node, "aria-current", if isSelected: "true" else: "false")
    # Padding identical between states; the 4 px transparent / accent
    # border-left handles the visual indent rhythm. Vertical padding
    # mirrors the v4 polish (7 px) so the row reads at ~32 px tall.
    r.setStyle(node, "padding", "7px 12px 7px 28px")
    r.setStyle(node, "background-color",
        if isSelected: accentSoft else: "transparent")
    r.setStyle(node, "border-left-width", "4px")
    r.setStyle(node, "border-left-style", "solid")
    r.setStyle(node, "border-left-color",
        if isSelected: accent else: "transparent")

proc bindSidebarGroupFilter[R, E](r: R; node: E; vm: EditorVM;
    group: StoryGroup) =
  let captured = group
  createRenderEffect proc() =
    r.setStyle(node, "display",
      if matchesSidebarSearch(vm.sidebar.searchQuery.val, captured): "flex"
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
      if matchesSidebarSearch(vm.sidebar.searchQuery.val, capturedGroup,
          capturedItem): "flex" else: "none")

proc bindQuickNavIcon[R, E](r: R; node: E; vm: EditorVM; kind: StoryKind) =
  ## M-EVP-9: keep each quick-nav icon's enabled/active state in sync
  ## with ``vm.sidebar.groups`` (empty -> disabled) and
  ## ``vm.sidebar.activeCategory`` (active -> tinted background +
  ## ``aria-pressed="true"``).
  ##
  ## M-EVP-12 fix-cycle 1: the active state previously used
  ## ``accentSoft`` background + ``textPrimary`` text. That combo was
  ## too subtle for the v5-style screenshot review — the active icon
  ## read as "slightly tinted" rather than "selected". The fix:
  ## the active icon gets a 2 px accent border + the brighter
  ## ``accent`` color for the glyph, so it's unambiguously selected.
  ## The disabled state also drops to ``opacity: 0.4`` (was 0.45)
  ## per the brief's "≥ 40 % opacity drop" guidance.
  ##
  ## M-EVP-12 fix-cycle 2: pass-2 review still rated the active state
  ## as "is this on or off?" ambiguous — the ``accentSoft`` fill was
  ## too low-contrast against the dark sidebar. Bump the background to
  ## a saturated ``rgba(124,122,237,0.35)`` (the ``accent`` colour at
  ## 35 % alpha), keep the 2 px accent border + accent glyph colour,
  ## and add a 4 px accent dot below the icon (rendered via an inset
  ## ``box-shadow`` so we don't need to mutate child markup) as a
  ## redundant cue for unambiguous active read.
  let captured = kind
  const accentActiveBg = "rgba(124,122,237,0.35)"
    ## ``accent`` (#7C7AED) at 35 % alpha — the saturated tint that
    ## reads as "selected" against ``#0F1018`` / ``bgBase``.
  createRenderEffect proc() =
    let hasStories = vm.sidebar.categoryHasStories(captured)
    let activeOpt = vm.sidebar.activeCategory.val
    let active = activeOpt.isSome and activeOpt.get == captured
    r.setAttribute(node, "aria-disabled",
      if hasStories: "false" else: "true")
    r.setAttribute(node, "data-category-empty",
      if hasStories: "false" else: "true")
    r.setAttribute(node, "tabindex",
      if hasStories: "0" else: "-1")
    r.setAttribute(node, "aria-pressed",
      if active: "true" else: "false")
    r.setAttribute(node, "data-active",
      if active and hasStories: "true" else: "false")
    r.setStyle(node, "color",
      if not hasStories: textDim
      elif active: accent
      else: textMuted)
    r.setStyle(node, "background-color",
      if active and hasStories: accentActiveBg
      elif hasStories: "transparent"
      else: "transparent")
    r.setStyle(node, "border",
      if active and hasStories: "2px solid " & accent
      else: "2px solid transparent")
    # M-EVP-12 fix-cycle 2: redundant 4 px accent dot below the icon,
    # rendered as an inset bottom shadow so it tracks the icon's
    # border-radius without extra DOM. ``inset 0 -8px 0 -4px <accent>``
    # paints a 4 px horizontal band 4 px below the visual baseline.
    r.setStyle(node, "box-shadow",
      if active and hasStories: "0 6px 0 -4px " & accent
      else: "none")
    r.setStyle(node, "cursor",
      if hasStories: "pointer" else: "default")
    r.setStyle(node, "opacity",
      if hasStories: "1" else: "0.4")

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
    r.setStyle(node, "flex-basis", width)
    r.setStyle(node, "min-width", "240px")
    r.setStyle(node, "max-width", "420px")
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
    let mode = case vm.editMode.val
      of emView: "View"
      of emComment: "Comment"
      of emEdit: "Edit"
    # Compact status badges — show only the user-meaningful state. The
    # scope/binding/dirty/write badges are dev-only diagnostics and now
    # live behind the telemetry overlay; the status bar reads as a single
    # quiet line: "mode · selection".
    var badges: seq[string] = @[mode]
    if selected.tag.len > 0:
      badges.add selected.tag
    for i in 0 ..< badges.len:
      let badgeText = badges[i]
      let node = ui(r):
        span(white_space = "nowrap", color = textDim,
              font_size = "10px"):
          text badgeText
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
                `data-sidebar-search` = "true",
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

      # M-EVP-9: Quick-navigation strip — one icon per canonical
      # design-system category. Click an icon to focus that category
      # (activates ``SidebarVM.activeCategory``, collapses siblings,
      # scrolls the matching section into view). Empty categories are
      # marked ``aria-disabled="true"`` and refuse the click.
      #
      # M-EVP-12 fix-cycle 3 (Finding B): give the strip a clearly
      # distinct container so wide-viewport reviewers don't read it as
      # part of the sidebar tree below. Outer wrapper uses ``bgBase``
      # (a touch darker than ``bgSidebar``) with 8px horizontal margin
      # and a bottom hairline; the inner row inset adds breathing room
      # so the 5 icons read as their own toolbar above the section
      # tree.
      tdiv(padding = "8px 8px 10px 8px",
            border_bottom = "1px solid " & borderFaint):
        tdiv(`data-sidebar-quicknav` = "true",
              display = "flex", flex_direction = "row",
              align_items = "center", justify_content = "space-around",
              gap = "4px", padding = "6px 8px",
              border_radius = "6px",
              background_color = bgBase,
              border = "1px solid " & borderFaint):
          for k in quickNavCategories:
            var iconNode: E
            let cKind = k
            let cLabel = quickNavLabel(k)
            let cIcon = quickNavIcon(k)
            let cSectionId = quickNavSectionId(k)
            let onPick = quickNavHandler(vm, cKind)
            tdiv(ref = iconNode,
                  `data-category-kind` = $cKind,
                  `data-quicknav-icon` = cSectionId,
                  `role` = "button",
                  `aria-label` = "Focus " & cLabel & " category",
                  onclick = onPick,
                  onkeydown = onPick,
                  display = "flex", align_items = "center",
                  justify_content = "center",
                  width = "28px", height = "26px",
                  border_radius = "5px",
                  font_size = "13px",
                  color = textMuted,
                  transition = "background-color 0.12s, color 0.12s"):
              text cIcon
            block:
              r.bindQuickNavIcon(iconNode, vm, cKind)

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

          let qnSectionId = quickNavSectionId(sectionToQuickNavKind(section))
          tdiv(display = "flex", flex_direction = "column", gap = "2px",
                margin_bottom = "6px",
                `data-quicknav-section` = qnSectionId):
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
                span(font_size = "10px", color = textMuted,
                      opacity = "0.85"):
                  text sIcon
                span(font_size = "10px", font_weight = "600",
                      color = textMuted, text_transform = "uppercase",
                      letter_spacing = "0.9px"):
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
                    of skVectorSymbol: "\xE2\x9C\x8F" # pencil — M-EVP-8 affordance hint
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
                          gap = "6px", padding = "8px 8px 8px 18px",
                          border_radius = "4px", cursor = "pointer"):
                      span(font_size = "10px", color = textMuted,
                            flex_shrink = "0"):
                        text gIcon
                      # v4: group names are typically "App / Story" — they
                      # wrap awkwardly to two lines at laptop width. Lock
                      # the row to a single line with ellipsis so the
                      # sidebar reads as a clean list rather than a
                      # rag-right scroll.
                      span(font_size = "12px", font_weight = "500",
                            color = textPrimary,
                            letter_spacing = "0.1px",
                            white_space = "nowrap",
                            overflow = "hidden",
                            text_overflow = "ellipsis",
                            flex = "1", min_width = "0"):
                        text gName
                      span(ref = groupChevron,
                            font_size = "9px", color = textMuted,
                            margin_left = "auto",
                            flex_shrink = "0"):
                        if gShowsStories:
                          text gChevron

                    if gShowsStories:
                      tdiv(ref = groupBody,
                            display = (if gExpanded: "flex" else: "none"),
                            flex_direction = "column", gap = "1px"):
                        var itemIdx = 0
                        for item in gItems:
                          let iName = $item.name
                          let iGroup = $item.group
                          let iKind = item.kind
                          let story = StoryRef(group: iGroup, name: iName,
                                                kind: iKind, index: itemIdx)
                          let selectStory = storySelectHandler(vm, story)
                          let selected = vm.isSelectedStory(story)
                          # M-EVP-4: every story row declares the SAME left
                          # padding and the SAME 3 px left border (accent
                          # for selected, transparent for unselected), so
                          # the rhythm doesn't shift when selection toggles.
                          let storyBackground =
                            if selected: accentSoft else: "transparent"
                          let storyBorderColor =
                            if selected: accent else: "transparent"
                          let storyWeight =
                            if selected: "500" else: "400"
                          var storyNode: E
                          var storyEditBtn: E
                          let isVector = iKind == skVectorSymbol

                          tdiv(display = "flex", flex_direction = "row",
                                align_items = "center",
                                ref = storyNode,
                                `role` = "button", tabindex = "0",
                                `aria-label` = "Select story " & iGroup &
                                  " / " & iName,
                                `data-story-row` = iGroup & "/" & iName,
                                `aria-current` = (
                                    if selected: "true" else: "false"),
                                onclick = selectStory,
                                onkeydown = selectStory,
                                padding = "7px 12px 7px 28px",
                                border_radius = "4px", cursor = "pointer",
                                transition = "background-color 0.1s, border-left-color 0.1s",
                                background_color = storyBackground,
                                border_left_width = "3px",
                                border_left_style = "solid",
                                border_left_color = storyBorderColor):
                            span(font_size = "12px", line_height = "1.4",
                                  flex = "1", min_width = "0",
                                  overflow = "hidden",
                                  text_overflow = "ellipsis",
                                  white_space = "nowrap",
                                  color = (
                                      if selected: textPrimary
                                      else: textSecondary),
                                  font_weight = storyWeight):
                              text iName
                            # M-EVP-8: vector-symbol rows expose an inline
                            # "Edit" affordance that opens the vector editor
                            # for the symbol. The button stops click
                            # propagation so the surrounding row's click
                            # handler (which would route to the default
                            # ``viewForStory`` view) does not also fire.
                            if isVector:
                              tdiv(ref = storyEditBtn,
                                    `data-vector-edit` = "true",
                                    `data-vector-edit-target` =
                                      iGroup & "/" & iName,
                                    `role` = "button", tabindex = "0",
                                    `aria-label` =
                                      "Edit vector symbol " & iName,
                                    margin_left = "8px",
                                    flex_shrink = "0",
                                    padding = "2px 6px",
                                    border_radius = "3px",
                                    font_size = "10px",
                                    color = textSecondary,
                                    background_color = bgSurface,
                                    border = "1px solid " & border,
                                    cursor = "pointer"):
                                text "Edit"
                          block:
                            r.bindSidebarStoryState(storyNode, vm, story)
                            r.bindSidebarItemFilter(storyNode, vm, group, item)
                            if isVector:
                              let openVec = openVectorEditorHandler(vm, story)
                              r.addEventListener(storyEditBtn, "click", openVec)
                              r.addEventListener(storyEditBtn, "keydown", openVec)
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

proc bindBackendChip[R, E](r: R; chip: E; vm: EditorVM;
    backend: PreviewBackend) =
  ## Rewire the backend chip's reactive bits (aria-pressed, accent
  ## fill, font weight, text colour) to track `vm.platform`. Called
  ## from `renderPreviewLeftEdge` once per visible chip so the active
  ## chip flips without rebuilding the strip.
  ##
  ## Also installs a click / keydown listener that dispatches the
  ## backend change *every* time, regardless of the snapshot-time
  ## enabled flag the choice-row macro baked into its own
  ## `compactChoiceHandler` capture. Reason: the chip's enabled flag
  ## depends on `vm.streamingPreview.availableBackends`, which may
  ## itself flip after construction; the choice-row's captured handler
  ## would otherwise refuse the click for ever. The platform handler
  ## already checks availability internally before forwarding to
  ## `selectBackend`.
  let captured = backend
  createRenderEffect proc() =
    let selected = vm.platform.val == captured
    let available =
      if vm.streamingPreview != nil:
        vm.streamingPreview.backendIsAvailable(captured)
      else:
        true
    r.setAttribute(chip, "aria-pressed", if selected: "true" else: "false")
    r.setStyle(chip, "background-color",
      if selected: accent
      elif available: bgSurface
      else: "transparent")
    r.setStyle(chip, "color",
      if selected: "#FFFFFF"
      elif available: textSecondary
      else: textDim)
    r.setStyle(chip, "font-weight", if selected: "700" else: "600")
    r.setStyle(chip, "box-shadow",
      if selected: "0 3px 12px rgba(124,122,237,0.55), inset 0 0 0 1px " & accentHot
      else: "none")
    r.setAttribute(chip, "data-preview-backend-available",
      if available: "true" else: "false")
    r.setAttribute(chip, "aria-disabled",
      if available: "false" else: "true")
    r.setAttribute(chip, "data-compact-choice-enabled",
      if available: "true" else: "false")
    r.setAttribute(chip, "tabindex",
      if available: "0" else: "-1")
  let liveHandler = platformHandler(vm, captured)
  let availabilityCheck = proc() =
    let okNow =
      if vm.streamingPreview != nil:
        vm.streamingPreview.backendIsAvailable(captured)
      else:
        true
    if okNow:
      liveHandler()
  r.addEventListener(chip, "click", availabilityCheck)
  r.addEventListener(chip, "keydown", availabilityCheck)

proc bindViewportChip[R, E](r: R; chip: E; vm: EditorVM;
    viewport: PreviewViewport) =
  ## Rewire the viewport chip's reactive bits to track `vm.viewport`.
  ## Also installs a live click listener so the chip dispatches the
  ## viewport change regardless of any stale `enabled` capture inside
  ## the choice-row's compactChoiceHandler.
  let captured = viewport
  createRenderEffect proc() =
    let selected = viewportsEqual(vm.viewport.val, captured)
    r.setAttribute(chip, "aria-pressed", if selected: "true" else: "false")
    r.setStyle(chip, "background-color",
      if selected: accentSoft else: "transparent")
    r.setStyle(chip, "color",
      if selected: textPrimary else: textMuted)
    r.setStyle(chip, "font-weight", if selected: "600" else: "500")
    r.setStyle(chip, "box-shadow",
      if selected: "inset 0 0 0 1px " & accent else: "none")
  let liveHandler = viewportSelectHandler(vm, captured)
  r.addEventListener(chip, "click", liveHandler)
  r.addEventListener(chip, "keydown", liveHandler)

proc bindModeChip[R, E](r: R; chip: E; vm: EditorVM;
    mode: EditMode) =
  ## Rewire the mode chip's reactive bits to track `vm.editMode` and
  ## the per-mode command-enabled state.
  ##
  ## Like `bindBackendChip`, this also installs a live event listener
  ## so the chip's onClick path bypasses the snapshot-time `enabled`
  ## capture that the choice-row's compactChoiceHandler bakes in. The
  ## per-mode command (eckInspect / eckComment / eckEdit) is gated by
  ## `vm.runEditorCommand` itself, which re-evaluates the requirement
  ## on every invocation; deferring to the VM avoids the stale-capture
  ## class of bug that motivated this fix.
  let captured = mode
  let command = case mode
    of emView: eckInspect
    of emComment: eckComment
    of emEdit: eckEdit
  let capturedCommand = command
  createRenderEffect proc() =
    let selected = vm.editMode.val == captured
    let state = vm.evaluateCommand(capturedCommand)
    let enabled = state.status != ecsDisabled
    r.setAttribute(chip, "aria-pressed", if selected: "true" else: "false")
    r.setStyle(chip, "background-color",
      if selected: accent
      elif enabled: bgSurface
      else: "transparent")
    r.setStyle(chip, "color",
      if selected: "#FFFFFF"
      elif enabled: textSecondary
      else: textDim)
    r.setStyle(chip, "font-weight", if selected: "700" else: "600")
    r.setStyle(chip, "box-shadow",
      if selected: "0 3px 12px rgba(124,122,237,0.55), inset 0 0 0 1px " & accentHot
      else: "none")
    r.setAttribute(chip, "data-preview-mode-disabled",
      if enabled: "false" else: "true")
    r.setAttribute(chip, "aria-disabled",
      if enabled: "false" else: "true")
    r.setAttribute(chip, "data-compact-choice-enabled",
      if enabled: "true" else: "false")
    r.setAttribute(chip, "tabindex",
      if enabled: "0" else: "-1")
  let liveHandler = editModeHandler(vm, captured)
  r.addEventListener(chip, "click", liveHandler)
  r.addEventListener(chip, "keydown", liveHandler)

proc backendsForLeftEdge(): array[6, PreviewBackend] =
  [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]

proc backendShortLabelsForLeftEdge(): array[6, string] =
  ["Web", "TUI", "GPUI", "Freya", "Cocoa", "Droid"]

proc buildBackendOptions(vm: EditorVM): seq[CompactChoiceOption] =
  ## M58: the backend strip's option list is now produced by a thunk so
  ## the column's `createRenderEffect` re-runs and diffs the chip set
  ## whenever `vm.platform` or `vm.streamingPreview.availableBackends`
  ## change. Today the backend ENUM list is fixed; the availability flag
  ## is what flips per option, but routing it through the thunk gives
  ## the column a single reactive idiom shared with the viewport strip.
  result = @[]
  let backends = backendsForLeftEdge()
  let backendShortLabels = backendShortLabelsForLeftEdge()
  let active = vm.platform.val
  for i in 0 ..< backends.len:
    let b = backends[i]
    let available =
      if vm.streamingPreview != nil:
        vm.streamingPreview.backendIsAvailable(b)
      else:
        true
    let captured = b
    result.add CompactChoiceOption(
      label: backendLabel(b),
      shortLabel: backendShortLabels[i],
      ariaLabel: "Preview backend " & backendLabel(b),
      selected: active == b,
      enabled: available,
      dataAttrs: @[
        ("data-preview-backend", backendId(b)),
        ("data-preview-backend-available",
          if available: "true" else: "false")],
      onChoose: platformHandler(vm, captured))

proc buildViewportOptions(vm: EditorVM): seq[CompactChoiceOption] =
  ## M58 thunk producing the viewport strip's option list. Reading
  ## `vm.platform.val` here registers the column's rebuild effect with
  ## the platform signal so switching backend flips the pinned chip
  ## set in place.
  result = @[]
  let backend = vm.platform.val
  let pinnedForBackend = pinnedViewports(backend)
  let popupForBackend = popupViewports(backend)
  let activeViewport = vm.viewport.val
  for vp in pinnedForBackend:
    let captured = vp
    result.add CompactChoiceOption(
      label: vp.label,
      shortLabel: vp.label,
      ariaLabel: "Preview viewport " & vp.label,
      selected: viewportsEqual(activeViewport, vp),
      enabled: true,
      dataAttrs: @[
        ("data-preview-viewport", vp.slug),
        ("data-preview-viewport-pinned", "true")],
      onChoose: viewportSelectHandler(vm, captured))
  for vp in popupForBackend:
    let captured = vp
    result.add CompactChoiceOption(
      label: vp.label,
      shortLabel: vp.label,
      ariaLabel: "Preview viewport " & vp.label,
      selected: viewportsEqual(activeViewport, vp),
      enabled: true,
      dataAttrs: @[
        ("data-preview-viewport", vp.slug),
        ("data-preview-viewport-pinned", "false")],
      onChoose: viewportSelectHandler(vm, captured))

proc viewportFromChipOption(option: CompactChoiceOption): PreviewViewport =
  ## Recover the `PreviewViewport` enum value from a chip's data
  ## attributes; the M58 thunk path needs this because
  ## `onChipMounted` only sees the option, not the original viewport
  ## list.
  for (key, value) in option.dataAttrs:
    if key == "data-preview-viewport":
      return builtinViewportFromSlug(value)
  result = builtinViewportFromSlug("desktop")

proc modeFromChipOption(option: CompactChoiceOption): EditMode =
  for (key, value) in option.dataAttrs:
    if key == "data-preview-mode":
      case value
      of "view": return emView
      of "comment": return emComment
      of "edit": return emEdit
      else: discard
  result = emView

proc renderPreviewLeftEdge*[R, E](r: R; vm: EditorVM): E =
  ## Legacy left-edge column. The backend / viewport chip groups moved
  ## into the preview-pane's top toolbar (see `renderPreviewPane`); this
  ## proc is preserved only to keep its public symbol stable for code
  ## that still imports it directly. Returns a hidden stub.
  result = ui(r):
    tdiv(display = "none",
          `data-preview-left-edge-legacy` = "true")

proc buildModeOptions(vm: EditorVM): seq[CompactChoiceOption] =
  ## M58 thunk for the mode-strip option list. The set is statically
  ## three entries — the migration to the thunk pattern is for idiom
  ## uniformity with the left-edge strips (per the M58 spec).
  const modes = [emView, emComment, emEdit]
  const modeLabels = ["View", "Comment", "Edit"]
  # Short labels mirror the full labels — the v3 widened right edge has
  # room for "Comment" without truncating, so we no longer fall back to
  # the cramped "Cmt" abbreviation that v2 used.
  const modeShorts = ["View", "Comment", "Edit"]
  let activeMode = vm.editMode.val
  for i in 0 ..< modes.len:
    let mode = modes[i]
    let captured = mode
    let command = case mode
      of emView: eckInspect
      of emComment: eckComment
      of emEdit: eckEdit
    let state = vm.evaluateCommand(command)
    result.add CompactChoiceOption(
      label: modeLabels[i],
      shortLabel: modeShorts[i],
      ariaLabel: "Preview mode " & modeLabels[i],
      selected: activeMode == mode,
      enabled: state.status != ecsDisabled,
      dataAttrs: @[
        ("data-preview-mode", modeLabels[i].toLowerAscii()),
        ("data-preview-mode-disabled",
          if state.status == ecsDisabled: "true" else: "false")],
      onChoose: editModeHandler(vm, captured))

proc renderPreviewRightEdge*[R, E](r: R; vm: EditorVM): E =
  ## Legacy right-edge column. The mode chip group moved into the
  ## preview-pane's top toolbar (see `renderPreviewPane`); this proc is
  ## preserved only to keep its public symbol stable. Returns a hidden
  ## stub.
  result = ui(r):
    tdiv(display = "none",
          `data-preview-right-edge-legacy` = "true")

proc renderPreviewPane*[R, E](r: R; vm: EditorVM): E =
  ## Center panel: component preview with consolidated top-toolbar
  ## chrome. The legacy M57 left/right edge strips are gone — backend,
  ## viewport, and mode chip groups all live in the preview-pane's top
  ## toolbar alongside the view switcher. The streaming-preview VM,
  ## when present on `vm.streamingPreview`, drives backend availability
  ## and selection.
  let pane = ui(r):
    tdiv(class = "editor-preview",
          display = "flex", flex_direction = "column",
          flex = "1", min_width = "0", height = "100%",
          background_color = bgPreview)

  # --- Top toolbar (backend / viewport / mode chips) ---------------------
  # M-EVP-7: the view-switcher chip group is gone; the sidebar drives
  # the active view via ``selectStory`` + ``viewForStory``. Wraps to two
  # rows on narrow viewports so the three groups stay readable at
  # 1440x900 without horizontal scroll.
  let toolbar = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "flex-start",
          gap = "10px", flex_wrap = "wrap",
          row_gap = "6px",
          min_height = "44px", padding = "8px 14px",
          background_color = bgToolbar,
          border_bottom = "1px solid " & border,
          `data-preview-toolbar` = "true")

  # --- Backend / Viewport / Mode chip groups (was: left + right edge) -----
  # All three chip groups now live in the top toolbar so the preview pane
  # sits edge-to-edge without vertical chrome columns. Each group is
  # rendered as a horizontal compact-choice row reusing the thunk-driven
  # M58 reactive pipeline; the column variants previously used for the
  # M57 edge strips are gone.
  let capturedVm = vm

  # Reuse `renderCompactChoiceColumn` (which already has the M58
  # reactive chip-set rebuild logic) and override its CSS to flow
  # horizontally. This keeps M58's per-backend viewport pinned-set
  # reactivity intact without duplicating the rebuild machinery.
  proc tiltHorizontal(root: E; ariaLabel: string) =
    r.setStyle(root, "flex-direction", "row")
    r.setStyle(root, "width", "auto")
    r.setStyle(root, "min-width", "0")
    r.setAttribute(root, "aria-orientation", "horizontal")

  let backendThunk = proc(): seq[CompactChoiceOption] =
    buildBackendOptions(capturedVm)
  let backendOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    var backendId = ""
    for (key, value) in option.dataAttrs:
      if key == "data-preview-backend":
        backendId = value
        break
    let b = backendFromId(backendId)
    r.bindBackendChip(node, capturedVm, b)
  let backendCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview backend",
    optionsThunk = backendThunk,
    visibleLimit = 6,
    chipWidth = "44px",
    chipHeight = "26px",
    dataAttrs = @[
      ("data-edge-strip", "backend"),
      ("data-preview-edge-group", "backend")],
    onChipMounted = backendOnChipMounted)
  tiltHorizontal(backendCol.root, "Preview backend")
  r.appendChild(toolbar, backendCol.root)

  let viewportThunk = proc(): seq[CompactChoiceOption] =
    buildViewportOptions(capturedVm)
  let viewportVisibleLimitThunk = proc(): int =
    pinnedViewports(capturedVm.platform.val).len
  let viewportOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    let vp = viewportFromChipOption(option)
    r.bindViewportChip(node, capturedVm, vp)
  let viewportCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview screen size",
    optionsThunk = viewportThunk,
    visibleLimitThunk = viewportVisibleLimitThunk,
    chipWidth = "44px",
    chipHeight = "24px",
    dataAttrs = @[
      ("data-edge-strip", "viewport"),
      ("data-preview-edge-group", "viewport")],
    onChipMounted = viewportOnChipMounted)
  tiltHorizontal(viewportCol.root, "Preview screen size")
  r.appendChild(toolbar, viewportCol.root)

  let modeThunk = proc(): seq[CompactChoiceOption] =
    buildModeOptions(capturedVm)
  let modeOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    let mode = modeFromChipOption(option)
    r.bindModeChip(node, capturedVm, mode)
  let modeCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview mode",
    optionsThunk = modeThunk,
    visibleLimit = 3,
    chipWidth = "60px",
    chipHeight = "26px",
    dataAttrs = @[
      ("data-edge-strip", "mode"),
      ("data-preview-edge-group", "mode")],
    onChipMounted = modeOnChipMounted)
  tiltHorizontal(modeCol.root, "Preview mode")
  r.appendChild(toolbar, modeCol.root)

  r.appendChild(pane, toolbar)

  # --- Body row: preview canvas only (edge strips removed) ----------------
  let body = ui(r):
    tdiv(flex = "1", display = "flex", flex_direction = "row",
          min_width = "0", min_height = "0",
          align_items = "stretch",
          `data-preview-body` = "true")

  # Preview canvas — fully inline (preserves the existing affordance).
  # Empty state: a quiet branded landing card centered on the canvas.
  # M-EVP-5: the canvas itself sits one luminance step lighter than
  # the surrounding pane (`bgPreview`) AND carries a 1 px hairline
  # border, so it reads as the visible focal area inside the pane
  # rather than blending into the panel surface. Both acceptance
  # conditions hold individually; doing both yields the unambiguous
  # "canvas surface" affordance reviewers asked for.
  let previewArea = ui(r):
    tdiv(flex = "1", display = "flex",
          align_items = "center", justify_content = "center",
          background_color = bgCanvas, position = "relative",
          min_width = "0",
          border = "1px solid " & border,
          background_image = "radial-gradient(circle at center, " &
            borderFaint & " 1px, transparent 1.5px)",
          background_size = "28px 28px",
          `data-preview-canvas` = "true"):
      tdiv(display = "flex", flex_direction = "column",
            align_items = "stretch", gap = "20px",
            padding = "40px", max_width = "520px", width = "100%",
            background_color = bgSurface,
            border = "1px solid " & border,
            border_radius = "14px",
            box_shadow = "0 24px 80px rgba(0,0,0,0.32)"):
        tdiv(display = "flex", flex_direction = "column", gap = "6px"):
          span(font_size = "11px", font_weight = "600",
                color = accentHot, text_transform = "uppercase",
                letter_spacing = "0.12em"):
            text "IsoNim Examples"
          span(font_size = "20px", font_weight = "600",
                color = textPrimary, letter_spacing = "-0.01em"):
            text "Pick a story to start exploring"
          span(font_size = "13px", color = textSecondary,
                line_height = "1.5"):
            text "Six renderers wrap the same view-model. Choose " &
              "Task App or Settings App from the sidebar to load a " &
              "live demo into the preview canvas."
        tdiv(display = "flex", flex_direction = "column", gap = "10px"):
          for hint in [
            ("Switch renderers", "Use the left-edge strip"),
            ("Resize the preview", "Viewport chips under the strip"),
            ("View · Comment · Edit", "Right-edge mode toggle")]:
            let title = hint[0]
            let detail = hint[1]
            tdiv(display = "flex", align_items = "center", gap = "12px",
                  padding = "10px 14px",
                  background_color = bgBase,
                  border = "1px solid " & border,
                  border_radius = "8px"):
              tdiv(width = "8px", height = "8px",
                    border_radius = "999px",
                    background_color = accent,
                    flex_shrink = "0")
              tdiv(display = "flex", flex_direction = "column",
                    flex = "1", gap = "2px"):
                span(font_size = "13px", font_weight = "500",
                      color = textPrimary):
                  text title
                span(font_size = "11px", color = textMuted):
                  text detail
  r.appendChild(body, previewArea)

  r.appendChild(pane, body)

  pane

proc renderInspectorPanel*[R, E](r: R; vm: EditorVM): E =
  ## Right panel: property inspector + agent chat.
  ## Fully inline except for tab active-state styling.
  result = ui(r):
    tdiv(class = "editor-inspector",
          display = "flex", flex_direction = "column",
          width = "280px", min_width = "240px", max_width = "420px",
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
            height = "160px", min_height = "160px",
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

proc renderEditorTitleBar[R, E](r: R; vm: EditorVM): E =
  ## Slim header bar above the shell row. Carries the product name (and
  ## the currently-loaded project) so the editor reads as a real tool
  ## rather than a frameless canvas. The header sits above the M57 edge
  ## strips and the sidebar.
  result = ui(r):
    tdiv(display = "flex", align_items = "center",
          gap = "12px",
          height = "36px", min_height = "36px",
          padding = "0 14px",
          background_color = bgSidebar,
          border_bottom = "1px solid " & border):
      tdiv(display = "flex", align_items = "center", gap = "8px"):
        tdiv(width = "20px", height = "20px",
              border_radius = "6px",
              background_image = "linear-gradient(135deg, #7C7AED, #A5A4F3)",
              box_shadow = "0 1px 4px rgba(124,122,237,0.4)")
        span(font_size = "13px", font_weight = "600",
              color = textPrimary, letter_spacing = "-0.005em"):
          text editorProductName
        span(font_size = "11px", color = textMuted):
          text "IsoNim Examples"
      tdiv(flex = "1")
      span(font_size = "11px", color = textDim, font_family = "monospace"):
        text "v" & editorVersion

proc renderPreviewChromeBar*[R, E](r: R; vm: EditorVM): E =
  ## Shared preview-pane top toolbar that sits above every view in the
  ## center column. Carries the three reactive chip groups
  ## (Backend / Viewport / Mode). Mounted once per shell and shared
  ## across the storyboard, component detail, component edit, page
  ## preview, foundations, and vector views — so clicking a backend
  ## chip always works no matter which view is active.
  ##
  ## M-EVP-7: the view-switcher chip group (Flow / Detail / Page /
  ## Foundations / Vector) was removed because the sidebar is now the
  ## sole navigation surface. ``selectStory`` derives the active view
  ## from the selected story's ``StoryKind`` via ``viewForStory``, so a
  ## dedicated chrome-bar tab strip would duplicate the sidebar's role.
  ##
  ## Replaces the M57 left/right edge strips and the per-view
  ## breadcrumb / "Edit | Code" toolbars. Wraps to a second row on
  ## narrow viewports so the three groups stay readable at 1440x900.
  # M-EVP-3: explicit `gap = "14px"` (centred in the spec's 12-16 px
  # band) gives every adjacent chip cluster a clearly-visible breathing
  # gap; `padding-right = "12px"` keeps the rightmost (mode) cluster
  # from sitting flush against the inspector edge. Padding is declared
  # via the four `padding-{top,right,bottom,left}` properties (not the
  # shorthand) so the headless layout test can assert `padding-right`
  # directly from `node.styles`.
  let toolbar = ui(r):
    tdiv(display = "flex", align_items = "center",
          justify_content = "flex-start",
          gap = "14px", flex_wrap = "wrap",
          row_gap = "6px",
          min_height = "44px",
          padding_top = "8px", padding_right = "12px",
          padding_bottom = "8px", padding_left = "16px",
          background_color = bgToolbar,
          border_bottom = "1px solid " & border,
          `data-preview-toolbar` = "true",
          `data-preview-chrome-bar` = "true")

  let capturedVm = vm

  # Reuse `renderCompactChoiceColumn` (which already has the M58
  # reactive chip-set rebuild logic) and override its CSS to flow
  # horizontally. This keeps M58's per-backend viewport pinned-set
  # reactivity intact without duplicating the rebuild machinery.
  proc tiltHorizontal(root: E; ariaLabel: string) =
    r.setStyle(root, "flex-direction", "row")
    r.setStyle(root, "width", "auto")
    r.setStyle(root, "min-width", "0")
    r.setAttribute(root, "aria-orientation", "horizontal")

  let backendThunk = proc(): seq[CompactChoiceOption] =
    buildBackendOptions(capturedVm)
  let backendOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    var backendId = ""
    for (key, value) in option.dataAttrs:
      if key == "data-preview-backend":
        backendId = value
        break
    let b = backendFromId(backendId)
    r.bindBackendChip(node, capturedVm, b)
  let backendCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview backend",
    optionsThunk = backendThunk,
    visibleLimit = 6,
    chipWidth = "44px",
    chipHeight = "26px",
    dataAttrs = @[
      ("data-edge-strip", "backend"),
      ("data-preview-edge-group", "backend"),
      ("data-toolbar-cluster", "backend")],
    onChipMounted = backendOnChipMounted)
  tiltHorizontal(backendCol.root, "Preview backend")
  r.appendChild(toolbar, backendCol.root)

  let viewportThunk = proc(): seq[CompactChoiceOption] =
    buildViewportOptions(capturedVm)
  let viewportVisibleLimitThunk = proc(): int =
    pinnedViewports(capturedVm.platform.val).len
  let viewportOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    let vp = viewportFromChipOption(option)
    r.bindViewportChip(node, capturedVm, vp)
  let viewportCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview screen size",
    optionsThunk = viewportThunk,
    visibleLimitThunk = viewportVisibleLimitThunk,
    chipWidth = "44px",
    chipHeight = "24px",
    dataAttrs = @[
      ("data-edge-strip", "viewport"),
      ("data-preview-edge-group", "viewport"),
      ("data-toolbar-cluster", "viewport")],
    onChipMounted = viewportOnChipMounted)
  tiltHorizontal(viewportCol.root, "Preview screen size")
  r.appendChild(toolbar, viewportCol.root)

  let modeThunk = proc(): seq[CompactChoiceOption] =
    buildModeOptions(capturedVm)
  let modeOnChipMounted = proc(node: E; option: CompactChoiceOption;
      index: int) =
    let mode = modeFromChipOption(option)
    r.bindModeChip(node, capturedVm, mode)
  let modeCol = renderCompactChoiceColumn[R, E](r,
    ariaLabel = "Preview mode",
    optionsThunk = modeThunk,
    visibleLimit = 3,
    chipWidth = "60px",
    chipHeight = "26px",
    dataAttrs = @[
      ("data-edge-strip", "mode"),
      ("data-preview-edge-group", "mode"),
      ("data-toolbar-cluster", "mode")],
    onChipMounted = modeOnChipMounted)
  tiltHorizontal(modeCol.root, "Preview mode")
  r.appendChild(toolbar, modeCol.root)

  toolbar

proc renderEditorShell*[R, E](r: R; vm: EditorVM): E =
  ## Top-level editor layout: [sidebar | center column | inspector chat] +
  ## status bar. The global title bar and the M57 left/right edge strips
  ## are gone — backend / viewport / mode chips now live in the shared
  ## preview chrome bar at the top of the center column
  ## (`renderPreviewChromeBar`). The shell row sits edge-to-edge at the
  ## top of the viewport.
  let shellRoot = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          width = "100%", height = "100%",
          font_family = "-apple-system, BlinkMacSystemFont, 'Inter', 'Segoe UI', system-ui, sans-serif",
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

  # Center column wraps the shared preview chrome bar + the view stack
  # so the toolbar sits above every view. Replaces the previous
  # per-view top toolbars + the legacy global title bar.
  let chromeBarEl = renderPreviewChromeBar[R, E](r, vm)
  let centerColumn = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          flex = "1", min_width = "0", min_height = "0",
          `data-preview-center-column` = "true")
  let viewStack = ui(r):
    tdiv(display = "flex", flex = "1", min_width = "0", min_height = "0",
          flex_direction = "column",
          `data-preview-view-stack` = "true")

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
    # Vector editor takes over the whole center column; hide the
    # shared chrome bar so the vector-editor toolbar isn't doubled up.
    r.setStyle(chromeBarEl, "display",
      if view == evVectorEditor: "none" else: "flex")
    let manualEditMode = view == evComponentEdit and vm.editMode.val == emEdit
    r.setStyle(chatEl, "display",
      if panels.inspector and not manualEditMode: "flex" else: "none")

  r.appendChild(viewStack, storyboardEl)
  r.appendChild(viewStack, componentDetailEl)
  r.appendChild(viewStack, componentEditEl)
  r.appendChild(viewStack, pagePreviewEl)
  r.appendChild(viewStack, foundationsEl)
  r.appendChild(viewStack, vectorEditorEl)
  r.appendChild(centerColumn, chromeBarEl)
  r.appendChild(centerColumn, viewStack)

  # Mount order is the on-screen order (flex row, left to right):
  #   [sidebar | center column (chrome bar + view stack) | inspector chat]
  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, centerColumn)
  r.appendChild(shell, chatEl) # inspector / AI chat
  r.appendChild(shellRoot, shell)
  r.appendChild(shellRoot, renderCommandPalette[R, E](r, vm))
  r.appendChild(shellRoot, renderTelemetryOverlay[R, E](r, vm))
  r.appendChild(shellRoot, renderStatusBar[R, E](r, vm))

  # M-EVP-8: ESC closes the vector editor and routes back to the prior
  # view. We add a single keyboard-event entry-point inside the shell
  # tagged with ``data-shell-escape-key="true"`` that listens for the
  # ``keydown`` event. JS wires ``document.keydown`` (filtered on
  # ``event.key === "Escape"``) to ``fireEvent("keydown")`` on this
  # node, so the same no-arg handler closes the vector editor whether
  # the trigger comes from a real keystroke (production) or a
  # ``node.fireEvent("keydown")`` call (headless tests).
  let escKeyNode = ui(r):
    tdiv(`data-shell-escape-key` = "true",
          position = "absolute", width = "0", height = "0",
          overflow = "hidden", `aria-hidden` = "true")
  r.appendChild(shellRoot, escKeyNode)
  r.addEventListener(escKeyNode, "keydown", proc() =
    if vm.activeView.val == evVectorEditor:
      vm.closeVectorEditor())
  when defined(js):
    {.emit: ["""
      (function () {
        const node = """, escKeyNode, """;
        if (!node || node.__isonimEscBound) return;
        node.__isonimEscBound = true;
        document.addEventListener('keydown', function (event) {
          if (event.key !== 'Escape') return;
          const ev = new Event('keydown', { bubbles: false });
          node.dispatchEvent(ev);
        });
      })();
    """].}

  shellRoot
