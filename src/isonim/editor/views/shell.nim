## IsoNim Editor — shell View (three-panel layout).
##
## Fully dogfoods IsoNim: all elements via ui macro with if/for/case.
## Only uses manual setStyle for reactive effects (createRenderEffect).

import std/[options, sets, strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/viewmodel  # AsyncState (asIdle/asLoading/asReady/asError)
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
import isonim/editor/views/icons
import isonim/editor/views/design_review_mount as design_review_mount_view
import isonim/editor/views/widgets as editor_widgets
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/brief_index_static
import isonim/editor/design_review/editor_http_client as editor_http_client
import isonim/editor/views/spec_pane as spec_pane_view
import isonim/editor/views/spec_comment_popover as spec_comment_popover_view
import isonim/editor/views/spec_comment_chat as spec_comment_chat_view

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

func inspectorSectionAttr*(section: InspectorSection): string =
  ## ``data-inspector-section`` value for an ``InspectorSection`` enum
  ## entry. The 12 legacy slugs (``layout``, ``size``, ``spacing``, …)
  ## match ``sectionFullTitle`` in ``component_edit.nim`` lower-cased.
  ## Phase C (2026-05-28) extends the mapping with the four section-
  ## catalogue additions (Appearance, Selection colors,
  ## Component properties, Export) so the section frame click handlers
  ## can resolve their owning ``InspectorSection`` value cheaply.
  case section
  of isLayout: "layout"
  of isSize: "size"
  of isSpacing: "spacing"
  of isPosition: "position"
  of isFill: "fill"
  of isStroke: "stroke"
  of isTypography: "typography"
  of isEffects: "effects"
  of isTransitions: "transitions"
  of isFilters: "filters"
  of isState: "state"
  of isSource: "source"
  of isAppearance: "appearance"
  of isSelectionColors: "selection-colors"
  of isComponentProps: "component-properties"
  of isExport: "export"

func inspectorSectionFromAttr*(slug: string): InspectorSection =
  ## Inverse of ``inspectorSectionAttr``. Returns ``isLayout`` for
  ## unknown slugs so the caller can decide whether to no-op. Tests
  ## should pin the round-trip property.
  case slug
  of "layout": isLayout
  of "size": isSize
  of "spacing": isSpacing
  of "position": isPosition
  of "fill": isFill
  of "stroke": isStroke
  of "typography": isTypography
  of "effects": isEffects
  of "transitions": isTransitions
  of "filters": isFilters
  of "state": isState
  of "source": isSource
  of "appearance": isAppearance
  of "selection-colors": isSelectionColors
  of "component-properties": isComponentProps
  of "export": isExport
  else: isLayout

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

func quickNavShortLabel(kind: StoryKind): string =
  ## M-EVP-14 Wave B: tight caption shown directly under each quick-nav
  ## glyph. The 260 px sidebar splits five icons across ~216 px usable
  ## width, so the visible caption needs to fit ~40 px per cell without
  ## ellipsis. The full label survives in the HTML `title` tooltip and
  ## the `aria-label` for accessibility.
  case kind
  of skFoundation: "Found"
  of skComponent: "Comps"
  of skPattern: "Comps"
  of skPage: "Pages"
  of skFlow: "Flows"
  of skGuideline: "Guide"
  of skVectorSymbol: "Found"

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
  ## 2026-05-28 icon-coverage expansion: the status-bar sidebar toggles
  ## now render an inline SVG icon instead of a Unicode arrow glyph.
  ## The ``glyph`` parameter is repurposed to hold the SVG markup —
  ## the call sites pass ``currentIconSet().sidebarLeft`` /
  ## ``sidebarRight``. The button size grows from 24x22 to 26x26 so the
  ## SVG icon has room to read at the status-bar density (the previous
  ## arrow glyph was a single text character; the SVG is rendered as
  ## an 18x18 host inside the button chrome to match the sidebar tab
  ## bar's icon size).
  var iconHost: E
  result = ui(r):
    tdiv(width = "26px", height = "26px", border_radius = "4px",
          display = "flex", align_items = "center", justify_content = "center",
          cursor = "pointer", transition = "all 0.12s",
          flex_shrink = "0"):
      tdiv(ref = iconHost,
            `aria-hidden` = "true",
            display = "flex", align_items = "center",
            justify_content = "center",
            width = "18px", height = "18px",
            line_height = "1",
            flex_shrink = "0")
  r.setInnerHtml(iconHost, glyph)
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
  # M-EVP-14 Wave Chrome CR-4: suppress trailing path segments that
  # duplicate the active story name (or its containing group path).
  # The page-preview root element commonly tags as the same word as the
  # story leaf (e.g. story name "Inbox" + element tag "Inbox"), which
  # produced visibly redundant breadcrumb tails like
  # "Task App / Pages / Inbox / Inbox". Trim consecutive duplicates
  # from the right so the breadcrumb reads as the story path without
  # the redundant echo.
  while result.len >= 2 and result[^1] == result[^2]:
    result.setLen(result.len - 1)
  # Also drop the trailing element label if it equals the active story
  # name — same redundancy class, but the duplicated segment may not be
  # strictly adjacent if the breadcrumb interleaves the group / name
  # halves of the story path against the element tag.
  if story.name.len > 0 and result.len >= 2 and result[^1] == story.name and
      not (result[^2] == story.name):
    # only drop if the *story name itself* (result[^2] in the typical
    # group+name+tag shape) is already present earlier in the chain.
    if story.name in result[0 ..< result.high]:
      result.setLen(result.len - 1)

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
  # 2026-05-28 icon-coverage expansion: the sidebar-toggle buttons in
  # the status bar now render real SVG icons from the active IconSet
  # instead of the Unicode arrow glyphs (U+21E4 / U+21E5). Source from
  # ``currentIconSet()`` so the per-set sidebar artwork follows the
  # rest of the editor chrome (in-house set today; a future preference
  # swap repoints every call site through ``currentIconSet`` in lock
  # step).
  let iconSet = currentIconSet()
  r.appendChild(leftControls,
    statusPanelButton[R, E](r, vm, epSidebar, "Toggle left sidebar",
      iconSet.sidebarLeft))
  r.appendChild(rightControls,
    statusPanelButton[R, E](r, vm, epInspector, "Toggle right sidebar",
      iconSet.sidebarRight))
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
  ##
  ## 2026-05-28: drag-resize affordance landed. The sidebar root is now
  ## ``position: relative`` so a 4 px ``data-resize-handle="left-sidebar"``
  ## strip can absolute-position itself at the right edge; mousedown on
  ## the strip drives ``vm.setLeftSidebarWidth`` via the
  ## ``window.__isonimEditor.setLeftSidebarWidth`` exposure in
  ## ``browser.nim``. A reactive effect mirrors ``vm.leftSidebarWidth``
  ## back onto the sidebar's inline ``width`` so headless tests (and
  ## programmatic callers) can drive the same signal.
  let capturedVm = vm
  let sidebar = ui(r):
    tdiv(class = "editor-sidebar",
          `data-editor-sidebar` = "true",
          display = "flex", flex_direction = "column",
          width = "260px", min_width = "180px", max_width = "420px",
          height = "100%",
          position = "relative",
          flex_shrink = "0",
          background_color = bgSidebar,
          border_right = "1px solid " & borderStrong,
          overflow_y = "auto", overflow_x = "hidden"):

      # Search input
      var searchInput: E
      # CHRM-M7 — sidebar header row holds the search input plus a
      # narrow-only history affordance.  At wide / laptop widths the
      # chrome-bar's history button (rendered inside the centre
      # column) is the canonical entry to the gallery; at narrow
      # widths the centre column collapses (``display: none`` via
      # ``browser.nim``'s ``@media (max-width: 768px)`` rule) so the
      # chrome-bar button is unreachable. This sidebar-resident
      # mirror is shown only at narrow widths (the
      # ``editor-sidebar-history-narrow`` class is gated on the same
      # CSS media query) and drives the same gallery host state.
      var sidebarHistorySlot: E
      tdiv(padding = "8px 10px",
            border_bottom = "1px solid " & borderFaint):
        tdiv(display = "flex", align_items = "center",
              gap = "6px"):
          tdiv(display = "flex", align_items = "center",
                background_color = bgSurface,
                border = "1px solid " & border,
                border_radius = "5px", padding = "0 8px", height = "28px",
                flex = "1"):
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
          # Narrow-only history-button slot. ``mountHistoryButtonForEditor``
          # appends the 🕘 button into this slot. The
          # ``editor-sidebar-history-narrow`` class is gated by the
          # CSS media query in ``browser.nim``: ``display: none`` at
          # wide / laptop widths, ``inline-flex`` at narrow widths.
          # No inline ``display`` here so the class rule wins.
          tdiv(ref = sidebarHistorySlot,
                class = "editor-sidebar-history-narrow",
                `data-sidebar-history-slot` = "true",
                align_items = "center",
                justify_content = "center")
      # CHRM-M7 — mount a sidebar-only history affordance. The button
      # is in the DOM at all widths but the slot is ``display: none``
      # by default; the CSS rule injected in ``browser.nim`` flips it
      # to ``inline-flex`` at narrow widths so the affordance surfaces
      # only when the chrome-bar button is unreachable. The sidebar
      # mirror uses a distinct data attribute so existing
      # ``[data-design-review-history-button="true"]`` selectors
      # continue to resolve to a single (chrome-bar) element.
      block:
        design_review_mount_view.mountSidebarHistoryButtonForEditor[R, E](
          r, sidebarHistorySlot, vm)
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
              align_items = "stretch", justify_content = "space-around",
              gap = "4px", padding = "6px 6px",
              border_radius = "6px",
              background_color = bgBase,
              border = "1px solid " & borderFaint):
          for k in quickNavCategories:
            var iconNode: E
            let cKind = k
            let cLabel = quickNavLabel(k)
            let cShort = quickNavShortLabel(k)
            let cIcon = quickNavIcon(k)
            let cSectionId = quickNavSectionId(k)
            let onPick = quickNavHandler(vm, cKind)
            # M-EVP-14 Wave B: the previous icon-only strip relied on
            # hover tooltips (HTML `title`) for legibility, which static
            # screenshot reviewers can't see. Add a tiny visible caption
            # under each glyph so the meaning of the diamond / square /
            # triangle / circle is unambiguous from a still capture.
            # `quickNavShortLabel` keeps each caption inside the ~40 px
            # cell budget; the full label still surfaces via `title` +
            # `aria-label` for hover and screen-reader use.
            tdiv(ref = iconNode,
                  `data-category-kind` = $cKind,
                  `data-quicknav-icon` = cSectionId,
                  `role` = "button",
                  `aria-label` = "Focus " & cLabel & " category",
                  onclick = onPick,
                  onkeydown = onPick,
                  display = "flex", flex_direction = "column",
                  align_items = "center", justify_content = "center",
                  flex = "1", min_width = "0",
                  padding = "4px 2px",
                  border_radius = "5px",
                  color = textMuted,
                  transition = "background-color 0.12s, color 0.12s"):
              span(font_size = "13px", line_height = "1"):
                text cIcon
              span(font_size = "9px", line_height = "1.1",
                    margin_top = "3px",
                    white_space = "nowrap", overflow = "hidden",
                    text_overflow = "ellipsis",
                    max_width = "100%",
                    `data-quicknav-caption` = "true"):
                text cShort
            block:
              # Keep the native HTML `title` tooltip too — useful in
              # interactive sessions and for any future narrower variant
              # where the caption text gets ellipsised.
              r.setAttribute(iconNode, "title", cLabel)
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
                # M-EVP-14 Wave Chrome CR-5: suppress the
                # "Toggle Setting Flow" pseudo-story from the sidebar
                # tree. The Settings-app demo references its three flow
                # steps from the settings storyboard but the flow itself
                # is not a navigable demo from the sidebar — leaving it
                # in the User Journeys section ghosts a non-functional
                # entry. The flow's `StoryItem` records (used by the
                # storyboard + launcher tests) are unaffected.
                if group.name == "Toggle Setting Flow":
                  continue
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
                                # M-EVP-14 Wave Chrome CR-1: bumped vertical
                                # padding from 7px → 10px each side so story
                                # rows have visible breathing room (~40 px
                                # row height vs the previous ~28 px). The
                                # horizontal padding (28 px left, 12 px
                                # right) is unchanged so the indent rhythm
                                # against the section / group headers is
                                # preserved.
                                padding = "10px 12px 10px 28px",
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

  # 2026-05-28: drag-resize handle. A 4 px-wide strip pinned to the
  # right edge of the sidebar; cursor: col-resize. The JS-side
  # mousedown/move/up wiring lives in ``installSidebarResizeWiring``
  # below and calls ``window.__isonimEditor.setLeftSidebarWidth`` which
  # is exposed in ``browser.nim``. Headless tests drive the same VM
  # signal directly via ``setLeftSidebarWidth``.
  let resizeHandle = ui(r):
    tdiv(`data-resize-handle` = "left-sidebar",
         `aria-hidden` = "true",
         position = "absolute",
         right = "0", top = "0",
         width = "4px", height = "100%",
         cursor = "col-resize",
         background_color = "transparent",
         z_index = "30")
  r.appendChild(sidebar, resizeHandle)

  # Reactive width mirror — ``vm.leftSidebarWidth`` is the source of
  # truth; this effect writes its current value back onto the sidebar's
  # inline ``width``. This is the same pattern used for the right
  # panel via ``bindRightPanelWidth``.
  block:
    let captSidebar = sidebar
    createRenderEffect proc() =
      let w = capturedVm.leftSidebarWidth.val
      let wpx = $w & "px"
      r.setStyle(captSidebar, "width", wpx)
      r.setStyle(captSidebar, "flex-basis", wpx)
      r.setAttribute(captSidebar, "data-left-sidebar-width", $w)

  when defined(js):
    # Mousedown on the handle records the starting cursor X + sidebar
    # width; mousemove computes the delta and pushes the new width
    # through the ``window.__isonimEditor.setLeftSidebarWidth`` hook
    # (exposed in ``browser.nim``). Mouseup releases the drag. We
    # mirror the same body-level cursor / user-select toggles the
    # right-panel handler uses so dragging across the viewport doesn't
    # select text.
    let handleEl = resizeHandle
    let sidebarEl = sidebar
    {.emit: ["""
      (function (handle, sidebar) {
        if (!handle || !document) return;
        var startX = 0;
        var startW = 0;
        var dragging = false;
        function endDrag() {
          if (!dragging) return;
          dragging = false;
          document.body.style.cursor = '';
          document.body.style.userSelect = '';
        }
        handle.addEventListener('mousedown', function (e) {
          dragging = true;
          startX = e.clientX;
          startW = sidebar.getBoundingClientRect().width;
          document.body.style.cursor = 'col-resize';
          document.body.style.userSelect = 'none';
          if (e.preventDefault) e.preventDefault();
        });
        document.addEventListener('mousemove', function (e) {
          if (!dragging) return;
          var delta = e.clientX - startX;
          var w = Math.max(180, Math.min(420, Math.round(startW + delta)));
          if (window.__isonimEditor &&
              window.__isonimEditor.setLeftSidebarWidth) {
            window.__isonimEditor.setLeftSidebarWidth(w);
          }
        });
        document.addEventListener('mouseup', endDrag);
        document.addEventListener('mouseleave', endDrag);
      })(""", handleEl, """, """, sidebarEl, """);
    """].}

  result = sidebar

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
    # M-EVP-14: pill chip styling.
    #  * Active   — solid #7C7AED fill, white text, font-weight 600,
    #              no border (Wave Chrome CR-2: dropped the 1px
    #              transparent border so the active chip reads as a
    #              clean fill, not a bordered shape — the previous
    #              "1px solid transparent" still reserved a 1px gap
    #              that made the active state read as a border swap
    #              rather than a fill state at thumbnail scale).
    #  * Inactive — transparent fill, muted #A0A2B0 label, 1px
    #              rgba(255,255,255,0.08) border.
    #  * Unavailable — same shape as inactive but with opacity 0.35 and
    #              `cursor: not-allowed`.
    r.setStyle(chip, "background-color",
      if selected: accent else: "transparent")
    r.setStyle(chip, "color",
      if selected: "#FFFFFF"
      elif available: "#A0A2B0"
      else: textDim)
    r.setStyle(chip, "border",
      if selected: "none"
      else: "1px solid rgba(255,255,255,0.08)")
    r.setStyle(chip, "border-radius", "6px")
    r.setStyle(chip, "padding", "4px 12px")
    r.setStyle(chip, "font-weight", if selected: "600" else: "500")
    r.setStyle(chip, "opacity", if available: "1" else: "0.35")
    r.setStyle(chip, "cursor",
      if available: "pointer" else: "not-allowed")
    r.setStyle(chip, "box-shadow", "none")
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
    # M-EVP-14: unified pill chip styling — solid accent fill with
    # white label on the active chip; transparent fill with muted label
    # and a faint 1px border on the inactive chip. Mirrors
    # `bindBackendChip` and `bindModeChip` so the three clusters share
    # one affordance.
    r.setStyle(chip, "background-color",
      if selected: accent else: "transparent")
    r.setStyle(chip, "color",
      if selected: "#FFFFFF" else: "#A0A2B0")
    r.setStyle(chip, "border",
      if selected: "none"
      else: "1px solid rgba(255,255,255,0.08)")
    r.setStyle(chip, "border-radius", "6px")
    r.setStyle(chip, "padding", "4px 12px")
    r.setStyle(chip, "font-weight", if selected: "600" else: "500")
    r.setStyle(chip, "cursor", "pointer")
    r.setStyle(chip, "opacity", "1")
    r.setStyle(chip, "box-shadow", "none")
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
    # M-EVP-14: unified pill chip styling — see `bindBackendChip` for
    # the shared rule.
    r.setStyle(chip, "background-color",
      if selected: accent else: "transparent")
    r.setStyle(chip, "color",
      if selected: "#FFFFFF"
      elif enabled: "#A0A2B0"
      else: textDim)
    r.setStyle(chip, "border",
      if selected: "none"
      else: "1px solid rgba(255,255,255,0.08)")
    r.setStyle(chip, "border-radius", "6px")
    r.setStyle(chip, "padding", "4px 12px")
    r.setStyle(chip, "font-weight", if selected: "600" else: "500")
    r.setStyle(chip, "opacity", if enabled: "1" else: "0.35")
    r.setStyle(chip, "cursor",
      if enabled: "pointer" else: "not-allowed")
    r.setStyle(chip, "box-shadow", "none")
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

