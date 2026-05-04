## IsoNim Editor — all ViewModel types.
##
## Pure state machines using IsoNim reactive primitives.
## No CSS, no colors, no rendering — only signals, memos, and enums.
## Created via withViewModel inside createRoot.

import std/strutils
import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim/editor/types

export types

# ===========================================================================
# All ViewModel types (single type block for forward references)
# ===========================================================================

type
  SidebarVM* = ref object of ViewModel
    groups*: Signal[seq[StoryGroup]]
    sections*: Signal[SidebarSectionExpansion]
    searchFilter*: Signal[string]
    filteredItems*: Memo[seq[StoryGroup]]

  StoryboardVM* = ref object of ViewModel
    ## Canvas showing screen thumbnails connected by flow arrows.
    canvasItems*: Signal[seq[CanvasItem]]
    connections*: Signal[seq[FlowConnection]]
    zoom*: Signal[float]        ## Canvas zoom level (0.25..4.0)
    panX*, panY*: Signal[float] ## Canvas pan offset
    selectedItem*: Signal[int]  ## Index into canvasItems (-1 = none)
    hoveredItem*: Signal[int]

  InspectorVM* = ref object of ViewModel
    selectedElement*: Signal[ElementRef]
    activeSection*: Signal[InspectorSection]
    editDiagnostics*: Signal[seq[PropertyEditDiagnostic]]
    pendingSourceEdits*: Signal[seq[SourceEditPlan]]
    hasElement*: Memo[bool]
    properties*: Memo[seq[PropertyInfo]]
    ## CSS-specific state
    displayMode*: Signal[DisplayMode]
    flexDirection*: Signal[FlexDirection]

  VectorEditorVM* = ref object of ViewModel
    ## Embedded vector editor for SVG symbols.
    activeTool*: Signal[VectorTool]
    symbols*: Signal[seq[VectorSymbol]]
    searchFilter*: Signal[string]
    filteredSymbols*: Memo[seq[VectorSymbol]]
    selectedSymbol*: Signal[int] ## Index into symbols (-1 = none)
    isEditing*: Memo[bool]
    zoom*: Signal[float]
    showGrid*: Signal[bool]
    snapToGrid*: Signal[bool]
    gridSize*: Signal[float]

  AgentChatVM* = ref object of ViewModel
    messages*: Signal[seq[ChatMessage]]
    sessionStatus*: Signal[AsyncState]
    accumulatedEdits*: Signal[seq[EditRecord]]
    inputText*: Signal[string]
    connectionState*: Signal[string]
    planEntries*: Signal[seq[string]]
    toolCalls*: Signal[seq[string]]
    stopReason*: Signal[string]
    messageCount*: Memo[int]
    promptAdapter*: AgentPromptAdapter
    cancelAdapter*: AgentCancelAdapter

  ReviewResultsVM* = ref object of ViewModel
    violations*: Signal[seq[Violation]]
    errorCount*: Memo[int]
    warningCount*: Memo[int]
    hasIssues*: Memo[bool]

  ProjectPreviewVM* = ref object of ViewModel
    hook*: ProjectPreviewHook
    current*: Memo[ProjectPreview]

  FlowPlayerVM* = ref object of ViewModel
    steps*: Signal[seq[FlowStep]]
    currentStep*: Signal[int]
    playState*: Signal[PlayState]
    totalSteps*: Memo[int]
    isFirstStep*: Memo[bool]
    isLastStep*: Memo[bool]
    currentAction*: Memo[string]

  EditorVM* = ref object of ViewModel
    activeView*: Signal[EditorView]
    selectedStory*: Signal[StoryRef]
    editMode*: Signal[EditMode]
    panels*: Signal[PanelVisibility]
    platform*: Signal[Platform]
    viewport*: Signal[PreviewViewport]
    workspacePermissions*: Signal[EditorWorkspacePermissions]
    sourceAdapterReady*: Signal[bool]
    commandStates*: Signal[seq[EditorCommandState]]
    sidebar*: SidebarVM
    storyboard*: StoryboardVM
    inspector*: InspectorVM
    vectorEditor*: VectorEditorVM
    chat*: AgentChatVM
    review*: ReviewResultsVM
    preview*: ProjectPreviewVM
    flowPlayer*: FlowPlayerVM
    hasSelection*: Memo[bool]

func isEmptyStory(story: StoryRef): bool =
  story.group.len == 0 and story.name.len == 0

func defaultWorkspacePermissions*(): EditorWorkspacePermissions =
  EditorWorkspacePermissions(
    readSource: true,
    writeSource: false,
    createStory: false,
    createVariant: false,
    duplicate: false,
    delete: false)

func commandLabel*(kind: EditorCommandKind): string =
  case kind
  of eckEdit: "Edit"
  of eckInspect: "Inspect"
  of eckApply: "Apply"
  of eckRevert: "Revert"
  of eckSave: "Save"
  of eckDiscard: "Discard"
  of eckDuplicate: "Duplicate"
  of eckDelete: "Delete"
  of eckCreateVariant: "Create variant"
  of eckCreateStory: "Create story"
  of eckOpenSource: "Open source"

func allEditorCommandKinds*(): seq[EditorCommandKind] =
  @[
    eckEdit,
    eckInspect,
    eckApply,
    eckRevert,
    eckSave,
    eckDiscard,
    eckDuplicate,
    eckDelete,
    eckCreateVariant,
    eckCreateStory,
    eckOpenSource
  ]

