## IsoNim Editor — all ViewModel types.
##
## Pure state machines using IsoNim reactive primitives.
## No CSS, no colors, no rendering — only signals, memos, and enums.
## Created via withViewModel inside createRoot.

import std/strutils
import isonim/core/[signals, computation, owner]
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

  InspectorVM* = ref object of ViewModel
    selectedElement*: Signal[ElementRef]
    activeSection*: Signal[InspectorSection]
    hasElement*: Memo[bool]
    properties*: Memo[seq[PropertyInfo]]

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
    selectedStory*: Signal[StoryRef]
    editMode*: Signal[EditMode]
    panels*: Signal[PanelVisibility]
    platform*: Signal[Platform]
    sidebar*: SidebarVM
    inspector*: InspectorVM
    chat*: AgentChatVM
    review*: ReviewResultsVM
    flowPlayer*: FlowPlayerVM
    hasSelection*: Memo[bool]

# ===========================================================================
# SidebarVM actions
# ===========================================================================

proc selectStory*(sidebar: SidebarVM; editor: EditorVM; story: StoryRef) =
  editor.selectedStory.val = story

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
      var filtered = StoryGroup(name: g.name, kind: g.kind,
                                 description: g.description, expanded: g.expanded)
      for item in g.items:
        if query in item.name.toLowerAscii() or query in item.description.toLowerAscii():
          filtered.items.add item
      if filtered.items.len > 0:
        result.add filtered
  )

  SidebarVM(groups: groups, searchFilter: searchFilter, filteredItems: filteredItems)

proc createInspectorVM*(): InspectorVM =
  let selectedElement = createSignal(ElementRef())
  let activeSection = createSignal(isLayout)

  let hasElement = createMemo[bool](proc(): bool =
    selectedElement.val.tag.len > 0
  )

  let properties = createMemo[seq[PropertyInfo]](proc(): seq[PropertyInfo] =
    selectedElement.val.properties
  )

  InspectorVM(selectedElement: selectedElement, activeSection: activeSection,
              hasElement: hasElement, properties: properties)

proc createAgentChatVM*(): AgentChatVM =
  let messages = createSignal[seq[ChatMessage]](@[])
  let sessionStatus = createSignal(asIdle)
  let accumulatedEdits = createSignal[seq[EditRecord]](@[])
  let inputText = createSignal("")

  let messageCount = createMemo[int](proc(): int = messages.val.len)

  AgentChatVM(messages: messages, sessionStatus: sessionStatus,
              accumulatedEdits: accumulatedEdits, inputText: inputText,
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

  ReviewResultsVM(violations: violations, errorCount: errorCount,
                  warningCount: warningCount, hasIssues: hasIssues)

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

  FlowPlayerVM(steps: steps, currentStep: currentStep, playState: playState,
               totalSteps: totalSteps, isFirstStep: isFirstStep,
               isLastStep: isLastStep, currentAction: currentAction)

proc createEditorVM*(): EditorVM =
  ## Create the top-level editor ViewModel with all sub-VMs wired up.
  let selectedStory = createSignal(StoryRef())
  let editMode = createSignal(emView)
  let panels = createSignal(PanelVisibility(sidebar: true, inspector: true))
  let platform = createSignal(pfWeb)

  let sidebar = createSidebarVM()
  let inspector = createInspectorVM()
  let chat = createAgentChatVM()
  let review = createReviewResultsVM()
  let flowPlayer = createFlowPlayerVM()

  let hasSelection = createMemo[bool](proc(): bool =
    selectedStory.val.name.len > 0
  )

  EditorVM(selectedStory: selectedStory, editMode: editMode,
           panels: panels, platform: platform,
           sidebar: sidebar, inspector: inspector, chat: chat,
           review: review, flowPlayer: flowPlayer,
           hasSelection: hasSelection)