proc backendsForLeftEdge(): array[7, PreviewBackend] =
  [pbWeb, pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid, pbIos]

proc backendShortLabelsForLeftEdge(): array[7, string] =
  ["Web", "TUI", "GPUI", "Freya", "Cocoa", "Android", "iOS"]

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
  ## M-EVP-14: the column variant ships its primary strip inside a
  ## bordered, dark, rounded container (the M57 edge-strip affordance).
  ## When the cluster lives in the chrome bar each chip should read as
  ## its own pill — NOT as a segment of a single filled bar — so we
  ## strip the container's background + border, force a transparent
  ## surface, and add a 4px inter-chip gap so the pills don't kiss.
  proc tiltHorizontal(root: E; ariaLabel: string) =
    r.setStyle(root, "flex-direction", "row")
    r.setStyle(root, "align-items", "center")
    r.setStyle(root, "width", "auto")
    r.setStyle(root, "min-width", "0")
    r.setStyle(root, "background-color", "transparent")
    r.setStyle(root, "border", "none")
    r.setStyle(root, "border-radius", "0")
    r.setStyle(root, "gap", "4px")
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
    visibleLimit = 7,
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

  # REV-M2: ``renderPreviewPane`` is the legacy entry-point and is
  # currently only exercised by tests; the production mount path goes
  # through ``renderEditorShell`` directly, which is where the brief
  # tab strip is appended. We deliberately avoid mounting the strip
  # here so the legacy preview-pane tests (which assert on
  # ``pane.children.len``) remain stable.
  pane

const inspectorPlaceholderSections* = [
  ("position",             "Position"),
  ("layout",               "Layout"),
  ("appearance",           "Appearance"),
  ("fill",                 "Fill"),
  ("stroke",               "Stroke"),
  ("effects",              "Effects"),
  ("typography",           "Typography"),
  ("selection-colors",     "Selection colors"),
  ("source",               "Source"),
  ("component-properties", "Component properties"),
  ("state",                "State"),
  ("export",               "Export")
]
  ## Phase A — Section-based inspector demolition. The single-column
  ## scroll surface that replaces the prior 12-sub-tab + Manual/
  ## Assistant tab pair lists these twelve sections in
  ## user-decided order. Each entry is ``(slug, displayName)``.
  ## Phase C wires real expansion state + conditional visibility
  ## (Typography only when text element, Component properties only
  ## for instances). Phase G progressively extracts per-section
  ## content from ``populateInspectorManualBody`` in
  ## ``component_edit.nim`` into per-section widget files.

const inspectorSectionsWithPlusAction = [
  "fill", "stroke", "effects", "export"]
  ## Phase B — sections whose header right slot renders a ``+`` plus
  ## button placeholder ("add fill", "add stroke", "add effect",
  ## "add export entry"). Selection colors / Appearance / Layout
  ## carry richer affordances (swatches / eye+droplet / constraint
  ## widget) that Phase G owns — for Phase B those sections render
  ## an empty action slot so the right margin still lines up.

func selectionDisplayName(tag: string): string =
  ## Map an ``ElementRef.tag`` to the selection-header display label
  ## used in the dropdown trigger. The mapping leans on common HTML
  ## semantics: container tags read as "Group" / "Frame"; text-bearing
  ## tags read as "Text"; form controls keep their semantic name.
  ## Unknown tags fall through to a capitalised echo of the tag so
  ## new elements aren't relabelled as a generic "Element".
  let lower = tag.toLowerAscii()
  case lower
  of "div", "section", "main", "article", "aside", "nav", "header",
      "footer": "Group"
  of "span", "p", "h1", "h2", "h3", "h4", "h5", "h6", "label",
      "strong", "em", "small", "code", "pre": "Text"
  of "button": "Button"
  of "a": "Link"
  of "img": "Image"
  of "svg": "Vector"
  of "input": "Input"
  of "textarea": "Text area"
  of "select": "Select"
  of "ul", "ol", "li": "List"
  of "table", "thead", "tbody", "tr", "td", "th": "Table"
  of "form": "Form"
  of "iframe": "Frame"
  of "":
    ""
  else:
    # Preserve unknown tag names verbatim — capitalised first letter
    # so it reads as a noun in the dropdown without losing identity.
    if lower.len > 0:
      lower[0..0].toUpperAscii() & lower[1..^1]
    else:
      ""