func sameStory(a, b: StoryRef): bool =
  a.group == b.group and a.name == b.name and a.kind == b.kind

func viewForStory(story: StoryRef): EditorView =
  case story.kind
  of skFlow:
    evPagePreview
  of skPage:
    evPagePreview
  of skComponent, skPattern, skFoundation, skGuideline:
    evComponentDetail

func platformForViewport*(viewport: PreviewViewport): Platform =
  case viewport
  of pvDesktop:
    pfWeb
  of pvTablet:
    pfIOS
  of pvMobile:
    pfAndroid

func viewportForPlatform*(platform: Platform): PreviewViewport =
  case platform
  of pfWeb:
    pvDesktop
  of pfIOS:
    pvTablet
  of pfAndroid:
    pvMobile

func previewViewportLabel*(viewport: PreviewViewport): string =
  case viewport
  of pvDesktop:
    "Desktop"
  of pvTablet:
    "Tablet"
  of pvMobile:
    "Mobile"

func previewViewportWidth*(viewport: PreviewViewport): int =
  case viewport
  of pvDesktop:
    1280
  of pvTablet:
    834
  of pvMobile:
    390

func previewViewportHeight*(viewport: PreviewViewport): int =
  case viewport
  of pvDesktop:
    900
  of pvTablet:
    1112
  of pvMobile:
    844

func isShared(prop: PropertyInfo): bool =
  prop.sharedCount > 0

func isViewModelSource(file: string): bool =
  "viewmodel" in file.toLowerAscii()

func isTokenDrift(prop: PropertyInfo; newValue: string): bool =
  prop.origin == poThemeToken and newValue.strip.startsWith("#")

func isEmptyA11yEdit(prop: PropertyInfo; newValue: string): bool =
  (prop.name == "aria-label" or prop.name == "alt") and newValue.strip.len == 0

func diagnostic(kind: PropertyEditDiagnosticKind; prop: PropertyInfo;
    message: string): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name)

func diagnostic(kind: PropertyEditDiagnosticKind; element: ElementRef;
    property, message: string): PropertyEditDiagnostic =
  PropertyEditDiagnostic(
    kind: kind,
    message: message,
    file: element.sourceFile,
    line: element.sourceLine,
    property: property)

func editRecord(prop: PropertyInfo; request: PropertyEditRequest): EditRecord =
  EditRecord(
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name,
    oldValue: prop.value,
    newValue: request.newValue,
    origin: prop.origin,
    originDetail: prop.originDetail,
    scope: request.scope,
    isShared: request.scope == pesShared,
    editOrigin: request.origin)

func sourcePlan(prop: PropertyInfo; request: PropertyEditRequest): SourceEditPlan =
  SourceEditPlan(
    file: prop.sourceFile,
    line: prop.sourceLine,
    property: prop.name,
    oldValue: prop.value,
    newValue: request.newValue,
    originDetail: prop.originDetail,
    scope: request.scope)

func withStatus(status: PropertyEditStatus;
    diagnostics: seq[PropertyEditDiagnostic] = @[]): PropertyEditResult =
  PropertyEditResult(status: status, diagnostics: diagnostics)

func emptyPreview(story: StoryRef): ProjectPreview =
  let status =
    if story.isEmptyStory: ppsMissingSelection else: ppsUnsupportedStory
  ProjectPreview(status: status, story: story)

proc defaultPreviewHook*(story: StoryRef;
                        platform: Platform): ProjectPreview =
  emptyPreview(story)

proc findCanvasItem(vm: EditorVM; story: StoryRef): int =
  result = -1
  let items = vm.storyboard.canvasItems.val
  for i, item in items:
    if sameStory(item.storyRef, story):
      return i

proc hasStory(vm: EditorVM; story: StoryRef): bool =
  if isEmptyStory(story):
    return false

  for group in vm.sidebar.groups.val:
    for item in group.items:
      if item.group == story.group and item.name == story.name and
          item.kind == story.kind:
        return true

proc syncFlowStep(vm: EditorVM; story: StoryRef) =
  let steps = vm.flowPlayer.steps.val
  for i, step in steps:
    if sameStory(step.screenRef, story):
      vm.flowPlayer.currentStep.val = i
      return

proc selectFlowStep*(editor: EditorVM; index: int): bool {.discardable.} =
  ## Select a flow step and synchronize the story, canvas item, and action.
  let steps = editor.flowPlayer.steps.val
  if index < 0 or index >= steps.len:
    return false

  let story = steps[index].screenRef
  if not editor.hasStory(story):
    return false

  editor.flowPlayer.currentStep.val = index
  editor.selectedStory.val = story
  editor.activeView.val = evStoryboard
  editor.storyboard.selectedItem.val = editor.findCanvasItem(story)
  true

# ===========================================================================
# EditorVM headless actions
# ===========================================================================

proc selectStory*(editor: EditorVM; story: StoryRef): bool {.discardable.} =
  ## Select a story and move the shell to the view that owns that story kind.
  if not editor.hasStory(story):
    return false

  editor.selectedStory.val = story
  editor.activeView.val = viewForStory(story)
  editor.storyboard.selectedItem.val = editor.findCanvasItem(story)
  editor.syncFlowStep(story)
  true

