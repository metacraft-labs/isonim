## PSZ-M3 note 24: the status bar names the story the editor shows and the
## element selected in that story. Selecting a page story while a component
## is selected must drop the component's selection: the page has no such
## element, so the bar must not keep saying "View DestinationCard" beside
## "Pages / Trip Planner".
##
## The URL route (browser.nim, applyEditorRoute) and the sidebar both reach
## the story through ``EditorVM.selectStory``, so this test drives that path.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only: the test reads the status bar's breadcrumb segments, which are
##   rendered by the real shell view. Nothing else is faked.
## - The sidebar is filled with literal ``StoryGroup`` values, as the other
##   viewmodel tests do, because ``selectStory`` only accepts a story the
##   sidebar lists.
##
## Negative control: remove the selection clear in ``selectStory``
## (viewmodels.nim). The "page story after a component" case then fails, with
## the breadcrumb still holding the DestinationCard segment.
import std/[unittest, strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types]
import isonim/editor/views/shell

const
  componentStory = StoryRef(group: "Components", name: "DestinationCard",
    kind: skComponent, index: 0)
  pageStory = StoryRef(group: "Pages", name: "Trip Planner", kind: skPage,
    index: 0)

proc sidebarFor(vm: EditorVM) =
  vm.sidebar.groups.val = @[
    StoryGroup(name: "Components", kind: skComponent, items: @[
      StoryItem(name: "DestinationCard", kind: skComponent,
        group: "Components")]),
    StoryGroup(name: "Pages", kind: skPage, items: @[
      StoryItem(name: "Trip Planner", kind: skPage, group: "Pages")]),
  ]

proc cardElement(): ElementRef =
  ElementRef(id: "destination-card", tag: "DestinationCard",
    sourceFile: "destination_card.nim", sourceLine: 1,
    ancestors: @["DestinationCard"], ancestorIds: @["destination-card"])

proc collectElementSegments(node: MockNode; found: var seq[string]) =
  if node.kind == mnkElement:
    let state = node.attributes.getOrDefault("data-breadcrumb-state")
    if state.len > 0 and state != "story":
      found.add node.attributes.getOrDefault("data-breadcrumb-id")
  for child in node.children:
    collectElementSegments(child, found)

proc elementSegments(shell: MockNode): seq[string] =
  ## The breadcrumb's element segments (not the story segments), in render order.
  collectElementSegments(shell, result)

suite "PSZ-M3 note 24: the status bar after a story change":

  test "a page story selected after a component drops the component's selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      sidebarFor(vm)
      check vm.selectStory(componentStory)
      check vm.selectInspectorElement(cardElement())
      let before = renderEditorShell[MockRenderer, MockNode](r, vm)
      check elementSegments(before) == @["destination-card"]

      check vm.selectStory(pageStory)
      check vm.selectedStory.val.name == "Trip Planner"
      check vm.inspector.selectedElement.val.tag == ""
      check vm.inspector.breadcrumbPath().entries.len == 0
      let after = renderEditorShell[MockRenderer, MockNode](r, vm)
      check elementSegments(after).len == 0
      check after.textContent.contains("Trip Planner")
      dispose()

  test "re-selecting the same story keeps its selection":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      sidebarFor(vm)
      check vm.selectStory(componentStory)
      check vm.selectInspectorElement(cardElement())
      discard vm.selectStory(componentStory)
      check vm.inspector.selectedElement.val.tag == "DestinationCard"
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check elementSegments(shell) == @["destination-card"]
      dispose()

  test "a selection made after the page story belongs to the page":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      sidebarFor(vm)
      check vm.selectStory(componentStory)
      check vm.selectInspectorElement(cardElement())
      check vm.selectStory(pageStory)
      let title = ElementRef(id: "title", tag: "h1", ancestors: @["h1"],
        ancestorIds: @["title"])
      check vm.selectInspectorElement(title)
      check vm.inspector.selectedElement.val.id == "title"
      dispose()