proc renderSelectionHeader[R, E](r: R; vm: EditorVM): E =
  ## Phase B (2026-05-28): the always-visible selection header that
  ## sits above the section list. Layout matches the Figma reference
  ## (`docs/sidebar-figma-reference.png`):
  ##
  ##   ``[Group ▾]                    [</>] [◐] [▭▾] [⫶⫶]``
  ##
  ## Left: an element-type dropdown trigger that reads from
  ## ``vm.inspector.selectedElement.tag`` via ``selectionDisplayName``.
  ## When no element is selected the trigger renders "Nothing
  ## selected" in muted text (no chevron).
  ##
  ## Right: a four-icon cluster (Code / Visibility / Duplicate /
  ## More) wired to Phase B placeholder hooks on the VM. The
  ## Visibility button is the only one whose pressed-state is
  ## reactive in Phase B; the rest are no-op handlers ready for
  ## Phase D / E / G to wire up real behaviour.
  ##
  ## The header is `flex-shrink: 0` so it stays pinned to the top
  ## of the inspector regardless of how the section list scrolls,
  ## and carries ``data-inspector-selection-header="true"`` for the
  ## test harness + future hydration.

  var labelEl: E
  var chevronEl: E
  var codeBtn: E
  var codeIcon: E
  var visBtn: E
  var visIcon: E
  var dupBtn: E
  var dupIcon: E
  var moreBtn: E
  var moreIcon: E
  let header = ui(r):
    tdiv(`data-inspector-selection-header` = "true",
         display = "flex", align_items = "center",
         justify_content = "space-between",
         padding = "8px 12px",
         gap = "8px",
         min_height = "40px",
         flex_shrink = "0",
         background_color = bgSidebar,
         border_bottom = "1px solid " & border):
      # Left: element-type dropdown trigger. The chevron is rendered
      # as a separate node so the empty-selection state can hide it
      # without splitting the markup further.
      tdiv(`data-inspector-selection-trigger` = "true",
           role = "button",
           tabindex = "0",
           `aria-label` = "Selection element type",
           display = "flex", align_items = "center", gap = "4px",
           padding = "4px 6px",
           border_radius = "4px",
           cursor = "default",
           min_width = "0",
           font_size = "13px", font_weight = "600"):
        span(ref = labelEl,
             `data-inspector-selection-label` = "true",
             color = textPrimary,
             overflow = "hidden",
             text_overflow = "ellipsis",
             white_space = "nowrap"):
          text "Nothing selected"
        span(ref = chevronEl,
             `data-inspector-selection-chevron` = "true",
             `aria-hidden` = "true",
             color = textMuted,
             font_size = "10px",
             line_height = "1"):
          text "\xE2\x96\xBE" # ▾
      # Right: 4 quick-action icon buttons. They share a uniform
      # 24×24 footprint so the right-edge alignment matches the
      # Figma reference; the inner 16×16 host carries the SVG glyph
      # itself. Refs are captured so the SVG-paint, reactive style
      # binds, and click wiring below can address each button + its
      # icon host directly (no tree walks — the `DomRenderer` path
      # only exposes navigation helpers, not flat ``children``).
      tdiv(`data-inspector-selection-actions` = "true",
           display = "flex", align_items = "center", gap = "2px",
           flex_shrink = "0"):
        tdiv(ref = codeBtn,
             `data-inspector-selection-action` = "code",
             role = "button",
             tabindex = "0",
             `aria-label` = "Open source for selection",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "24px", height = "24px",
             border_radius = "4px",
             color = textMuted,
             cursor = "pointer"):
          tdiv(ref = codeIcon,
               `aria-hidden` = "true",
               display = "flex", align_items = "center",
               justify_content = "center",
               width = "16px", height = "16px",
               line_height = "1")
        tdiv(ref = visBtn,
             `data-inspector-selection-action` = "visibility",
             role = "button",
             tabindex = "0",
             `aria-label` = "Toggle selection visibility",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "24px", height = "24px",
             border_radius = "4px",
             color = textMuted,
             cursor = "pointer"):
          tdiv(ref = visIcon,
               `aria-hidden` = "true",
               display = "flex", align_items = "center",
               justify_content = "center",
               width = "16px", height = "16px",
               line_height = "1")
        tdiv(ref = dupBtn,
             `data-inspector-selection-action` = "duplicate",
             role = "button",
             tabindex = "0",
             `aria-label` = "Duplicate selection",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "24px", height = "24px",
             border_radius = "4px",
             color = textMuted,
             cursor = "pointer"):
          tdiv(ref = dupIcon,
               `aria-hidden` = "true",
               display = "flex", align_items = "center",
               justify_content = "center",
               width = "16px", height = "16px",
               line_height = "1")
        tdiv(ref = moreBtn,
             `data-inspector-selection-action` = "more",
             role = "button",
             tabindex = "0",
             `aria-label` = "More selection actions",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "24px", height = "24px",
             border_radius = "4px",
             color = textMuted,
             cursor = "pointer"):
          tdiv(ref = moreIcon,
               `aria-hidden` = "true",
               display = "flex", align_items = "center",
               justify_content = "center",
               width = "16px", height = "16px",
               line_height = "1")

  # Paint glyphs via setInnerHtml — established affordance for inline
  # SVG payloads (mirrors ``renderQuickNavIcon`` and the chrome bar).
  r.setInnerHtml(codeIcon, selectionCodeSvg)
  r.setInnerHtml(visIcon, selectionVisibilitySvg)
  r.setInnerHtml(dupIcon, selectionDuplicateSvg)
  r.setInnerHtml(moreIcon, selectionMoreSvg)

  # Reactive bind: the label + chevron track the selected element;
  # the visibility button tracks ``selectionVisible``. Both flow
  # through ``createRenderEffect`` so the no-setStyle-outside-effect
  # rule holds.
  createRenderEffect proc() =
    let element = vm.inspector.selectedElement.val
    let label = selectionDisplayName(element.tag)
    if label.len > 0:
      r.setTextContent(labelEl, label)
      r.setStyle(labelEl, "color", textPrimary)
      r.setStyle(chevronEl, "display", "inline")
    else:
      r.setTextContent(labelEl, "Nothing selected")
      r.setStyle(labelEl, "color", textMuted)
      r.setStyle(chevronEl, "display", "none")

  createRenderEffect proc() =
    let visible = vm.inspector.selectionVisible.val
    r.setAttribute(visBtn, "aria-pressed",
      if visible: "true" else: "false")
    r.setStyle(visBtn, "color",
      if visible: textPrimary else: textMuted)

  # Click wiring. The "code" / "duplicate" / "more" actions hit the
  # Phase B placeholder procs on ``EditorVM``; the "visibility"
  # action flips the signal that the reactive bind above watches.
  r.addEventListener(codeBtn, "click", proc() = vm.openSourceForSelection())
  r.addEventListener(codeBtn, "keydown", proc() = vm.openSourceForSelection())
  r.addEventListener(visBtn, "click", proc() = vm.toggleSelectionVisible())
  r.addEventListener(visBtn, "keydown", proc() = vm.toggleSelectionVisible())
  r.addEventListener(dupBtn, "click", proc() = vm.duplicateSelection())
  r.addEventListener(dupBtn, "keydown", proc() = vm.duplicateSelection())
  r.addEventListener(moreBtn, "click", proc() = vm.showSelectionMore())
  r.addEventListener(moreBtn, "keydown", proc() = vm.showSelectionMore())

  header

proc renderSectionFrame[R, E](r: R; vm: EditorVM;
    slug, displayName: string): tuple[row: E, body: E] =
  ## Phase B (2026-05-28): structured section frame — header (title
  ## + per-section action slot + chevron caret) plus an empty body
  ## the Phase G extraction will populate. The whole frame respects
  ## the dark-theme tokens established in ``shell.nim`` (``border``
  ## hairline divider, ``textPrimary`` headline, ``textMuted``
  ## chevron, ``bgSidebar`` surface).
  ##
  ## Phase C (2026-05-28): the header is now a real toggle. Click /
  ## Enter / Space flip the owning section's ``expandedSections``
  ## membership via ``toggleSectionExpanded``; a reactive effect
  ## mirrors the live expanded state into ``data-expanded`` /
  ## ``aria-expanded`` on the header, the body's ``display``
  ## (``flex`` vs ``none``), and the chevron glyph (``▾`` vs
  ## ``▸``). Phase G fills the body — the section frame doesn't
  ## reach into ``populateInspectorManualBody``.
  ##
  ## The header right slot is reserved per the section catalogue. In
  ## Phase B only Fill / Stroke / Effects / Export carry a ``+`` plus
  ## button placeholder — the other sections leave the slot empty so
  ## the right margin lines up but the chrome stays quiet.
  let hasPlus = slug in inspectorSectionsWithPlusAction
  let section = inspectorSectionFromAttr(slug)
  var plusIcon: E
  var headerEl: E
  var bodyEl: E
  var chevronEl: E
  var addBtn: E
  let row = ui(r):
    tdiv(`data-inspector-section-row` = slug,
         display = "flex", flex_direction = "column",
         border_bottom = "1px solid " & border):
      tdiv(ref = headerEl,
           `data-inspector-section-header` = slug,
           `data-expanded` = "true",
           role = "button",
           tabindex = "0",
           `aria-expanded` = "true",
           display = "flex", align_items = "center",
           justify_content = "space-between",
           gap = "8px",
           padding = "10px 12px",
           cursor = "pointer",
           user_select = "none"):
        span(`data-inspector-section-title` = "true",
             font_size = "13px", font_weight = "600",
             color = textPrimary,
             flex = "1", min_width = "0",
             overflow = "hidden",
             text_overflow = "ellipsis",
             white_space = "nowrap"):
          text displayName
        # Per-section action slot. The slot is always rendered (even
        # when empty) so chevron alignment is uniform across the
        # 12 frames.
        tdiv(`data-inspector-section-actions` = slug,
             display = "flex", align_items = "center",
             gap = "2px",
             flex_shrink = "0"):
          if hasPlus:
            tdiv(ref = addBtn,
                 `data-inspector-section-action` = "add",
                 role = "button",
                 tabindex = "0",
                 `aria-label` = "Add " & displayName & " entry",
                 display = "flex", align_items = "center",
                 justify_content = "center",
                 width = "20px", height = "20px",
                 border_radius = "4px",
                 color = textMuted,
                 cursor = "pointer"):
              tdiv(ref = plusIcon,
                   `aria-hidden` = "true",
                   display = "flex", align_items = "center",
                   justify_content = "center",
                   width = "14px", height = "14px",
                   line_height = "1")
        tdiv(ref = chevronEl,
             `data-inspector-section-chevron` = slug,
             `aria-hidden` = "true",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "12px", height = "12px",
             flex_shrink = "0",
             color = textMuted,
             font_size = "10px",
             line_height = "1"):
          text "\xE2\x96\xBE" # ▾
      tdiv(ref = bodyEl,
           `data-inspector-section-body` = slug,
           display = "flex", flex_direction = "column",
           padding = "0 12px 12px 12px",
           min_height = "0")
  # Paint the plus glyph outside the DSL — the renderer affordance
  # for inline SVG payloads is ``setInnerHtml``, which is an imperative
  # call. The icon host ref is only assigned when ``hasPlus`` flagged
  # the slot to be rendered.
  if hasPlus:
    r.setInnerHtml(plusIcon, plusSvg)

  # Phase C reactive bind: the header's ``data-expanded`` /
  # ``aria-expanded`` attributes, the chevron glyph, and the body's
  # display mode all track ``inspector.expandedSections``. A single
  # ``createRenderEffect`` keeps them in sync — flipping the signal
  # (via header click, keyboard activation, storage hydration, or
  # ``collapseAllSections``/``expandRelevantSections``) repaints the
  # frame on the next render tick.
  createRenderEffect proc() =
    let expanded = section in vm.inspector.expandedSections.val
    r.setAttribute(headerEl, "data-expanded",
      if expanded: "true" else: "false")
    r.setAttribute(headerEl, "aria-expanded",
      if expanded: "true" else: "false")
    r.setStyle(bodyEl, "display",
      if expanded: "flex" else: "none")
    r.setTextContent(chevronEl,
      if expanded: "\xE2\x96\xBE" else: "\xE2\x96\xB8") # ▾ vs ▸

  # Click + keyboard activation flip the owning section in
  # ``expandedSections``. The no-arg handler mirrors the selection-
  # header buttons above; under MockRenderer ``fireEvent`` calls it
  # directly (tests pass the slug they want, no key filtering needed).
  # Under DomRenderer the JS shim below filters keydown to Enter /
  # Space + intercepts the per-section ``+`` button click so it
  # doesn't bubble into the header (otherwise pressing Fill's ``+``
  # would also toggle Fill's expansion).
  r.addEventListener(headerEl, "click", proc() =
    vm.inspector.toggleSectionExpanded(section))
  r.addEventListener(headerEl, "keydown", proc() =
    vm.inspector.toggleSectionExpanded(section))

  when defined(js):
    let headerJsEl = headerEl
    {.emit: ["""
      (function (header) {
        if (!header || header.__isonimSectionHeaderReady) return;
        header.__isonimSectionHeaderReady = true;
        // Suppress the default scroll-on-Space behaviour and stop
        // Tab / Shift+Tab from triggering the keydown listener that
        // the renderer registered. The listener itself is a no-arg
        // callback so we cannot filter inside it; the capture-phase
        // shim below pre-empts non-activation keys by stopping
        // propagation before the renderer's listener sees them.
        header.addEventListener('keydown', function (ev) {
          if (!ev) return;
          var k = ev.key;
          if (k === 'Enter' || k === ' ' || k === 'Spacebar') {
            if (ev.preventDefault) ev.preventDefault();
            return;
          }
          if (ev.stopImmediatePropagation) ev.stopImmediatePropagation();
          else if (ev.stopPropagation) ev.stopPropagation();
        }, true);
      })(""", headerJsEl, """);
    """].}

    if hasPlus:
      let addBtnJsEl = addBtn
      {.emit: ["""
        (function (btn) {
          if (!btn || btn.__isonimSectionAddReady) return;
          btn.__isonimSectionAddReady = true;
          btn.addEventListener('click', function (ev) {
            if (ev && ev.stopPropagation) ev.stopPropagation();
          }, false);
        })(""", addBtnJsEl, """);
      """].}

  result = (row: row, body: bodyEl)