proc selectCanvasItem*(editor: EditorVM; index: int): bool {.discardable.} =
  ## Select a storyboard canvas item by index. Invalid indices are no-ops.
  let items = editor.storyboard.canvasItems.val
  if index < 0 or index >= items.len:
    return false

  if not editor.hasStory(items[index].storyRef):
    return false

  editor.storyboard.selectedItem.val = index
  discard editor.selectStory(items[index].storyRef)
  editor.storyboard.selectedItem.val = index
  if items[index].storyRef.kind == skFlow:
    editor.activeView.val = evStoryboard
  true

proc nextFlowStep*(editor: EditorVM): bool {.discardable.} =
  ## Advance the flow through the editor so selection stays synchronized.
  let total = editor.flowPlayer.totalSteps.val
  if total == 0:
    return false
  let nextIndex =
    if editor.flowPlayer.currentStep.val + 1 >= total: 0
    else: editor.flowPlayer.currentStep.val + 1
  editor.selectFlowStep(nextIndex)

proc prevFlowStep*(editor: EditorVM): bool {.discardable.} =
  ## Move backward in the flow through the editor selection contract.
  let total = editor.flowPlayer.totalSteps.val
  if total == 0:
    return false
  let prevIndex =
    if editor.flowPlayer.currentStep.val <= 0: total - 1
    else: editor.flowPlayer.currentStep.val - 1
  editor.selectFlowStep(prevIndex)

proc stopFlow*(editor: EditorVM): bool {.discardable.} =
  editor.flowPlayer.playState.val = psStopped
  editor.selectFlowStep(0)

proc setActiveView*(editor: EditorVM; view: EditorView) =
  editor.activeView.val = view

proc togglePanel*(editor: EditorVM; panel: EditorPanel) =
  let current = editor.panels.val
  case panel
  of epSidebar:
    editor.panels.val = PanelVisibility(sidebar: not current.sidebar,
                                        inspector: current.inspector)
  of epInspector:
    editor.panels.val = PanelVisibility(sidebar: current.sidebar,
                                        inspector: not current.inspector)

proc switchInspectorSection*(editor: EditorVM; section: InspectorSection) =
  editor.inspector.activeSection.val = section

proc selectInspectorElement*(editor: EditorVM;
    element: ElementRef): bool {.discardable.} =
  if element.tag.len == 0:
    editor.inspector.selectedElement.val = ElementRef()
    editor.inspector.editDiagnostics.val = @[]
    return false

  editor.inspector.selectedElement.val = element
  editor.inspector.editDiagnostics.val = @[]
  true

proc changePlatform*(editor: EditorVM; platform: Platform) =
  editor.platform.val = platform
  editor.viewport.val = viewportForPlatform(platform)

proc changeViewport*(editor: EditorVM; viewport: PreviewViewport) =
  editor.viewport.val = viewport
  editor.platform.val = platformForViewport(viewport)

proc selectVectorSymbol*(editor: EditorVM; index: int): bool {.discardable.} =
  let symbols = editor.vectorEditor.symbols.val
  if index < 0 or index >= symbols.len:
    return false

  editor.vectorEditor.selectedSymbol.val = index
  true

proc setAgentState*(editor: EditorVM; state: AsyncState) =
  editor.chat.sessionStatus.val = state

func hasSource(element: ElementRef): bool =
  element.sourceFile.len > 0 and element.sourceLine > 0

func hasSource(prop: PropertyInfo): bool =
  prop.sourceFile.len > 0 and prop.sourceLine > 0

proc selectedSourceContext(editor: EditorVM): tuple[file: string, line: int] =
  let element = editor.inspector.selectedElement.val
  if element.hasSource:
    return (element.sourceFile, element.sourceLine)
  for prop in element.properties:
    if prop.hasSource:
      return (prop.sourceFile, prop.sourceLine)
  let preview = editor.preview.current.val
  if preview.metadata.sourceFile.len > 0 and preview.metadata.sourceLine > 0:
    return (preview.metadata.sourceFile, preview.metadata.sourceLine)
  ("", 0)

func sourceChangingCommand(kind: EditorCommandKind): bool =
  kind in {eckApply, eckSave, eckDuplicate, eckDelete, eckCreateVariant,
    eckCreateStory}

proc commandRequirementFailure(editor: EditorVM;
    kind: EditorCommandKind): string =
  let story = editor.selectedStory.val
  let element = editor.inspector.selectedElement.val
  let permissions = editor.workspacePermissions.val
  let source = editor.selectedSourceContext()

  if story.isEmptyStory:
    return "Select a story before using " & commandLabel(kind) & "."

  if kind.sourceChangingCommand:
    if element.tag.len == 0:
      return "Select an element before using " & commandLabel(kind) & "."
    if source.file.len == 0:
      return "No source metadata is available for the selected element."
    if not permissions.writeSource:
      return "This workspace is read-only for source changes."
    if not editor.sourceAdapterReady.val:
      return "No source edit adapter is ready."

  case kind
  of eckEdit:
    ""
  of eckInspect:
    ""
  of eckOpenSource:
    if not permissions.readSource:
      "This workspace does not allow source reads."
    elif source.file.len == 0:
      "No source metadata is available for the current selection."
    else:
      ""
  of eckApply, eckSave:
    if editor.inspector.pendingSourceEdits.val.len == 0:
      "There are no pending source edits."
    else:
      ""
  of eckRevert, eckDiscard:
    if editor.inspector.pendingSourceEdits.val.len == 0 and
        editor.chat.accumulatedEdits.val.len == 0:
      "There are no edits to discard."
    else:
      ""
  of eckDuplicate:
    if not permissions.duplicate:
      "This workspace does not allow duplicate operations."
    else:
      ""
  of eckDelete:
    if not permissions.delete:
      "This workspace does not allow delete operations."
    else:
      ""
  of eckCreateVariant:
    if not permissions.createVariant:
      "This workspace does not allow variant creation."
    else:
      ""
  of eckCreateStory:
    if not permissions.createStory:
      "This workspace does not allow story creation."
    else:
      ""

