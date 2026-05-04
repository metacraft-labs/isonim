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
    messageCount*: Memo[int]

  ReviewResultsVM* = ref object of ViewModel
    violations*: Signal[seq[Violation]]
    errorCount*: Memo[int]
    warningCount*: Memo[int]
    hasIssues*: Memo[bool]

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
    sidebar*: SidebarVM
    storyboard*: StoryboardVM
    inspector*: InspectorVM
    vectorEditor*: VectorEditorVM
    chat*: AgentChatVM
    review*: ReviewResultsVM
    flowPlayer*: FlowPlayerVM
    hasSelection*: Memo[bool]

func isEmptyStory(story: StoryRef): bool =
  story.group.len == 0 and story.name.len == 0

func sameStory(a, b: StoryRef): bool =
  a.group == b.group and a.name == b.name and a.kind == b.kind

func viewForStory(story: StoryRef): EditorView =
  case story.kind
  of skFlow:
    evStoryboard
  of skPage:
    evPagePreview
  of skComponent, skPattern, skFoundation, skGuideline:
    evComponentDetail

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
  true

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
    return false

  editor.inspector.selectedElement.val = element
  true

proc changePlatform*(editor: EditorVM; platform: Platform) =
  editor.platform.val = platform

proc selectVectorSymbol*(editor: EditorVM; index: int): bool {.discardable.} =
  let symbols = editor.vectorEditor.symbols.val
  if index < 0 or index >= symbols.len:
    return false

  editor.vectorEditor.selectedSymbol.val = index
  true

proc setAgentState*(editor: EditorVM; state: AsyncState) =
  editor.chat.sessionStatus.val = state

# ===========================================================================
# SidebarVM actions
# ===========================================================================

proc selectStory*(sidebar: SidebarVM; editor: EditorVM;
    story: StoryRef): bool {.discardable.} =
  editor.selectStory(story)

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

proc setSection*(inspector: InspectorVM; section: InspectorSection) =
  inspector.activeSection.val = section

proc clearSelection*(inspector: InspectorVM) =
  inspector.selectedElement.val = ElementRef()

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

  let messageCount = createMemo[int](proc(): int = messages.val.len)

  AgentChatVM(
    messages: messages,
    sessionStatus: sessionStatus,
    accumulatedEdits: accumulatedEdits,
    inputText: inputText,
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

  let sidebar = createSidebarVM()
  let storyboard = createStoryboardVM()
  let inspector = createInspectorVM()
  let vectorEditor = createVectorEditorVM()
  let chat = createAgentChatVM()
  let review = createReviewResultsVM()
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
    sidebar: sidebar,
    storyboard: storyboard,
    inspector: inspector,
    vectorEditor: vectorEditor,
    chat: chat,
    review: review,
    flowPlayer: flowPlayer,
    hasSelection: hasSelection)