proc mountInspectorSectionBody[R, E](r: R; vm: EditorVM;
    slug: string; body: E) =
  ## Phase G — dispatch the section body content to its widget. The
  ## body slot was left empty by ``renderSectionFrame``; this proc
  ## reads the slug, picks the matching ``mountSection<Name>`` widget,
  ## and mounts its property rows into ``body``. Unknown slugs are a
  ## no-op so future section additions don't trip the dispatcher
  ## before they have a widget module.
  case slug
  of "position":
    mountSectionPosition[R, E](r, body, vm)
  of "layout":
    mountSectionLayout[R, E](r, body, vm)
  of "appearance":
    mountSectionAppearance[R, E](r, body, vm)
  of "fill":
    mountSectionFill[R, E](r, body, vm)
  of "stroke":
    mountSectionStroke[R, E](r, body, vm)
  of "effects":
    mountSectionEffects[R, E](r, body, vm)
  of "typography":
    mountSectionTypography[R, E](r, body, vm)
  of "selection-colors":
    mountSectionSelectionColors[R, E](r, body, vm)
  of "source":
    mountSectionSource[R, E](r, body, vm)
  of "component-properties":
    mountSectionComponentProps[R, E](r, body, vm)
  of "state":
    mountSectionState[R, E](r, body, vm)
  of "export":
    mountSectionExport[R, E](r, body, vm)
  else: discard