proc evaluateCommand*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState =
  let failure = editor.commandRequirementFailure(kind)
  let source = editor.selectedSourceContext()
  EditorCommandState(
    kind: kind,
    label: commandLabel(kind),
    status: if failure.len == 0: ecsAvailable else: ecsDisabled,
    diagnostic: failure,
    sourceFile: source.file,
    sourceLine: source.line)

proc commandState*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState =
  for state in editor.commandStates.val:
    if state.kind == kind:
      return state
  editor.evaluateCommand(kind)

proc commandAvailable*(editor: EditorVM; kind: EditorCommandKind): bool =
  editor.evaluateCommand(kind).status == ecsAvailable

proc setCommandState(editor: EditorVM; state: EditorCommandState) =
  editor.commandStates.update proc(prev: seq[EditorCommandState]): seq[
      EditorCommandState] =
    result = prev
    for i in 0 ..< result.len:
      if result[i].kind == state.kind:
        result[i] = state
        return
    result.add state

proc refreshCommandStates*(editor: EditorVM) =
  var states: seq[EditorCommandState] = @[]
  for kind in allEditorCommandKinds():
    states.add editor.evaluateCommand(kind)
  editor.commandStates.val = states

proc failCommand(editor: EditorVM; kind: EditorCommandKind;
    diagnostic: string): EditorCommandState =
  let source = editor.selectedSourceContext()
  result = EditorCommandState(
    kind: kind,
    label: commandLabel(kind),
    status: ecsFailed,
    diagnostic: diagnostic,
    sourceFile: source.file,
    sourceLine: source.line)
  editor.setCommandState(result)

proc setEditMode*(editor: EditorVM; mode: EditMode) =
  editor.editMode.val = mode
  if mode == emEdit and editor.activeView.val in {evComponentDetail,
      evPagePreview}:
    editor.activeView.val = evComponentEdit
  elif mode == emView and editor.activeView.val == evComponentEdit:
    editor.activeView.val = evPagePreview

proc setVectorTool*(editor: EditorVM; tool: VectorTool) =
  editor.vectorEditor.activeTool.val = tool

proc runEditorCommand*(editor: EditorVM;
    kind: EditorCommandKind): EditorCommandState {.discardable.} =
  ## Dispatch a framework-owned editor command with deterministic state.
  let available = editor.evaluateCommand(kind)
  if available.status == ecsDisabled:
    return editor.failCommand(kind, available.diagnostic)

  var running = available
  running.status = ecsRunning
  editor.setCommandState(running)

  case kind
  of eckEdit:
    editor.setEditMode(emEdit)
  of eckInspect:
    editor.setEditMode(emView)
  of eckApply:
    discard
  of eckRevert, eckDiscard:
    editor.inspector.pendingSourceEdits.val = @[]
    editor.chat.accumulatedEdits.val = @[]
    editor.inspector.editDiagnostics.val = @[]
  of eckSave:
    discard
  of eckDuplicate, eckDelete, eckCreateVariant, eckCreateStory:
    discard
  of eckOpenSource:
    discard

  result = editor.evaluateCommand(kind)
  result.status = ecsSucceeded
  result.diagnostic = ""
  editor.setCommandState(result)

# ===========================================================================
# SidebarVM actions
# ===========================================================================

proc selectStory*(sidebar: SidebarVM; editor: EditorVM;
    story: StoryRef): bool {.discardable.} =
  editor.selectStory(story)

func defaultSidebarSections*(): SidebarSectionExpansion =
  SidebarSectionExpansion(
    userJourneys: true,
    pages: true,
    components: true,
    foundations: true,
    guidelines: false)

func isExpanded*(state: SidebarSectionExpansion;
    section: SidebarSection): bool =
  case section
  of ssUserJourneys:
    state.userJourneys
  of ssPages:
    state.pages
  of ssComponents:
    state.components
  of ssFoundations:
    state.foundations
  of ssGuidelines:
    state.guidelines

func withToggled(state: SidebarSectionExpansion;
    section: SidebarSection): SidebarSectionExpansion =
  result = state
  case section
  of ssUserJourneys:
    result.userJourneys = not result.userJourneys
  of ssPages:
    result.pages = not result.pages
  of ssComponents:
    result.components = not result.components
  of ssFoundations:
    result.foundations = not result.foundations
  of ssGuidelines:
    result.guidelines = not result.guidelines

func withExpanded(state: SidebarSectionExpansion; section: SidebarSection;
    expanded: bool): SidebarSectionExpansion =
  result = state
  case section
  of ssUserJourneys:
    result.userJourneys = expanded
  of ssPages:
    result.pages = expanded
  of ssComponents:
    result.components = expanded
  of ssFoundations:
    result.foundations = expanded
  of ssGuidelines:
    result.guidelines = expanded

