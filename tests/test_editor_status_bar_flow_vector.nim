## PSZ-M3 note 25: the flow-step and vector-editor routes drop an element that
## belongs to the story they leave, as ``selectStory`` does (PSZ-M3 note 24).
## An element is part of the story whose tree it came from, so after
## ``selectFlowStep`` moves to a page, or ``openVectorEditor`` opens a symbol,
## the status bar must not keep naming the component's element. Selecting the
## story that is already selected keeps its element.
##
## These routes are viewmodel state only, so the test reads the viewmodel
## directly. It needs no DOM and no mocks: the breadcrumb it checks is the
## viewmodel's own ``breadcrumbPath``, which is what the status bar renders.
##
## Negative control: make ``setSelectedStory`` (viewmodels.nim) skip its
## ``clearInspectorSelection`` call. The two "drops" cases then fail with the
## component's element still selected.
import std/unittest
import isonim/core/[signals, computation, owner]
import isonim/editor/[viewmodels, types]

const
  componentStory = StoryRef(group: "Components", name: "DestinationCard",
    kind: skComponent, index: 0)
  pageStory = StoryRef(group: "Pages", name: "Trip Planner", kind: skPage,
    index: 0)
  symbolStory = StoryRef(group: "Vector Symbols", name: "TaskCheckIcon",
    kind: skVectorSymbol, index: 0)

proc sidebarFor(vm: EditorVM) =
  # selectStory and selectFlowStep only accept a story the sidebar lists.
  vm.sidebar.groups.val = @[
    StoryGroup(name: "Components", kind: skComponent, items: @[
      StoryItem(name: "DestinationCard", kind: skComponent,
        group: "Components")]),
    StoryGroup(name: "Pages", kind: skPage, items: @[
      StoryItem(name: "Trip Planner", kind: skPage, group: "Pages")]),
    StoryGroup(name: "Vector Symbols", kind: skVectorSymbol, items: @[
      StoryItem(name: "TaskCheckIcon", kind: skVectorSymbol,
        group: "Vector Symbols")]),
  ]

proc cardElement(): ElementRef =
  ElementRef(id: "destination-card", tag: "DestinationCard",
    sourceFile: "destination_card.nim", sourceLine: 1,
    ancestors: @["DestinationCard"], ancestorIds: @["destination-card"])

proc titleElement(): ElementRef =
  ElementRef(id: "title", tag: "h1", ancestors: @["h1"],
    ancestorIds: @["title"])

suite "PSZ-M3 note 25: flow-step and vector-editor routes drop a stale element":

  test "a flow step to a page drops the component's element selection":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      sidebarFor(vm)
      vm.flowPlayer.steps.val = @[FlowStep(screenRef: pageStory)]
      check vm.selectStory(componentStory)
      check vm.selectInspectorElement(cardElement())
      check vm.inspector.selectedElement.val.tag == "DestinationCard"

      check vm.selectFlowStep(0)
      check vm.selectedStory.val.name == "Trip Planner"
      check vm.inspector.selectedElement.val.tag == ""
      check vm.inspector.breadcrumbPath().entries.len == 0
      dispose()

  test "a flow step to the story already selected keeps its element":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      sidebarFor(vm)
      vm.flowPlayer.steps.val = @[FlowStep(screenRef: pageStory)]
      check vm.selectStory(pageStory)
      check vm.selectInspectorElement(titleElement())

      check vm.selectFlowStep(0)
      check vm.inspector.selectedElement.val.id == "title"
      dispose()

  test "opening the vector editor drops the component's element selection":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      sidebarFor(vm)
      check vm.selectStory(componentStory)
      check vm.selectInspectorElement(cardElement())

      check vm.openVectorEditor(symbolStory)
      check vm.activeView.val == evVectorEditor
      check vm.selectedStory.val.name == "TaskCheckIcon"
      check vm.inspector.selectedElement.val.tag == ""
      dispose()

  test "re-opening the same vector symbol keeps its element selection":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      sidebarFor(vm)
      check vm.openVectorEditor(symbolStory)
      check vm.selectInspectorElement(titleElement())

      check vm.openVectorEditor(symbolStory)
      check vm.inspector.selectedElement.val.id == "title"
      dispose()