proc renderInspectorPanel*[R, E](r: R; vm: EditorVM): E =
  ## Right sidebar — a selection header above a single-column scroll
  ## surface of inspector section frames.
  ##
  ## 2026-05-28 Phase A demolition: the prior Manual/Assistant tab
  ## pair plus the 12-sub-tab strip were torn out (see
  ## ``Front-Ends/IsoNim/isonim-editor.md`` §"Property Inspector
  ## Panel — Section-Based Design"). The sidebar now scrolls a
  ## single column of section frames — the same shape Figma's
  ## UI3 design panel uses. The AI assistant moved out of the
  ## sidebar entirely; per-chat robot icons live in the chrome bar
  ## and open a slide-out drawer (Phase F).
  ##
  ## 2026-05-28 Phase B: the placeholders are replaced by structured
  ## section frames (header + per-section action slot + chevron caret
  ## + empty body) and a non-scrolling selection header is mounted
  ## above the section list. See ``renderSelectionHeader`` and
  ## ``renderSectionFrame`` above.
  ##
  ## Phase B scope:
  ##   * Mount the selection header (element-type dropdown + 4 quick-
  ##     action icons) above the section list.
  ##   * Replace each placeholder row with the structured frame —
  ##     header title, per-section action slot (``+`` for Fill /
  ##     Stroke / Effects / Export, empty otherwise), chevron, empty
  ##     body.
  ##   * Keep the sidebar root's ``data-test-id="property-panel"``
  ##     contract (existing e2e tests resolve the sidebar by it).
  ##   * Keep the left-edge drag-resize handle.
  ##   * STILL skip ``populateInspectorManualBody`` — that proc is
  ##     preserved in ``component_edit.nim`` for Phase G content
  ##     extraction but is not mounted here.
  ##
  ## All section bodies render as visible (empty) for Phase B. Every
  ## frame ships with ``data-expanded="true"`` so Phase C can flip
  ## individual sections without re-mounting. Conditional visibility
  ## (Typography only when text element, Component properties only
  ## for instances, etc.) lands in Phase C as well.

  # Selection header. Sits above the section list and stays pinned —
  # ``flex-shrink: 0`` inside the header proc.
  let selectionHeaderEl = renderSelectionHeader[R, E](r, vm)

  # Section list container — the single scrollable column that the
  # section frames mount into. Direct child of the sidebar root.
  var sectionList: E
  let sectionListEl = ui(r):
    tdiv(ref = sectionList,
         `data-inspector-section-list` = "true",
         display = "flex", flex_direction = "column",
         flex = "1", min_height = "0", min_width = "0",
         overflow_y = "auto", overflow_x = "hidden")

  for (slug, displayName) in inspectorPlaceholderSections:
    let frame = renderSectionFrame[R, E](r, vm, slug, displayName)
    r.appendChild(sectionList, frame.row)
    mountInspectorSectionBody[R, E](r, vm, slug, frame.body)

  result = ui(r):
    tdiv(class = "editor-inspector",
          `data-test-id` = "property-panel",
          display = "flex", flex_direction = "column",
          # 2026-05-28: default width bumped to 320 (signal default in
          # viewmodels.nim); ``bindRightPanelWidth`` overwrites this
          # static value reactively on first paint. Floor stays at
          # 200 px so the AI inspector rail can still narrow.
          width = "320px", min_width = "200px", max_width = "420px",
          height = "100%",
          position = "relative",
          flex_shrink = "0",
          background_color = bgSidebar,
          border_left = "1px solid " & borderStrong,
          overflow_x = "hidden")

  let sidebarRoot = result

  # 2026-05-28: left-edge drag-resize handle. Symmetrical with the
  # left sidebar's right-edge handle; drives ``setRightPanelWidth``
  # via the ``window.__isonimEditor.setRightPanelWidth`` exposure in
  # ``browser.nim``. The handle is absolutely-positioned on the inner
  # edge (which is the LEFT edge for the right panel) at z-index 30
  # so it sits above the section-list content. Appended FIRST so
  # downstream tests / consumers find the handle reliably regardless
  # of section-list growth.
  let rightResizeHandle = ui(r):
    tdiv(`data-resize-handle` = "right-panel",
         `aria-hidden` = "true",
         position = "absolute",
         left = "0", top = "0",
         width = "4px", height = "100%",
         cursor = "col-resize",
         background_color = "transparent",
         z_index = "30")
  r.appendChild(sidebarRoot, rightResizeHandle)
  # Phase B (2026-05-28): selection header sits above the scrollable
  # section list. Append BEFORE the list so the DOM order matches the
  # visual order (header first, then list).
  r.appendChild(sidebarRoot, selectionHeaderEl)
  r.appendChild(sidebarRoot, sectionListEl)

  when defined(js):
    let handleEl = rightResizeHandle
    let panelEl = sidebarRoot
    {.emit: ["""
      (function (handle, panel) {
        if (!handle || !document) return;
        var startX = 0;
        var startW = 0;
        var dragging = false;
        function endDrag() {
          if (!dragging) return;
          dragging = false;
          document.body.style.cursor = '';
          document.body.style.userSelect = '';
        }
        handle.addEventListener('mousedown', function (e) {
          dragging = true;
          startX = e.clientX;
          startW = panel.getBoundingClientRect().width;
          document.body.style.cursor = 'col-resize';
          document.body.style.userSelect = 'none';
          if (e.preventDefault) e.preventDefault();
        });
        document.addEventListener('mousemove', function (e) {
          if (!dragging) return;
          // Right panel grows when the cursor moves LEFT (delta < 0
          // means user wants a wider panel). Hence subtract.
          var delta = startX - e.clientX;
          var w = Math.max(200, Math.min(420, Math.round(startW + delta)));
          if (window.__isonimEditor &&
              window.__isonimEditor.setRightPanelWidth) {
            window.__isonimEditor.setRightPanelWidth(w);
          }
        });
        document.addEventListener('mouseup', endDrag);
        document.addEventListener('mouseleave', endDrag);
      })(""", handleEl, """, """, panelEl, """);
    """].}

  # Phase C (2026-05-28): hydrate the inspector's expanded-section
  # set from ``localStorage`` BEFORE the first reactive paint so the
  # default-vs-restored state lands on the inspector frames in a
  # single pass (no flash of the default four). The hydration is a
  # no-op on native (the native build still uses the
  # ``createInspectorVM`` default), so the call is unconditional.
  hydrateInspectorExpansionFromStorage(vm)

  # Phase C reactive write-back: every change to
  # ``expandedSections`` (whether from header click, programmatic
  # toggle, hydration, or ``collapseAllSections``) is serialized to
  # ``localStorage["isonim:inspector:expanded"]``. The shim runs
  # only on JS targets; the native build still owns the
  # signal-write side but skips the storage emit.
  when defined(js):
    createRenderEffect proc() =
      let payload = serializeExpandedSections(
        vm.inspector.expandedSections.val).cstring
      {.emit: ["""
        try {
          if (window.localStorage) {
            window.localStorage.setItem(
              'isonim:inspector:expanded', """, payload, """);
          }
        } catch (e) {}
      """].}

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
          gap = "16px", flex_wrap = "wrap",
          row_gap = "6px",
          min_height = "44px",
          padding_top = "8px", padding_right = "12px",
          padding_bottom = "8px", padding_left = "16px",
          background_color = bgToolbar,
          border_bottom = "1px solid " & border,
          # AIVS-NSO — the chrome bar needs to sit ABOVE the
          # ``no-story`` overlay (z-index 20) so the user can still
          # flip the surface back to Preview, change the viewport, or
          # toggle the mode triplet even while the centre-column
          # body is grayed out.  ``position: relative`` activates the
          # z-index; the layout stays in the centerColumn flex flow.
          position = "relative",
          z_index = "25",
          `data-preview-toolbar` = "true",
          `data-preview-chrome-bar` = "true")

  # 2026-05-28: cluster dividers removed. Per user, the thin vertical
  # hairlines between Backend / Viewport / Mode clusters added visual
  # noise to a chrome bar that was already crowded; the cluster pills
  # themselves carry enough segmentation. The proc and ``appendChild``
  # calls were dropped together so no dead code remains.

  let capturedVm = vm

  # CHRM-M2: backend cluster now uses the ChoiceGroup segmented widget
  # with the per-option ``disabledIndices`` signal driving the
  # streaming-preview availability check + the transparent container
  # variant so the pills sit directly on the chrome-bar surface
  # without the bespoke ``tiltHorizontal`` setStyle workaround.
  let backendOrder = backendsForLeftEdge()
  let backendShortLabels = backendShortLabelsForLeftEdge()
  var backendLabelSeq: seq[string] = @[]
  for s in backendShortLabels: backendLabelSeq.add s

  let backendWrapper = ui(r):
    tdiv(`data-edge-strip` = "backend",
         `data-preview-edge-group` = "backend",
         `data-toolbar-cluster` = "backend",
         display = "inline-flex", align_items = "center",
         `aria-label` = "Preview backend")

  var backendInitialIndex = 0
  block:
    let current = capturedVm.platform.val
    for i in 0 ..< backendOrder.len:
      if backendOrder[i] == current:
        backendInitialIndex = i
        break
  # 2026-05-28 icon-coverage expansion — Backend cluster pills now
  # render the per-backend glyph from the active IconSet. The label
  # text (``Web`` / ``TUI`` / ``GPUI`` / ``Freya`` / ``Cocoa`` /
  # ``Android`` / ``iOS``) is still surfaced as the pill's tooltip +
  # screen-reader label via the icon-aware mount. The icon order must
  # match ``backendOrder`` (pbWeb, pbTui, pbGpui, pbFreya, pbCocoa,
  # pbAndroid, pbIos).
  let chromeIcons = currentIconSet()
  let backendIcons = @[
    chromeIcons.backendWeb,
    chromeIcons.backendTui,
    chromeIcons.backendGpui,
    chromeIcons.backendFreya,
    chromeIcons.backendCocoa,
    chromeIcons.backendAndroid,
    chromeIcons.backendIos,
  ]
  let backendVm = createSegmentedChoiceVMWithIcons(
    backendLabelSeq, backendIcons, initialIndex = backendInitialIndex)

  proc computeBackendDisabled(): HashSet[int] =
    result = initHashSet[int]()
    if capturedVm.streamingPreview == nil:
      return
    for i in 0 ..< backendOrder.len:
      if not capturedVm.streamingPreview.backendIsAvailable(backendOrder[i]):
        result.incl i
  backendVm.setDisabledIndices(computeBackendDisabled())

  r.mountSegmentedChoice(backendWrapper, backendVm,
    proc(i: int) {.closure.} =
      if i < 0 or i >= backendOrder.len:
        return
      let target = backendOrder[i]
      if capturedVm.streamingPreview != nil and
          target in capturedVm.streamingPreview.availableBackends.val:
        selectBackend(capturedVm.streamingPreview, target)
      capturedVm.changePlatform(target),
    variant = cgvTransparent)

  # Mirror external writes to ``vm.platform`` onto the segmented
  # control. Same ``.value``-not-``.val`` precaution as the Surface
  # cluster — reading ``.val`` here would feedback-loop with the
  # mount's click handler. Also refresh the disabled set when
  # ``availableBackends`` flips.
  block:
    let syncVm = backendVm
    createRenderEffect proc() =
      let current = capturedVm.platform.val
      var target = 0
      for i in 0 ..< backendOrder.len:
        if backendOrder[i] == current:
          target = i
          break
      if syncVm.activeIndex.value != target:
        syncVm.activate(target)
    createRenderEffect proc() =
      if capturedVm.streamingPreview == nil:
        syncVm.setDisabledIndices(initHashSet[int]())
        return
      let available = capturedVm.streamingPreview.availableBackends.val
      var disabled = initHashSet[int]()
      for i in 0 ..< backendOrder.len:
        if backendOrder[i] notin available:
          disabled.incl i
      syncVm.setDisabledIndices(disabled)

  # CHRM-M5 Fix A: cluster order is now
  # ``[surface, backend, viewport, mode]`` — Surface moves to the
  # leftmost position so the user reads the surface decision
  # (preview workspace vs brief markdown) before any backend or
  # layout knob. The clusters are constructed in source order
  # below for code readability; the ``appendChild`` order at the
  # bottom of each cluster's block determines the on-screen
  # left-to-right ordering.

  # TBAR-M3 / CHRM-M5: Preview / Spec top-bar surface switch.
  # Leftmost cluster after CHRM-M5. Uses the segmented variant of
  # the ChoiceGroup widget delivered by TBAR-M2. CHRM-M2: the
  # chrome-bar consumer now requests the ``cgvTransparent``
  # container variant so the surface pills sit on the toolbar
  # surface without their own filled backdrop.
  let surfaceWrapper = ui(r):
    tdiv(`data-toolbar-cluster` = "surface",
         `data-preview-surface-switch` = "true",
         display = "inline-flex", align_items = "center")
  # 2026-05-28 icon-coverage expansion — Surface cluster pills render
  # the IconSet's preview / spec glyphs. Label text travels via
  # ``title`` + ``aria-label`` so existing e2e tests that locate the
  # pills by ``data-choice-group-pill`` index continue to work
  # unchanged, and screen-reader / tooltip discoverability is
  # preserved.
  let surfaceVm = createSegmentedChoiceVMWithIcons(
    @["Preview", "Spec"],
    @[chromeIcons.preview, chromeIcons.spec],
    initialIndex = (if capturedVm.surfaceSig.val == sPreview: 0 else: 1))
  r.mountSegmentedChoice(surfaceWrapper, surfaceVm, proc(i: int) {.closure.} =
    capturedVm.setSurface(if i == 0: sPreview else: sSpec),
    variant = cgvTransparent)
  # Keep the segmented control in sync with external writes to
  # ``surfaceSig`` (e.g. tests that flip the signal directly). This
  # effect tracks ONLY ``surfaceSig`` — reading ``activeIndex`` via
  # ``.val`` here would create a feedback loop with the segmented
  # mount's own click handler (which sets ``activeIndex`` then
  # dispatches ``onChange``). We read the bare ``value`` field
  # directly to skip ``trackRead``.
  block:
    let syncVm = surfaceVm
    createRenderEffect proc() =
      let target = if capturedVm.surfaceSig.val == sPreview: 0 else: 1
      if syncVm.activeIndex.value != target:
        syncVm.activate(target)
  r.appendChild(toolbar, surfaceWrapper)

  # CHRM-M5 Fix A: backend cluster appended AFTER the surface
  # cluster so the on-screen order reads
  # ``[surface, backend, viewport, mode]``. The cluster itself
  # was constructed above (alongside its reactive effects) for
  # code readability; only the mount-into-toolbar step happens
  # here.
  r.appendChild(toolbar, backendWrapper)

  # TBAR-M3: screen-size chevron-popup selector. Replaces the legacy
  # viewport chip-set in the chrome bar. The chevron's option list is
  # the union of the per-backend pinned + popup viewports so every
  # viewport reachable today through the old chip strip stays
  # reachable. Re-builds when the platform flips (the rebuild lives
  # inside a ``createRenderEffect`` so the option list, active label,
  # and selection stay coherent).
  proc viewportOptionList(backend: PreviewBackend): seq[PreviewViewport] =
    result = @[]
    for vp in pinnedViewports(backend):
      result.add vp
    for vp in popupViewports(backend):
      result.add vp
  proc viewportLabelList(backend: PreviewBackend): seq[string] =
    result = @[]
    for vp in viewportOptionList(backend):
      result.add vp.label
  let initialBackend = capturedVm.platform.val
  let initialVps = viewportOptionList(initialBackend)
  var initialIndex = 0
  block:
    let active = capturedVm.viewport.val
    for i, vp in initialVps:
      if viewportsEqual(active, vp):
        initialIndex = i
        break
  let viewportChevronWrapper = ui(r):
    tdiv(`data-edge-strip` = "viewport",
         `data-toolbar-cluster` = "viewport",
         `data-preview-edge-group` = "viewport",
         `data-preview-viewport-chevron` = "true",
         display = "inline-flex", align_items = "center")
  var viewportChevronVm = createChevronChoiceVM(
    viewportLabelList(initialBackend), initialIndex = initialIndex)
  var viewportChoices = initialVps
  r.mountChevronChoice(viewportChevronWrapper, viewportChevronVm,
    proc(i: int) {.closure.} =
      if i >= 0 and i < viewportChoices.len:
        capturedVm.changeViewport(viewportChoices[i]),
    variant = cgvTransparent)
  # Reactively rebuild the chevron options when the backend flips OR
  # when an external write to ``viewport`` moves the active index.
  # IMPORTANT: this effect must NOT track ``viewportChevronVm
  # .activeIndex`` — the chevron mount sets that index then dispatches
  # ``onChange``, so a tracking read here would create a feedback loop
  # (the effect would re-fire mid-click, snap the index back to the
  # currently-active viewport, and ``onChange`` would never see a
  # transition). We read the bare ``value`` field directly to skip
  # ``trackRead``.
  createRenderEffect proc() =
    let backend = capturedVm.platform.val
    let active = capturedVm.viewport.val
    let labels = viewportLabelList(backend)
    if labels != viewportChevronVm.labels:
      # Re-mount the chevron with a fresh VM matching the new label
      # list. The DOM under ``viewportChevronWrapper`` is removed first
      # so the new mount paints into a clean host. This is the same
      # pattern ``renderCompactChoiceColumn`` uses internally when its
      # option list churns.
      r.clearChildren(viewportChevronWrapper)
      viewportChoices = viewportOptionList(backend)
      var idx = 0
      for i, vp in viewportChoices:
        if viewportsEqual(active, vp):
          idx = i
          break
      viewportChevronVm = createChevronChoiceVM(labels, initialIndex = idx)
      r.mountChevronChoice(viewportChevronWrapper, viewportChevronVm,
        proc(i: int) {.closure.} =
          if i >= 0 and i < viewportChoices.len:
            capturedVm.changeViewport(viewportChoices[i]),
        variant = cgvTransparent)
    else:
      viewportChoices = viewportOptionList(backend)
      for i, vp in viewportChoices:
        if viewportsEqual(active, vp):
          if viewportChevronVm.activeIndex.value != i:
            viewportChevronVm.activate(i)
          break
  r.appendChild(toolbar, viewportChevronWrapper)

  # CHRM-M2: mode cluster now uses the ChoiceGroup segmented widget +
  # the per-option ``disabledIndices`` signal driven by
  # ``vm.evaluateCommand``. The reactive mirror that flips
  # ``SpecPaneVM.mode`` from ``editMode + surface == sSpec`` (below)
  # is unchanged.
  const modeOrder = [emView, emComment, emEdit]
  const modeLabels = @["View", "Comment", "Edit"]

  let modeWrapper = ui(r):
    tdiv(`data-edge-strip` = "mode",
         `data-preview-edge-group` = "mode",
         `data-toolbar-cluster` = "mode",
         display = "inline-flex", align_items = "center",
         `aria-label` = "Preview mode")

  var modeInitialIndex = 0
  block:
    let active = capturedVm.editMode.val
    for i in 0 ..< modeOrder.len:
      if modeOrder[i] == active:
        modeInitialIndex = i
        break
  # 2026-05-28 icon-coverage expansion — Mode cluster renders the
  # IconSet's modeView / modeComment / modeEdit glyphs. Order matches
  # ``modeOrder`` (emView, emComment, emEdit).
  let modeIcons = @[
    chromeIcons.modeView, chromeIcons.modeComment, chromeIcons.modeEdit]
  let modeVm = createSegmentedChoiceVMWithIcons(modeLabels, modeIcons,
                                       initialIndex = modeInitialIndex)

  proc commandForMode(m: EditMode): EditorCommandKind =
    case m
    of emView: eckInspect
    of emComment: eckComment
    of emEdit: eckEdit

  proc computeModeDisabled(): HashSet[int] =
    result = initHashSet[int]()
    for i in 0 ..< modeOrder.len:
      let state = capturedVm.evaluateCommand(commandForMode(modeOrder[i]))
      if state.status == ecsDisabled:
        result.incl i
  modeVm.setDisabledIndices(computeModeDisabled())

  r.mountSegmentedChoice(modeWrapper, modeVm, proc(i: int) {.closure.} =
    if i < 0 or i >= modeOrder.len:
      return
    discard capturedVm.runEditorCommand(commandForMode(modeOrder[i])),
    variant = cgvTransparent)

  block:
    let syncVm = modeVm
    createRenderEffect proc() =
      let current = capturedVm.editMode.val
      var target = 0
      for i in 0 ..< modeOrder.len:
        if modeOrder[i] == current:
          target = i
          break
      if syncVm.activeIndex.value != target:
        syncVm.activate(target)
    createRenderEffect proc() =
      syncVm.setDisabledIndices(computeModeDisabled())

  r.appendChild(toolbar, modeWrapper)

  # REV-M8 — mount the design-review 🕘 history button at the right
  # end of the chrome bar. CHRM-M5: the button stays VISIBLE for
  # any brief; the gallery overlay's own empty state surfaces
  # "No captures yet" when ``briefHasHistory`` is false, which
  # is a better UX than a button that disappears.
  design_review_mount_view.mountHistoryButtonForEditor[R, E](r, toolbar, vm)

  # Phase F — per-chat robot strip + trailing "+" button.
  #
  # The chrome bar's right-edge slot used to end at the 🕘 history
  # button. Phase F appends the AI-assistant chat strip after it: one
  # 28×28 robot button per ``ChatSession`` in ``vm.chats``, plus a
  # trailing "+" button to spawn fresh chats. The strip uses
  # ``overflow-x: auto`` so many concurrent chats fall behind a
  # native horizontal scrollbar rather than being hidden in a
  # chevron popup.  Clicking a robot toggles the AI drawer for that
  # session (see ``vm.toggleAiDrawer``); the active robot reflects
  # both ``aiDrawerOpen`` and ``activeChatId`` so the indigo accent
  # only lights up when the drawer is actually showing that chat.
  let chromeChatStrip = ui(r):
    tdiv(`data-chrome-chat-strip` = "true",
         `role` = "tablist",
         `aria-label` = "AI chat sessions",
         display = "inline-flex", align_items = "center",
         gap = "4px",
         margin_left = "8px",
         max_width = "260px",
         overflow_x = "auto",
         overflow_y = "hidden",
         flex_shrink = "0")
  r.appendChild(toolbar, chromeChatStrip)

  let chromeNewChatBtn = ui(r):
    tdiv(`data-chrome-chat-new` = "true",
         `role` = "button", tabindex = "0",
         title = "Create new chat",
         `aria-label` = "Create new chat",
         display = "flex", align_items = "center",
         justify_content = "center",
         width = "28px", height = "28px",
         border_radius = "6px",
         color = textMuted,
         cursor = "pointer", flex_shrink = "0",
         margin_left = "2px",
         transition = "background-color 0.12s, color 0.12s")
  let chromeNewChatIconHost = ui(r):
    tdiv(`aria-hidden` = "true",
         display = "flex", align_items = "center",
         justify_content = "center",
         width = "18px", height = "18px",
         line_height = "1",
         flex_shrink = "0")
  r.setInnerHtml(chromeNewChatIconHost, plusSvg)
  r.appendChild(chromeNewChatBtn, chromeNewChatIconHost)
  block:
    let capturedVm = vm
    let newClick = proc() =
      let id = capturedVm.createNewChat()
      capturedVm.openAiDrawer(id)
    r.addEventListener(chromeNewChatBtn, "click", newClick)
    r.addEventListener(chromeNewChatBtn, "keydown", newClick)
  r.appendChild(toolbar, chromeNewChatBtn)

  # Rebuild the robot row whenever ``chats``, ``activeChatId`` or
  # ``aiDrawerOpen`` flips.  The row is small (≤ a few dozen robots
  # in practice) so a full rebuild is cheaper than partial diffing
  # and keeps the DOM in lockstep with the VM signals.  Per-session
  # status-dot effects are registered inside the rebuild so they
  # tear down with the row.
  block:
    let capturedVm = vm
    let strip = chromeChatStrip
    # Helper that takes the session id by VALUE and returns a fresh
    # closure.  The naked ``let capturedId = sessionId`` form used
    # inline ends up sharing a single stack slot across the for-loop
    # iterations (the closure captures by reference, so every robot
    # would fire ``toggleAiDrawer`` with the LAST session id seen).
    # The helper proc bottoms out the capture so each robot's
    # listener fires with its own id.
    proc robotClickHandler(vm: EditorVM; sessionId: string): proc() =
      result = proc() =
        vm.toggleAiDrawer(sessionId)
    proc renderChromeChatStrip() =
      r.clearChildren(strip)
      let sessions = capturedVm.chats.val
      let activeId = capturedVm.activeChatId.val
      let drawerOpen = capturedVm.aiDrawerOpen.val
      for session in sessions:
        let sessionId = session.id
        let title = session.title.val
        let isActive = drawerOpen and sessionId == activeId
        var iconHost: E
        var statusDot: E
        let robotEl = ui(r):
          tdiv(`role` = "tab", tabindex = "0",
               `data-chat-tab` = sessionId,
               `aria-selected` = (if isActive: "true" else: "false"),
               title = title,
               `aria-label` = title,
               position = "relative",
               display = "flex", align_items = "center",
               justify_content = "center",
               width = "28px", height = "28px",
               border_radius = "6px",
               background_color = (if isActive: accent else: "transparent"),
               color = (if isActive: "#FFFFFF" else: textMuted),
               cursor = "pointer", flex_shrink = "0",
               transition = "background-color 0.12s, color 0.12s"):
            tdiv(ref = iconHost,
                 `aria-hidden` = "true",
                 display = "flex", align_items = "center",
                 justify_content = "center",
                 width = "18px", height = "18px",
                 line_height = "1",
                 flex_shrink = "0")
            tdiv(ref = statusDot,
                 `data-chat-status-dot` = "true",
                 position = "absolute",
                 right = "1px", bottom = "1px",
                 width = "8px", height = "8px",
                 border_radius = "4px",
                 border = "1px solid " & bgToolbar,
                 background_color = "#A0A2B0")
        r.setInnerHtml(iconHost, robotSvg)
        # Per-session click → toggle drawer.  We route through a
        # helper proc that captures the session id by VALUE so the
        # right chat fires even when the strip is rebuilt under us
        # (the prior plain ``let capturedId = sessionId`` form shared
        # a single stack slot across iterations and stranded every
        # robot with the LAST session id seen).
        let robotClick = robotClickHandler(capturedVm, sessionId)
        r.addEventListener(robotEl, "click", robotClick)
        r.addEventListener(robotEl, "keydown", robotClick)
        # Status dot reactive on the per-session ``sessionStatus``.
        block:
          let dot = statusDot
          let chatVm = session.vm
          createRenderEffect proc() =
            let state = chatVm.sessionStatus.val
            let color = case state
              of asIdle: "#A0A2B0"
              of asLoading: "#F59E0B"
              of asReady: "#22C55E"
              of asError: "#EF4444"
            r.setStyle(dot, "background-color", color)
            r.setAttribute(dot, "data-chat-status",
              case state
              of asIdle: "idle"
              of asLoading: "loading"
              of asReady: "ready"
              of asError: "error")
        r.appendChild(strip, robotEl)
    createRenderEffect proc() =
      discard capturedVm.chats.val
      discard capturedVm.activeChatId.val
      discard capturedVm.aiDrawerOpen.val
      renderChromeChatStrip()

  toolbar