proc toggleSection*(sidebar: SidebarVM; section: SidebarSection) =
  sidebar.sections.update proc(prev: SidebarSectionExpansion): SidebarSectionExpansion =
    prev.withToggled(section)

proc setSectionExpanded*(sidebar: SidebarVM; section: SidebarSection;
    expanded: bool) =
  sidebar.sections.update proc(prev: SidebarSectionExpansion): SidebarSectionExpansion =
    prev.withExpanded(section, expanded)

proc toggleGroup*(sidebar: SidebarVM; groupName: string) =
  sidebar.groups.update proc(prev: seq[StoryGroup]): seq[StoryGroup] =
    result = prev
    for i in 0 ..< result.len:
      if result[i].name == groupName:
        result[i].expanded = not result[i].expanded

proc setSearch*(sidebar: SidebarVM; query: string) =
  sidebar.searchFilter.val = query

# ===========================================================================
# InspectorVM actions
# ===========================================================================

proc selectElement*(inspector: InspectorVM; element: ElementRef) =
  inspector.selectedElement.val = element
  inspector.editDiagnostics.val = @[]

proc setSection*(inspector: InspectorVM; section: InspectorSection) =
  inspector.activeSection.val = section

proc clearSelection*(inspector: InspectorVM) =
  inspector.selectedElement.val = ElementRef()
  inspector.editDiagnostics.val = @[]

proc editProperty*(inspector: InspectorVM;
    request: PropertyEditRequest): PropertyEditResult {.discardable.} =
  ## Update the selected element and produce source-aware edit data.
  let element = inspector.selectedElement.val
  if element.tag.len == 0:
    result = withStatus(pesRejected, @[
      diagnostic(pedMissingSelection, element, request.property,
        "Select an element before editing inspector properties.")
    ])
    inspector.editDiagnostics.val = result.diagnostics
    return

  var propIndex = -1
  var prop = PropertyInfo()
  for i, candidate in element.properties:
    if candidate.name == request.property:
      propIndex = i
      prop = candidate
      break

  if propIndex < 0:
    result = withStatus(pesRejected, @[
      diagnostic(pedUnknownProperty, element, request.property,
        "The selected element does not expose this property.")
    ])
    inspector.editDiagnostics.val = result.diagnostics
    return

  var diagnostics: seq[PropertyEditDiagnostic] = @[]
  if prop.isShared and request.scope == pesUnspecified:
    diagnostics.add diagnostic(pedSharedScopeRequired, prop,
      "Shared properties require an explicit local or shared scope.")
    result = withStatus(pesNeedsScope, diagnostics)
    inspector.editDiagnostics.val = diagnostics
    return

  if prop.origin == poSetStyle:
    diagnostics.add diagnostic(pedUnsupportedDirectStyle, prop,
      "Direct setStyle origins are review-only; move the style into classes or tokens before editing.")

  if (request.kind == pekCss or request.kind == pekLayout) and
      prop.sourceFile.isViewModelSource:
    diagnostics.add diagnostic(pedViewModelBoundary, prop,
      "CSS and layout edits cannot be applied from ViewModel-owned source.")

  if prop.isTokenDrift(request.newValue):
    diagnostics.add diagnostic(pedTokenDrift, prop,
      "Theme-token properties must stay on token values instead of literal colors.")

  if prop.isEmptyA11yEdit(request.newValue):
    diagnostics.add diagnostic(pedAccessibility, prop,
      "Accessibility text properties cannot be blank.")

  if diagnostics.len > 0:
    result = withStatus(pesRejected, diagnostics)
    inspector.editDiagnostics.val = diagnostics
    return

  var updated = element
  updated.properties[propIndex].value = request.newValue
  inspector.selectedElement.val = updated
  inspector.editDiagnostics.val = @[]

  let record = prop.editRecord(request)
  let plan = prop.sourcePlan(request)
  inspector.pendingSourceEdits.update proc(prev: seq[SourceEditPlan]): seq[
      SourceEditPlan] =
    result = prev
    result.add plan

  PropertyEditResult(status: pesAccepted, record: record, sourceEdit: plan)

proc editInspectorProperty*(editor: EditorVM;
    request: PropertyEditRequest): PropertyEditResult {.discardable.} =
  result = editor.inspector.editProperty(request)
  if result.status == pesAccepted:
    let acceptedRecord = result.record
    editor.chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
      result = prev
      result.add acceptedRecord
  elif result.diagnostics.len > 0:
    let editDiagnostics = result.diagnostics
    editor.review.violations.update proc(prev: seq[Violation]): seq[Violation] =
      result = prev
      for d in editDiagnostics:
        let category =
          case d.kind
          of pedUnsupportedDirectStyle: vcDirectStyle
          of pedViewModelBoundary: vcViewModelBoundary
          of pedTokenDrift: vcDryTokens
          of pedAccessibility: vcAccessibility
          of pedSharedScopeRequired, pedMissingSelection, pedUnknownProperty:
            vcMockCompleteness
        result.add Violation(
          severity: if d.kind in {pedSharedScopeRequired, pedMissingSelection,
              pedUnknownProperty}: vsWarning else: vsError,
          category: category,
          message: d.message,
          file: d.file,
          line: d.line,
          autoFixable: d.kind in {pedUnsupportedDirectStyle, pedTokenDrift,
              pedAccessibility})

proc editCssProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekCss, scope: scope,
    origin: origin))

proc editLayoutProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekLayout, scope: scope,
    origin: origin))

proc editStateProperty*(editor: EditorVM; property, newValue: string;
    scope = pesUnspecified; origin = peoInspector): PropertyEditResult {.discardable.} =
  editor.editInspectorProperty(PropertyEditRequest(
    property: property, newValue: newValue, kind: pekState, scope: scope,
    origin: origin))

proc applyPendingSourceEdits*(inspector: InspectorVM;
    adapter: SourceEditAdapter): int =
  ## Apply pending plans through a project-owned adapter. No file IO is owned here.
  var remaining: seq[SourceEditPlan] = @[]
  for plan in inspector.pendingSourceEdits.val:
    if adapter(plan):
      inc result
    else:
      remaining.add plan
  inspector.pendingSourceEdits.val = remaining

# ===========================================================================
# AgentChatVM actions
# ===========================================================================

proc addUserMessage*(chat: AgentChatVM; text: string) =
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkUser, text: text, timestamp: 0.0)
  chat.inputText.val = ""

proc addAgentResponse*(chat: AgentChatVM; text: string) =
  chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
    result = prev
    result.add ChatMessage(kind: cmkAgent, text: text, timestamp: 0.0)

proc recordEdit*(chat: AgentChatVM; edit: EditRecord) =
  chat.accumulatedEdits.update proc(prev: seq[EditRecord]): seq[EditRecord] =
    result = prev
    result.add edit

proc clearAccumulatedEdits*(chat: AgentChatVM) =
  chat.accumulatedEdits.val = @[]

proc configureAgentAdapters*(chat: AgentChatVM;
    promptAdapter: AgentPromptAdapter = nil;
    cancelAdapter: AgentCancelAdapter = nil) =
  chat.promptAdapter = promptAdapter
  chat.cancelAdapter = cancelAdapter

proc sendAgentPrompt*(editor: EditorVM): bool {.discardable.} =
  let prompt = editor.chat.inputText.val.strip()
  if prompt.len == 0:
    return false

  editor.chat.addUserMessage(prompt)
  editor.chat.sessionStatus.val = asLoading
  editor.chat.connectionState.val = "streaming"

  if editor.chat.promptAdapter == nil:
    editor.chat.sessionStatus.val = asError
    editor.chat.connectionState.val = "adapter-missing"
    editor.chat.messages.update proc(prev: seq[ChatMessage]): seq[ChatMessage] =
      result = prev
      result.add ChatMessage(kind: cmkError,
        text: "No agent adapter configured.", timestamp: 0.0)
    return false

  let context = AgentPromptContext(
    selectedStory: editor.selectedStory.val,
    selectedElement: editor.inspector.selectedElement.val,
    accumulatedEdits: editor.chat.accumulatedEdits.val,
    platform: editor.platform.val)
  if editor.chat.promptAdapter(prompt, context):
    if editor.chat.sessionStatus.val == asLoading:
      editor.chat.sessionStatus.val = asReady
    if editor.chat.connectionState.val == "streaming":
      editor.chat.connectionState.val = "ready"
    return true

  editor.chat.sessionStatus.val = asError
  editor.chat.connectionState.val = "error"
  false

proc cancelAgentPrompt*(editor: EditorVM): bool {.discardable.} =
  if editor.chat.cancelAdapter == nil:
    return false
  result = editor.chat.cancelAdapter()
  if result:
    editor.chat.sessionStatus.val = asIdle
    editor.chat.connectionState.val = "cancelled"
    editor.chat.stopReason.val = "cancelled"

# ===========================================================================
# ReviewResultsVM actions
# ===========================================================================

func containsLiteralColor(line: string): bool =
  let stripped = line.strip()
  if stripped.startsWith("#") or stripped.startsWith("##"):
    return false
  for i in 0 ..< stripped.len:
    if stripped[i] == '#' and i + 3 < stripped.len:
      return true

func reviewViolation(severity: ViolationSeverity; category: ViolationCategory;
    message, file: string; line: int; autoFixable: bool): Violation =
  Violation(
    severity: severity,
    category: category,
    message: message,
    file: file,
    line: line,
    autoFixable: autoFixable)