proc renderAiDrawer*[R, E](r: R; vm: EditorVM): E =
  ## Phase F — AI assistant slide-out drawer.
  ##
  ## A right-edge fixed-positioned panel that mounts
  ## ``renderChatPanel`` for the currently-active chat.  Width tracks
  ## ``vm.rightPanelWidth`` (the same signal the inspector uses) so
  ## both rails read as a single column even though they are
  ## independently mounted.  Visibility is driven by
  ## ``vm.aiDrawerOpen``: when false the root is ``display: none`` so
  ## the editor surface stays focused on the inspector.
  ##
  ## Z-index 80 layers the drawer above the inspector (z-index 30 on
  ## its resize handle) and below the command palette (z-index 50 +
  ## ``position: fixed``; effectively a modal layer).  The drawer is
  ## itself ``position: fixed`` with ``top: 44px`` so the chrome bar
  ## stays reachable while the drawer is open.
  var closeBtn: E
  var body: E
  result = ui(r):
    tdiv(`data-ai-drawer` = "true",
          `data-ai-drawer-open` = "false",
          position = "fixed",
          top = "44px", right = "0", bottom = "0",
          display = "none",
          flex_direction = "column",
          background_color = bgSidebar,
          border_left = "1px solid " & borderStrong,
          box_shadow = "-12px 0 32px -16px rgba(0, 0, 0, 0.45)",
          z_index = "80",
          width = "320px", min_width = "200px", max_width = "420px",
          overflow = "hidden"):
      tdiv(`data-ai-drawer-header` = "true",
           display = "flex", align_items = "center",
           justify_content = "flex-end",
           min_height = "32px",
           padding_top = "6px", padding_right = "8px",
           padding_bottom = "6px", padding_left = "12px",
           border_bottom = "1px solid " & border):
        tdiv(ref = closeBtn,
             `data-ai-drawer-close` = "true",
             `role` = "button", tabindex = "0",
             title = "Close AI drawer",
             `aria-label` = "Close AI drawer",
             display = "flex", align_items = "center",
             justify_content = "center",
             width = "24px", height = "24px",
             border_radius = "4px",
             color = textMuted,
             font_size = "14px", line_height = "1",
             cursor = "pointer"):
          text "\xE2\x9C\x95"  # ✕
      tdiv(ref = body,
           `data-ai-drawer-body` = "true",
           display = "flex", flex_direction = "column",
           flex = "1", min_height = "0", min_width = "0",
           overflow_x = "hidden")

  let drawer = result
  let bodyEl = body
  # Mount the chat panel inside the drawer body.  ``renderChatPanel``
  # reads ``vm.activeChat()`` so it automatically reflects the chat
  # the robot row last activated; no internal tab strip is rendered.
  let chatPanel = renderChatPanel[R, E](r, vm)
  r.appendChild(bodyEl, chatPanel)

  # Close button + ESC handling + click-outside handling are all
  # wired below.  ``aiDrawerOpen`` is the load-bearing signal.
  let capturedVm = vm
  r.addEventListener(closeBtn, "click", proc() =
    capturedVm.closeAiDrawer())
  r.addEventListener(closeBtn, "keydown", proc() =
    capturedVm.closeAiDrawer())

  # Width binding — mirror the inspector's ``bindRightPanelWidth`` so
  # the drawer and the inspector occupy the same horizontal slot
  # (the drawer overlays the inspector when open).
  block:
    let drawerCapture = drawer
    createRenderEffect proc() =
      let width = $capturedVm.rightPanelWidth.val & "px"
      r.setStyle(drawerCapture, "width", width)

  # Visibility binding.
  block:
    let drawerCapture = drawer
    createRenderEffect proc() =
      let open = capturedVm.aiDrawerOpen.val
      r.setStyle(drawerCapture, "display", if open: "flex" else: "none")
      r.setAttribute(drawerCapture, "data-ai-drawer-open",
        if open: "true" else: "false")

  when defined(js):
    let drawerJs = drawer
    {.emit: ["""
      (function (drawer) {
        if (!drawer || drawer.__isonimAiDrawerReady) return;
        drawer.__isonimAiDrawerReady = true;
        // ESC closes the drawer when it's open.
        document.addEventListener('keydown', function (event) {
          if (event.key !== 'Escape') return;
          if (drawer.getAttribute('data-ai-drawer-open') !== 'true') return;
          var btn = drawer.querySelector('[data-ai-drawer-close="true"]');
          if (btn) btn.click();
        });
        // Click-outside closes the drawer.  Robot buttons in the
        // chrome bar are excluded so a click on a robot can still
        // switch chats / toggle the drawer without an immediate
        // close fighting the toggle.
        document.addEventListener('mousedown', function (event) {
          if (drawer.getAttribute('data-ai-drawer-open') !== 'true') return;
          var target = event.target;
          if (!target) return;
          if (drawer.contains(target)) return;
          if (target.closest && target.closest('[data-chat-tab]')) return;
          if (target.closest && target.closest('[data-chrome-chat-new="true"]')) return;
          var btn = drawer.querySelector('[data-ai-drawer-close="true"]');
          if (btn) btn.click();
        });
      })(""", drawerJs, """);
    """].}

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
    tdiv(`data-shell-row` = "true",
          display = "flex", flex = "1", min_height = "0",
          width = "100%", overflow = "hidden")

  let sidebarEl = renderSidebar[R, E](r, vm)
  let storyboardEl = renderStoryboardCanvas[R, E](r, vm)
  let componentDetailEl = renderComponentDetail[R, E](r, vm)
  let componentEditEl = renderComponentEditView[R, E](r, vm)
  let pagePreviewEl = renderPagePreview[R, E](r, vm)
  let foundationsEl = renderFoundationsPage[R, E](r, vm)
  let vectorEditorEl = renderVectorEditor[R, E](r, vm)
  # Right sidebar — a SINGLE tabbed panel hosting both the manual
  # property inspector and the AI assistant chat. Per the user's
  # restructure, the AI assistant is no longer a separate column; it
  # is a tab inside the right sidebar so logically related editing
  # affordances (manual property edits + AI-driven changes) live
  # together. The ``data-test-id="property-panel"`` attribute is
  # stamped inside ``renderInspectorPanel`` on the sidebar root so
  # the existing e2e tests still resolve it.
  let inspectorEl = renderInspectorPanel[R, E](r, vm)

  # Center column wraps the shared preview chrome bar + the view stack
  # so the toolbar sits above every view. Replaces the previous
  # per-view top toolbars + the legacy global title bar.
  let chromeBarEl = renderPreviewChromeBar[R, E](r, vm)
  let centerColumn = ui(r):
    tdiv(display = "flex", flex_direction = "column",
          flex = "1", min_width = "0", min_height = "0",
          # AIVS-NSO: center column is ``position: relative`` so the
          # "select an item" overlay (mounted below) can absolute-
          # position itself across the view stack + chrome bar without
          # spilling into the sidebar / chat column.  The overlay is
          # the load-bearing carrier for the UX-correctness contract:
          # when a mode requires a selected story, the centre column
          # grays out and surfaces an explanatory message — but the AI
          # sidebar stays mounted so the user can keep talking to the
          # assistant.
          position = "relative",
          `data-preview-center-column` = "true")
  let viewStack = ui(r):
    tdiv(display = "flex", flex = "1", min_width = "0", min_height = "0",
          flex_direction = "column",
          `data-preview-view-stack` = "true")

  # TBAR-M4: Spec-pane mount. Renders inside the center column when
  # ``surfaceSig.val == sSpec``. The body is the active brief's
  # markdown rendered through the vendored TipTap editor (read-only).
  # When the vendor UMD failed to load the spec_pane mount falls back
  # to a setTextContent of the raw markdown so the user still sees the
  # brief body (rather than a hard crash) — see ``spec_pane.nim``.
  #
  # The outer ``specPaneEl`` keeps the TBAR-M3 ``data-test-id``
  # selector + the ``display: none/flex`` reactive toggle below so the
  # surface-switch e2e test contract is preserved.
  let specPaneEl = ui(r):
    tdiv(`data-preview-spec-pane` = "true",
         `data-test-id` = "spec-pane",
         display = "none", flex = "1", min_width = "0", min_height = "0",
         flex_direction = "column",
         background_color = bgPreview)
  let specPaneVm = spec_pane_view.createSpecPaneVM("")
  # TBAR-M5: wire the Save/Cancel callbacks the mount delivers. Save
  # POSTs the current markdown to /api/design-review/save-brief via
  # the editor's HTTP client (the daemon writes to disk + re-parses
  # the brief). Cancel reverts to the last-saved body.
  let designReviewState = ensureDesignReviewState(vm)
  let specPaneCallbacks = SpecPaneMountCallbacks(
    onSaveRequested: proc(markdown: string) {.closure.} =
      let bid = designReviewState.briefId.val
      let client = designReviewState.httpClient
      if bid.len == 0 or client == nil:
        return
      let saver: SaveBriefHttpProc = proc(briefId, body: string;
                                          cb: proc(success: bool;
                                                   payload: string)) =
        editor_http_client.saveBrief(client, briefId, body, proc(res: HttpCallbackResult) =
          cb(res.kind == hcOk, res.body))
      saveEdits(specPaneVm, bid, markdown, saver, proc(success: bool) =
        if success:
          # Keep the shell's editMode triplet in sync with the
          # spec-pane mode so the user sees the View chip light up
          # after a successful save.  The shell's mode-mirror effect
          # would otherwise reset the pane mode back to ``spmEdit``
          # on the next pass (it tracks ``editMode``, not
          # ``spmMode``).
          vm.setEditMode(emView)
          specPaneVm.setMode(spmView)),
    onCancelRequested: proc() {.closure.} =
      # Same direction as the save success path: tell the shell's
      # ``editMode`` triplet to flip to View so the mirror effect
      # doesn't snap the pane back to Edit on the next tick.
      vm.setEditMode(emView)
      cancelEdits(specPaneVm),
  )
  spec_pane_view.mountSpecPane[R, E](r, specPaneEl, specPaneVm, specPaneCallbacks)
  # Reactively feed the active brief's markdown into the spec pane VM.
  # ``resolveBriefId`` follows the active story + selected backend.
  # We prepend the brief's ``title`` as an H1 so the rendered TipTap
  # surface carries the canonical title heading even when the brief
  # body itself only starts at H2 (the render briefs follow that
  # pattern; the title field carries the H1 text).
  block:
    let capturedVm = vm
    var lastBody = ""
    var lastBriefId = ""
    createRenderEffect proc() =
      let story = capturedVm.selectedStory.val
      let backend = capturedVm.platform.val
      let bid = design_review_mount_view.resolveBriefId(story, backend)
      var body = ""
      if bid.len > 0:
        let idx = builtInBriefIndex()
        if idx != nil and bid in idx.byBriefId:
          let b = idx.byBriefId[bid]
          if b.title.len > 0:
            body.add "# "
            body.add b.title
            body.add "\n\n"
          body.add b.bodyMarkdown
      if body.len == 0:
        body = "# Spec\n\nNo brief available for the selected story."
      # TBAR-M5: a brief-body change from outside (e.g. story switch)
      # is a fresh saved-state baseline. Use markSaved so ``dirty``
      # stays false and any prior unsaved edits are discarded.
      #
      # Guard against re-firing on identical inputs: this effect
      # tracks ``selectedStory`` + ``platform`` (both reactive); if
      # neither the resolved briefId nor the assembled body actually
      # changed across runs, suppress the ``markSaved`` write so an
      # in-progress Edit-mode session doesn't get its ``dirty`` flag
      # silently reset by a redundant re-evaluation.
      if bid == lastBriefId and body == lastBody:
        return
      lastBody = body
      lastBriefId = bid
      specPaneVm.markSaved(body)

  # TBAR-M5: when surface is Spec, mirror the View/Comment/Edit
  # mode triplet onto the spec pane's mode signal. In Preview mode
  # the triplet keeps its existing meaning (preview chrome); the
  # spec pane reacts only when surface == sSpec.
  block:
    let capturedVm = vm
    let capturedSpecVm = specPaneVm
    createRenderEffect proc() =
      if capturedVm.surfaceSig.val != sSpec:
        return
      let em = capturedVm.editMode.val
      let target =
        case em
        of emView: spmView
        of emComment: spmComment
        of emEdit: spmEdit
      if capturedSpecVm.mode.val != target:
        capturedSpecVm.setMode(target)

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
    let surface = vm.surfaceSig.val
    let preview = surface == sPreview
    r.setStyle(storyboardEl, "display", if preview and view ==
        evStoryboard: "flex" else: "none")
    r.setStyle(componentDetailEl, "display", if preview and view ==
        evComponentDetail: "flex" else: "none")
    r.setStyle(componentEditEl, "display", if preview and view ==
        evComponentEdit: "flex" else: "none")
    r.setStyle(pagePreviewEl, "display", if preview and view ==
        evPagePreview: "flex" else: "none")
    r.setStyle(foundationsEl, "display", if preview and view ==
        evFoundationsPage: "flex" else: "none")
    r.setStyle(vectorEditorEl, "display", if preview and view ==
        evVectorEditor: "flex" else: "none")
    r.setStyle(sidebarEl, "display", if panels.sidebar and view !=
        evVectorEditor: "flex" else: "none")
    # Vector editor takes over the whole center column; hide the
    # shared chrome bar so the vector-editor toolbar isn't doubled up.
    r.setStyle(chromeBarEl, "display",
      if view == evVectorEditor: "none" else: "flex")
    # TBAR-M3: spec-pane swaps in when surface is sSpec.
    r.setStyle(specPaneEl, "display",
      if not preview: "flex" else: "none")
    # CHRM-M3 Wave A: the viewStack (which hosts the per-preview
    # surfaces — storyboard, component detail, page preview, etc.) is
    # itself a flex=1 child of centerColumn. When surface flips to
    # sSpec every CHILD of viewStack is set to display:none above —
    # but the viewStack ITSELF stays display:flex and keeps its
    # flex=1, so it splits the centre column's vertical budget evenly
    # with specPaneEl. Result: the spec pane only gets ~half of the
    # available height (rootClientHeight ≈ 505 px on a 1080 viewport),
    # the brief content scrolls inside a too-short pane, and the
    # CHRM-M4 toolbar sits halfway down the visible column. Collapse
    # the empty viewStack when surface is Spec so specPaneEl gets the
    # full flex:1 budget. This is a single setStyle inside the
    # existing createRenderEffect — no new effects introduced, no
    # setStyle outside a render effect.
    r.setStyle(viewStack, "display",
      if preview: "flex" else: "none")

  r.appendChild(viewStack, storyboardEl)
  r.appendChild(viewStack, componentDetailEl)
  r.appendChild(viewStack, componentEditEl)
  r.appendChild(viewStack, pagePreviewEl)
  r.appendChild(viewStack, foundationsEl)
  r.appendChild(viewStack, vectorEditorEl)
  r.appendChild(centerColumn, chromeBarEl)

  # CHRM-M2: the legacy in-pane Preview/Brief tab strip is gone. The
  # chrome-bar Surface switch covers the Preview ⇄ Spec axis and the
  # TipTap-backed spec pane renders the brief body; the only
  # load-bearing affordance the strip carried — the
  # "Review this preview" button — is now mounted in the chrome bar's
  # trailing-edge slot before the 🕘 history button.
  r.appendChild(centerColumn, viewStack)
  # TBAR-M3: spec-pane placeholder sits inside the center column
  # alongside the view stack — display swaps between them via the
  # reactive effect above.
  r.appendChild(centerColumn, specPaneEl)

  # REV-M8 — mount the gallery overlay host below the view stack so the
  # 🕘 button can flip it open without disturbing the chrome bar or the
  # preview surface above it.  The host is data-hidden until both
  # ``briefHasHistory`` and ``galleryHostState == ghsOpen`` are true.
  discard design_review_mount_view.mountGalleryHostForEditor[R, E](
    r, centerColumn, vm)

  # AIVS-NSO — "Select an item to edit its properties" overlay.
  #
  # Several centre-column surfaces are meaningless without a selected
  # story: the component detail / component edit / page preview /
  # foundations views all depend on ``vm.selectedStory`` to know what
  # to render, and the Spec pane (View / Comment / Edit) needs a
  # brief to display.  Storyboard is the exception — it shows the
  # whole flow graph regardless of selection — and so is the vector
  # editor, which only opens via an explicit ``openVectorEditor``
  # affordance.
  #
  # The overlay sits absolute-positioned over the centre column, gated
  # by a single ``createRenderEffect`` that observes ``selectedStory``,
  # ``surfaceSig``, ``editMode``, and ``activeView``.  Its message
  # adapts to the current mode per the user's spec:
  #   * Spec View / Comment / Edit, no story: "Select an item to view
  #     its specification."
  #   * Preview View / Comment / Edit (Component/Page/Foundation
  #     views) without a story: "Select an item to edit its
  #     properties."
  let overlayEl = ui(r):
    tdiv(`data-no-story-overlay` = "true",
         `data-test-id` = "no-story-overlay",
         position = "absolute", top = "0", left = "0",
         right = "0", bottom = "0",
         display = "none",
         align_items = "center", justify_content = "center",
         flex_direction = "column",
         gap = "8px", padding = "32px",
         text_align = "center",
         background_color = "rgba(11, 18, 32, 0.72)",
         z_index = "20",
         pointer_events = "auto")
  var overlayHeadingEl: E
  var overlaySubtitleEl: E
  let overlayHeading = ui(r):
    span(ref = overlayHeadingEl,
         font_size = "16px", font_weight = "600",
         color = "#E5E7EB",
         `data-no-story-overlay-heading` = "true"):
      text "Select an item to edit its properties"
  let overlaySubtitle = ui(r):
    span(ref = overlaySubtitleEl,
         font_size = "13px", font_weight = "400",
         color = "#A0A2B0",
         line_height = "1.5",
         max_width = "480px",
         `data-no-story-overlay-subtitle` = "true"):
      text "Pick a Page, Component, or Foundation from the sidebar — the editor surface activates once an item is selected."
  r.appendChild(overlayEl, overlayHeading)
  r.appendChild(overlayEl, overlaySubtitle)
  r.appendChild(centerColumn, overlayEl)

  block:
    let capturedVm = vm
    let captHeading = overlayHeadingEl
    let captSubtitle = overlaySubtitleEl
    # Set backdrop-filter via setStyle so vendor-prefixed values
    # survive the DSL's CSS-property whitelist (which excludes
    # ``backdrop-filter`` / ``-webkit-backdrop-filter`` by default).
    # The setStyle sits inside this createRenderEffect to honour the
    # "no setStyle outside an effect" rule even though the value is
    # static.
    createRenderEffect proc() =
      r.setStyle(overlayEl, "backdrop-filter", "blur(2px)")
      r.setStyle(overlayEl, "-webkit-backdrop-filter", "blur(2px)")
    createRenderEffect proc() =
      let story = capturedVm.selectedStory.val
      let view = capturedVm.activeView.val
      let surface = capturedVm.surfaceSig.val
      let em = capturedVm.editMode.val
      # ``vector editor`` is never reached without an explicit
      # ``openVectorEditor`` affordance so it always has a target;
      # ``storyboard`` renders the whole flow graph and is the
      # default landing surface — both are exempt from the no-story
      # overlay.  The remaining centre-column surfaces all hinge on
      # ``vm.selectedStory``.
      let surfaceNeedsStory =
        surface == sSpec or
        view in {evComponentDetail, evComponentEdit,
                 evPagePreview, evFoundationsPage}
      let noStory = story.name.len == 0
      let want = surfaceNeedsStory and noStory
      r.setStyle(overlayEl, "display", if want: "flex" else: "none")
      if want:
        # Mode-specific copy.  In Spec surface the call-to-action is
        # to view / comment / edit the brief; in Preview surface the
        # message stays consistent with the user's "select an item to
        # edit its properties" suggestion.
        if surface == sSpec:
          let heading =
            case em
            of emView: "Select an item to view its specification"
            of emComment: "Select an item to comment on its specification"
            of emEdit: "Select an item to edit its specification"
          let subtitle =
            "Pick a Page, Component, or Foundation from the sidebar — " &
            "the spec pane loads the matching brief once an item is " &
            "selected.  Meanwhile the AI Assistant on the right " &
            "remains available for general questions."
          r.setTextContent(captHeading, heading)
          r.setTextContent(captSubtitle, subtitle)
        else:
          let heading =
            case em
            of emView: "Select an item to view its preview"
            of emComment: "Select an item to comment on its preview"
            of emEdit: "Select an item to edit its properties"
          let subtitle =
            "Pick a Page, Component, or Foundation from the sidebar — " &
            "the editor surface activates once an item is selected. " &
            "Meanwhile the AI Assistant on the right remains " &
            "available for general questions."
          r.setTextContent(captHeading, heading)
          r.setTextContent(captSubtitle, subtitle)

  # Mount order is the on-screen order (flex row, left to right):
  #   [sidebar | center column (chrome bar + view stack) | tabbed right sidebar]
  r.appendChild(shell, sidebarEl)
  r.appendChild(shell, centerColumn)
  # Right sidebar visibility contract:
  # The right sidebar is a SINGLE tabbed panel that hosts both the
  # manual property inspector ("Manual" tab) and the AI assistant
  # chat ("Assistant" tab). The user toggles between the two at the
  # top of the sidebar — logically the sidebar is "the editing
  # surface": you can edit by hand (Manual) or by messaging the
  # assistant (Assistant). Both tabs are ALWAYS available regardless
  # of surface (Preview/Spec), mode (View/Comment/Edit), or whether a
  # story is selected; this preserves the AIVS-NSO invariant that the
  # AI Assistant is the user's single point of contact and remains
  # reachable across every workspace state. The only carve-out is the
  # ``panels.inspector`` toggle — the status-bar Toggle inspector
  # button still collapses the right rail entirely (re-opening
  # restores it). The Spec-comment one-shot signal still pulls the
  # sidebar back into view when a brief comment is submitted.
  let chatOpenedForSpecComment = createSignal(false)
  block:
    let capturedVm = vm
    let capturedChatFlag = chatOpenedForSpecComment
    var mounted = false
    proc shouldMount(): bool =
      let panels = capturedVm.panels.val
      # Keep the spec-comment one-shot signal observed so the existing
      # TBAR-M6 wiring still drains it on surface flips (downstream
      # code may inspect it); the panel is always wanted when
      # ``panels.inspector`` is true regardless of its value.
      discard capturedChatFlag.val
      panels.inspector
    createRenderEffect proc() =
      let want = shouldMount()
      if want and not mounted:
        r.appendChild(shell, inspectorEl)
        mounted = true
      elif not want and mounted:
        r.removeChild(shell, inspectorEl)
        mounted = false
  # TBAR-M6: mount the Spec Comment popover at shellRoot so its
  # absolute-positioned overlay layers above the spec pane without
  # parent clipping.  Submission routes through
  # ``submitSpecComment`` (which sets the chat input + dispatches
  # ``sendAgentPrompt``) and flips ``chatOpenedForSpecComment`` so
  # the predicate above pulls the chat panel into the shell row.
  let specCommentSubmit: CommentSubmitProc =
    proc(draft: CommentDraft;
         cb: proc(success: bool; reason: string)) {.closure.} =
      let bid = designReviewState.briefId.val
      spec_comment_chat_view.submitSpecComment(vm, bid, draft,
        proc(success: bool; reason: string) =
          if success:
            chatOpenedForSpecComment.val = true
            # Phase F: open the AI drawer to the currently-active
            # chat so the comment-to-chat handoff surfaces the
            # transcript the spec_comment_chat_view just routed the
            # comment into.  Empty string lets ``openAiDrawer``
            # preserve the existing active chat.
            vm.openAiDrawer(vm.activeChatId.val)
          if cb != nil:
            cb(success, reason))
  spec_comment_popover_view.mountCommentPopover[R, E](
    r, shellRoot, specPaneVm.commentPopover, specCommentSubmit)

  # Phase E.3 + E.4 (2026-05-28): variable picker + inline editor.
  # Both are mounted at the shell root so their absolute-positioned
  # popovers layer above the inspector + preview without parent
  # clipping. A single instance of each is reused across all property
  # rows (the row's bind-request callback flips ``open`` on the
  # picker state; the picker's per-row Edit affordance opens the
  # inline editor through ``onVariableEdit``).
  #
  # Phase G will wire the property rows' ``onBindRequest`` callback
  # to ``openVariablePicker(state, anchorEl, propertyKey)`` and the
  # chip's ``onVariableNameClick`` to
  # ``openVariableInlineEditor(vm, inlineState, anchorEl, key)``.
  # The states live here so they are reachable from every consumer
  # without piling extra plumbing onto each property row.
  let variablePickerState = editor_widgets.createVariablePickerState()
  let variableInlineEditorState =
    editor_widgets.createVariableInlineEditorState()
  # Wire the picker's per-row Edit affordance into the inline editor.
  # The picker's row knows the variable key; the inline editor opens
  # anchored to the picker by inheriting the picker's anchor rect.
  variablePickerState.onVariableEdit.val =
    proc(variableKey: string) {.closure.} =
      let rect = variablePickerState.anchorRect.val
      openVariableInlineEditorWithRect(vm, variableInlineEditorState,
        variableKey, rect.x, rect.y, rect.w, rect.h)
  discard editor_widgets.mountVariablePicker[R, E](r, shellRoot, vm,
    variablePickerState)
  discard editor_widgets.mountVariableInlineEditor[R, E](r, shellRoot, vm,
    variableInlineEditorState)

  r.appendChild(shellRoot, shell)
  # Phase F — AI assistant slide-out drawer.  Mounted at the shell
  # root (NOT inside the editor row) so its ``position: fixed`` slot
  # overlays the inspector without disturbing flex layout.  The
  # drawer body hosts ``renderChatPanel`` for the active chat.
  r.appendChild(shellRoot, renderAiDrawer[R, E](r, vm))
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