proc reviewIsoNimSources*(review: ReviewResultsVM;
    snapshots: seq[SourceSnapshot]) =
  ## Run headless source diagnostics supplied by a project adapter.
  var found: seq[Violation] = @[]
  for snapshot in snapshots:
    let lowerFile = snapshot.file.toLowerAscii()
    let vmFile = lowerFile.contains("viewmodel")
    for index, line in pairs(snapshot.content.splitLines):
      let lineNo = index + 1
      let stripped = line.strip()
      if stripped.len == 0 or stripped.startsWith("#") or stripped.startsWith("##"):
        continue

      if stripped.contains("showIf(") or stripped.contains("forIn("):
        found.add reviewViolation(
          vsWarning,
          vcDeprecatedDsl,
          "Deprecated DSL forms should be replaced with natural Nim control flow.",
          snapshot.file,
          lineNo,
          true)

      if stripped.contains("buildHtml") or stripped.contains("writeBody(\"<") or
          stripped.contains("result.add \"<") or stripped.contains("result &= \"<"):
        found.add reviewViolation(
          vsWarning,
          vcHtmlBuilder,
          "Ad hoc HTML builders bypass the IsoNim DSL rendering contract.",
          snapshot.file,
          lineNo,
          false)

      if stripped.contains("setStyle(") or stripped.contains("setStyle ="):
        found.add reviewViolation(
          vsError,
          vcDirectStyle,
          "Direct setStyle edits are unsupported by the inspector edit engine.",
          snapshot.file,
          lineNo,
          true)

      let classAssignment = "class" & " ="
      if vmFile and (stripped.contains(classAssignment) or
          stripped.contains("setStyle(") or stripped.contains("setStyle =") or
          stripped.contains("background_color") or stripped.contains(
              "border_radius") or
          stripped.contains("font_size")):
        found.add reviewViolation(
          vsError,
          vcViewModelBoundary,
          "ViewModel source must not own CSS classes or style properties.",
          snapshot.file,
          lineNo,
          true)

      if stripped.containsLiteralColor:
        found.add reviewViolation(
          vsWarning,
          vcDryTokens,
          "Literal colors should stay behind theme tokens.",
          snapshot.file,
          lineNo,
          true)

      if (stripped.contains("<img") or stripped.contains("img(")) and
          not stripped.contains("alt"):
        found.add reviewViolation(
          vsWarning,
          vcAccessibility,
          "Images need accessible alt text.",
          snapshot.file,
          lineNo,
          true)

  review.violations.val = found

# ===========================================================================
# FlowPlayerVM actions
# ===========================================================================

proc nextStep*(player: FlowPlayerVM) =
  let total = player.totalSteps.val
  if total > 0:
    player.currentStep.update proc(prev: int): int =
      if prev + 1 >= total: 0 else: prev + 1

proc prevStep*(player: FlowPlayerVM) =
  let total = player.totalSteps.val
  if total > 0:
    player.currentStep.update proc(prev: int): int =
      if prev <= 0: total - 1 else: prev - 1

proc play*(player: FlowPlayerVM) =
  player.playState.val = psPlaying

proc pause*(player: FlowPlayerVM) =
  player.playState.val = psPaused

proc stop*(player: FlowPlayerVM) =
  player.playState.val = psStopped
  player.currentStep.val = 0

# ===========================================================================
# Factory: create all ViewModels with proper reactive wiring
# ===========================================================================

proc createSidebarVM*(): SidebarVM =
  let groups = createSignal[seq[StoryGroup]](@[])
  let sections = createSignal(defaultSidebarSections())
  let searchFilter = createSignal("")

  let filteredItems = createMemo[seq[StoryGroup]](proc(): seq[StoryGroup] =
    let query = searchFilter.val.toLowerAscii()
    let allGroups = groups.val
    if query.len == 0:
      return allGroups
    result = @[]
    for g in allGroups:
      var filtered = StoryGroup(
        name: g.name,
        kind: g.kind,
        description: g.description,
        expanded: g.expanded)
      for item in g.items:
        if query in item.name.toLowerAscii() or
            query in item.description.toLowerAscii():
          filtered.items.add item
      if filtered.items.len > 0:
        result.add filtered
  )

  SidebarVM(
    groups: groups,
    sections: sections,
    searchFilter: searchFilter,
    filteredItems: filteredItems)

proc createStoryboardVM*(): StoryboardVM =
  let canvasItems = createSignal[seq[CanvasItem]](@[])
  let connections = createSignal[seq[FlowConnection]](@[])
  let zoom = createSignal(1.0)
  let panX = createSignal(0.0)
  let panY = createSignal(0.0)
  let selectedItem = createSignal(-1)
  let hoveredItem = createSignal(-1)

  StoryboardVM(
    canvasItems: canvasItems,
    connections: connections,
    zoom: zoom,
    panX: panX,
    panY: panY,
    selectedItem: selectedItem,
    hoveredItem: hoveredItem)

proc createInspectorVM*(): InspectorVM =
  let selectedElement = createSignal(ElementRef())
  let activeSection = createSignal(isLayout)
  let editDiagnostics = createSignal[seq[PropertyEditDiagnostic]](@[])
  let pendingSourceEdits = createSignal[seq[SourceEditPlan]](@[])

  let hasElement = createMemo[bool](proc(): bool =
    selectedElement.val.tag.len > 0
  )

  let properties = createMemo[seq[PropertyInfo]](proc(): seq[PropertyInfo] =
    selectedElement.val.properties
  )

  let displayMode = createSignal(dmFlex)
  let flexDirection = createSignal(fdRow)

  InspectorVM(
    selectedElement: selectedElement,
    activeSection: activeSection,
    editDiagnostics: editDiagnostics,
    pendingSourceEdits: pendingSourceEdits,
    hasElement: hasElement,
    properties: properties,
    displayMode: displayMode,
    flexDirection: flexDirection)

proc createVectorEditorVM*(): VectorEditorVM =
  let activeTool = createSignal(vtSelect)
  let symbols = createSignal[seq[VectorSymbol]](@[])
  let searchFilter = createSignal("")
  let selectedSymbol = createSignal(-1)
  let zoom = createSignal(1.0)
  let showGrid = createSignal(true)
  let snapToGrid = createSignal(true)
  let gridSize = createSignal(8.0)

  let isEditing = createMemo[bool](proc(): bool =
    selectedSymbol.val >= 0
  )

  let filteredSymbols = createMemo[seq[VectorSymbol]](proc(): seq[VectorSymbol] =
    let query = searchFilter.val.toLowerAscii()
    let all = symbols.val
    if query.len == 0:
      return all
    result = @[]
    for s in all:
      if query in s.name.toLowerAscii() or query in s.category.toLowerAscii():
        result.add s
      else:
        for tag in s.tags:
          if query in tag.toLowerAscii():
            result.add s
            break
  )

  VectorEditorVM(
    activeTool: activeTool,
    symbols: symbols,
    searchFilter: searchFilter,
    filteredSymbols: filteredSymbols,
    selectedSymbol: selectedSymbol,
    isEditing: isEditing,
    zoom: zoom,
    showGrid: showGrid,
    snapToGrid: snapToGrid,
    gridSize: gridSize)

proc createAgentChatVM*(): AgentChatVM =
  let messages = createSignal[seq[ChatMessage]](@[])
  let sessionStatus = createSignal(asIdle)
  let accumulatedEdits = createSignal[seq[EditRecord]](@[])
  let inputText = createSignal("")
  let connectionState = createSignal("disconnected")
  let planEntries = createSignal[seq[string]](@[])
  let toolCalls = createSignal[seq[string]](@[])
  let stopReason = createSignal("")

  let messageCount = createMemo[int](proc(): int = messages.val.len)

  AgentChatVM(
    messages: messages,
    sessionStatus: sessionStatus,
    accumulatedEdits: accumulatedEdits,
    inputText: inputText,
    connectionState: connectionState,
    planEntries: planEntries,
    toolCalls: toolCalls,
    stopReason: stopReason,
    messageCount: messageCount)

proc createReviewResultsVM*(): ReviewResultsVM =
  let violations = createSignal[seq[Violation]](@[])

  let errorCount = createMemo[int](proc(): int =
    var count = 0
    for v in violations.val:
      if v.severity == vsError: inc count
    count
  )

  let warningCount = createMemo[int](proc(): int =
    var count = 0
    for v in violations.val:
      if v.severity == vsWarning: inc count
    count
  )

  let hasIssues = createMemo[bool](proc(): bool = violations.val.len > 0)

  ReviewResultsVM(
    violations: violations,
    errorCount: errorCount,
    warningCount: warningCount,
    hasIssues: hasIssues)

proc createProjectPreviewVM*(selectedStory: Signal[StoryRef];
    platform: Signal[Platform]): ProjectPreviewVM =
  let preview = ProjectPreviewVM(hook: defaultPreviewHook)
  preview.current = createMemo[ProjectPreview](proc(): ProjectPreview =
    preview.hook(selectedStory.val, platform.val)
  )
  preview

proc createFlowPlayerVM*(): FlowPlayerVM =
  let steps = createSignal[seq[FlowStep]](@[])
  let currentStep = createSignal(0)
  let playState = createSignal(psStopped)

  let totalSteps = createMemo[int](proc(): int = steps.val.len)
  let isFirstStep = createMemo[bool](proc(): bool = currentStep.val == 0)
  let isLastStep = createMemo[bool](proc(): bool =
    let total = steps.val.len
    total == 0 or currentStep.val >= total - 1
  )
  let currentAction = createMemo[string](proc(): string =
    let idx = currentStep.val
    let all = steps.val
    if idx >= 0 and idx < all.len: all[idx].action else: ""
  )

  FlowPlayerVM(
    steps: steps,
    currentStep: currentStep,
    playState: playState,
    totalSteps: totalSteps,
    isFirstStep: isFirstStep,
    isLastStep: isLastStep,
    currentAction: currentAction)

proc createEditorVM*(): EditorVM =
  ## Create the top-level editor ViewModel with all sub-VMs wired up.
  let activeView = createSignal(evStoryboard)
  let selectedStory = createSignal(StoryRef())
  let editMode = createSignal(emView)
  let panels = createSignal(PanelVisibility(sidebar: true, inspector: true))
  let platform = createSignal(pfWeb)
  let viewport = createSignal(pvDesktop)
  let workspacePermissions = createSignal(defaultWorkspacePermissions())
  let sourceAdapterReady = createSignal(false)
  let commandStates = createSignal[seq[EditorCommandState]](@[])

  let sidebar = createSidebarVM()
  let storyboard = createStoryboardVM()
  let inspector = createInspectorVM()
  let vectorEditor = createVectorEditorVM()
  let chat = createAgentChatVM()
  let review = createReviewResultsVM()
  let preview = createProjectPreviewVM(selectedStory, platform)
  let flowPlayer = createFlowPlayerVM()

  let hasSelection = createMemo[bool](proc(): bool =
    selectedStory.val.name.len > 0
  )

  EditorVM(
    activeView: activeView,
    selectedStory: selectedStory,
    editMode: editMode,
    panels: panels,
    platform: platform,
    viewport: viewport,
    workspacePermissions: workspacePermissions,
    sourceAdapterReady: sourceAdapterReady,
    commandStates: commandStates,
    sidebar: sidebar,
    storyboard: storyboard,
    inspector: inspector,
    vectorEditor: vectorEditor,
    chat: chat,
    review: review,
    preview: preview,
    flowPlayer: flowPlayer,
    hasSelection: hasSelection)
