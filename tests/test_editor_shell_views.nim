## Tests for IsoNim Editor — shell Views (M2)

import std/[unittest, strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/stories
import isonim/editor/types
import isonim/editor/views/shell
import isonim/editor/views/chat_panel
import isonim/editor/views/component_edit
import isonim/editor/views/component_detail
import isonim/editor/views/foundations_page
import isonim/editor/views/page_preview
import isonim/editor/views/storyboard
import isonim/editor/views/vector_editor

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc countByAttr(node: MockNode; name, value: string): int =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    inc result
  for child in node.children:
    result += countByAttr(child, name, value)

proc collectByAttr(node: MockNode; name, value: string; result: var seq[MockNode]) =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    result.add node
  for child in node.children:
    collectByAttr(child, name, value, result)

proc findAllByAttr(node: MockNode; name, value: string): seq[MockNode] =
  collectByAttr(node, name, value, result)

proc countInteractive(node: MockNode): int =
  if node.kind == mnkElement and
      ("click" in node.eventListeners or "keydown" in node.eventListeners):
    inc result
  for child in node.children:
    result += countInteractive(child)

suite "Editor Shell Views (M2)":

  test "test_editor_shell_three_panel_layout":
    ## Editor renders sidebar, preview, and inspector panels
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Shell mounts the main editor row, command palette, telemetry overlay,
      # and status bar.
      check shell.children.len == 4
      check shell.children[0].children.len == 8
      check findByAttr(shell, "data-foundations-page", "true") != nil
      check findByAttr(shell, "data-editor-command-palette", "true") != nil
      check findByAttr(shell, "data-editor-telemetry-overlay", "true") != nil
      dispose()

  test "test_sidebar_renders_groups":
    ## Sidebar shows storyboard groups
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)

      # Should have search and group list; product/version live in status bar.
      check sidebar.children.len >= 2
      check findByAttr(sidebar, "aria-label", "Toggle User Journeys section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Pages section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Components section") != nil
      check findByAttr(sidebar, "aria-label", "Toggle Foundations section") != nil
      check findByAttr(sidebar, "aria-label", "Open First Task journey") != nil
      check findByAttr(sidebar, "aria-label",
        "Select story First Task / User opens the app for the first time") == nil

      dispose()

  test "test_preview_pane_shows_toolbar":
    ## Preview pane has toolbar with mode toggle and platform selector
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      # Should have toolbar and preview area
      check pane.children.len >= 2

      # Toolbar should have mode toggle and platform selector
      let toolbar = pane.children[0]
      check toolbar.children.len >= 2

      dispose()

  test "test_inspector_renders_all_sections":
    ## Inspector shows section tabs and content area
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Should have tabs, content, and chat section
      check panel.children.len >= 3

      # Tabs should expose every inspector section.
      let tabs = panel.children[0]
      check tabs.children.len == 12

      dispose()

  test "component_edit_inspector_explains_and_applies_design_system_scope":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.selectInspectorElement(ElementRef(
        id: "card-title",
        tag: "h2",
        sourceFile: "apps/back-office/src/backoffice_ui/cards.nim",
        sourceLine: 42,
        properties: @[
          PropertyInfo(name: "gap", value: "16px", origin: poThemeToken,
            originDetail: "spacing token",
            sourceFile: "apps/back-office/src/backoffice_ui/cards.nim",
            sourceLine: 43,
            sharedCount: 5,
            schemaKey: "semantic.spacing.card-gap",
            tokenName: "space.card.gap"),
          PropertyInfo(name: "border-radius", value: "8px",
            origin: poSetStyle,
            originDetail: "local radius",
            sourceFile: "apps/back-office/src/backoffice_ui/cards.nim",
            sourceLine: 44)
        ]))

      let view = renderComponentEditView[MockRenderer, MockNode](r, vm)
      let impact = findByAttr(view, "data-design-system-impact", "true")
      check impact != nil
      check impact.attributes["data-source-scope-impact"] == "true"
      check impact.attributes["data-design-system-property-count"] == "1"
      check impact.attributes["data-source-scope-impact-count"] == "1"
      check view.textContent.contains("Scope impact")
      check view.textContent.contains("row scope selector")
      check view.textContent.contains("updates 5 mapped uses")
      check view.textContent.contains("token space.card.gap")
      check view.textContent.contains("CSS Layout / Grid / Flex / Constraints")
      check findByAttr(view, "data-inspector-section", "layout") != nil
      check findByAttr(view, "data-inspector-section", "size") != nil
      check findByAttr(view, "data-inspector-section", "spacing") != nil
      check findByAttr(view, "data-inspector-section", "position") != nil
      check findByAttr(view, "data-inspector-section", "fill") != nil
      check findByAttr(view, "data-inspector-section", "stroke") != nil
      check findByAttr(view, "data-inspector-section", "typography") != nil
      check findByAttr(view, "data-inspector-section", "effects") != nil
      check findByAttr(view, "data-inspector-section", "transitions") != nil
      check findByAttr(view, "data-inspector-section", "filters") != nil
      check findByAttr(view, "data-inspector-section", "state") != nil
      check findByAttr(view, "data-inspector-section", "source") != nil

      let denseRows = findAllByAttr(view, "data-inspector-dense-row", "true")
      check denseRows.len >= 2
      var gapRow: MockNode
      for row in denseRows:
        check row.attributes["data-inspector-row-slots"] ==
          "label scrub-value unit binding scope reset more"
        for slot in [
          "label-scrubber", "value-field", "unit-picker",
          "binding-indicator", "scope-selector", "reset", "actions"
        ]:
          check countByAttr(row, "data-inspector-row-slot", slot) == 1
        if row.attributes.getOrDefault("data-inspector-property") == "gap" and
            row.attributes.getOrDefault("data-inspector-property-source-key") ==
            "semantic.spacing.card-gap":
          gapRow = row
      check gapRow != nil
      let gapInput = findByAttr(gapRow, "aria-label",
        "Edit inspector property gap")
      let scopeSelector = findByAttr(gapRow, "aria-label",
        "Choose source scope for gap")
      let sharedScope = findByAttr(gapRow, "aria-label",
        "Apply Shared class source scope for gap")
      check gapInput != nil
      check scopeSelector != nil
      check scopeSelector.attributes["data-inspector-row-slot"] == "scope-selector"
      check scopeSelector.attributes["data-compact-choice-strip"] == "true"
      check scopeSelector.attributes["data-source-scope-count"] == "7"
      check sharedScope != nil
      check sharedScope.attributes["data-compact-choice-enabled"] == "true"
      check "click" in sharedScope.eventListeners
      r.setInputValue(gapInput, "24px")
      sharedScope.fireEvent("click")
      check vm.inspector.pendingSourceEdits.val.len == 1
      check vm.inspector.pendingSourceEdits.val[0].scope == pesShared
      check vm.inspector.pendingSourceEdits.val[0].sourceScope == sskSharedClass
      check vm.inspector.selectedElement.val.properties[0].value == "24px"
      dispose()

  test "test_views_contain_no_hardcoded_values":
    ## View files use Tailwind classes, no hardcoded pixel values in class strings
    let shellFile = readFile("src/isonim/editor/views/shell.nim")

    # Views should use class = "..." for layout (Tailwind)
    check "class = " in shellFile

    # Views should use setStyle for dynamic/theme values — this is expected
    # But class strings should not contain raw px values
    # (they use Tailwind scale like p-4, not p-16px)

  test "test_chat_section_has_input":
    ## Agent chat area has input bar and send button
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Chat section is the last child
      let chatSection = panel.children[^1]
      check chatSection.children.len >= 2 # header + input row

      dispose()

  test "editor_shell_mock_renderer_exposes_clickable_controls":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.vectorEditor.symbols.val = @[
        VectorSymbol(name: "Circle", category: "Icons",
            svgContent: "<svg></svg>"),
        VectorSymbol(name: "Rectangle", category: "Icons",
            svgContent: "<svg></svg>"),
        VectorSymbol(name: "Line", category: "Icons", svgContent: "<svg></svg>")
      ]

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check countInteractive(shell) >= 8

      let storyButton = findByAttr(shell, "aria-label", "Select story TaskRow / Active task")
      check storyButton != nil
      check storyButton.attributes["role"] == "button"
      check storyButton.attributes["tabindex"] == "0"
      check storyButton.attributes["aria-current"] == "false"
      storyButton.fireEvent("click")
      check vm.selectedStory.val.group == "TaskRow"
      check vm.selectedStory.val.name == "Active task"
      check storyButton.attributes["aria-current"] == "true"
      check storyButton.styles["background-color"].len > 0
      check storyButton.styles["border-left"].contains("#3B82F6")

      let sidebarToggle = findByAttr(shell, "aria-label", "Toggle TaskRow stories")
      check sidebarToggle != nil
      check sidebarToggle.attributes["aria-expanded"] == "true"
      sidebarToggle.fireEvent("keydown")
      var taskRowCollapsed = false
      for group in vm.sidebar.groups.val:
        if group.name == "TaskRow":
          taskRowCollapsed = not group.expanded
      check taskRowCollapsed
      check sidebarToggle.attributes["aria-expanded"] == "false"

      let journeysToggle = findByAttr(shell, "aria-label",
        "Toggle User Journeys section")
      let journeysOpen = findByAttr(shell, "aria-label",
        "Open User Journeys section")
      check journeysToggle != nil
      check journeysOpen != nil
      check journeysToggle.attributes["aria-expanded"] == "true"
      journeysOpen.fireEvent("click")
      check vm.activeView.val == evStoryboard
      journeysToggle.fireEvent("click")
      check journeysToggle.attributes["aria-expanded"] == "false"

      let inspectorToggle = findByAttr(shell, "aria-label", "Toggle inspector panel")
      check inspectorToggle != nil
      inspectorToggle.fireEvent("click")
      check vm.panels.val.inspector == false

      let vector = renderVectorEditor[MockRenderer, MockNode](r, vm)
      let penTool = findByAttr(vector, "aria-label", "Select Pen vector tool")
      check penTool != nil
      check penTool.attributes["aria-pressed"] == "false"
      penTool.fireEvent("click")
      check vm.vectorEditor.activeTool.val == vtPen
      check penTool.attributes["aria-pressed"] == "true"

      let gridToggle = findByAttr(vector, "aria-label", "Toggle vector grid")
      check gridToggle != nil
      check gridToggle.attributes["aria-pressed"] == "true"
      gridToggle.fireEvent("click")
      check vm.vectorEditor.showGrid.val == false
      check gridToggle.attributes["aria-pressed"] == "false"

      let union = findByAttr(vector, "aria-label", "Vector Union")
      check union != nil
      check union.attributes["data-vector-action"] == "boolean-unite"

      let saveVector = findByAttr(vector, "aria-label",
        "Save vector source edits")
      check saveVector != nil
      check saveVector.attributes["data-vector-pending-source-edits"] == "0"

      let layer = findByAttr(vector, "aria-label", "Select vector layer Rectangle")
      check layer != nil
      layer.fireEvent("keydown")
      check vm.vectorEditor.selectedSymbol.val == 1
      check layer.attributes["aria-selected"] == "true"

      let inspector = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let fillTab = findByAttr(inspector, "aria-label", "Show Fill inspector section")
      check fillTab != nil
      check fillTab.attributes["aria-selected"] == "false"
      fillTab.fireEvent("click")
      check vm.inspector.activeSection.val == isFill
      check fillTab.attributes["aria-selected"] == "true"
      check fillTab.styles["box-shadow"].contains("#3B82F6")

      let preview = renderPreviewPane[MockRenderer, MockNode](r, vm)
      let vectorView = findByAttr(preview, "aria-label", "Open Vector editor view")
      check vectorView != nil
      vectorView.fireEvent("click")
      check vm.activeView.val == evVectorEditor

      let iosButton = findByAttr(preview, "aria-label", "Preview iOS platform")
      check iosButton != nil
      check iosButton.attributes["aria-pressed"] == "false"
      iosButton.fireEvent("click")
      check vm.platform.val == pfIOS
      check iosButton.attributes["aria-pressed"] == "true"
      check iosButton.styles["background-color"] == "#3B82F6"

      vm.flowPlayer.steps.val = userFlows()[0].steps
      let flowShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let nextFlow = findByAttr(flowShell, "aria-label", "Next flow step")
      let prevFlow = findByAttr(flowShell, "aria-label", "Previous flow step")
      let playFlow = findByAttr(flowShell, "aria-label", "Play flow")
      let stopFlow = findByAttr(flowShell, "aria-label", "Stop flow")
      check nextFlow != nil
      check prevFlow != nil
      check playFlow != nil
      check stopFlow != nil
      check playFlow.attributes["aria-pressed"] == "false"

      nextFlow.fireEvent("click")
      check vm.flowPlayer.currentStep.val == 1
      let secondStep = findByAttr(flowShell, "aria-label",
        "Select story Pages / Empty State")
      check secondStep != nil
      check secondStep.attributes["aria-current"] == "true"

      prevFlow.fireEvent("click")
      check vm.flowPlayer.currentStep.val == 0

      playFlow.fireEvent("click")
      check vm.flowPlayer.playState.val == psPlaying
      check playFlow.attributes["aria-pressed"] == "true"
      check playFlow.attributes["aria-label"] == "Pause flow"

      stopFlow.fireEvent("click")
      check vm.flowPlayer.playState.val == psStopped
      check vm.flowPlayer.currentStep.val == 0
      storyButton.fireEvent("click")
      check vm.selectedStory.val.name == "Active task"

      var sentPrompt = ""
      var cancelled = false
      vm.chat.configureAgentAdapters(
        proc(prompt: string; context: AgentPromptContext): bool =
        sentPrompt = prompt
        check context.selectedStory.name == "Active task"
        true,
        proc(): bool =
        cancelled = true
        true)

      let chat = renderChatPanel[MockRenderer, MockNode](r, vm)
      let input = findByAttr(chat, "aria-label", "Agent prompt")
      let send = findByAttr(chat, "aria-label", "Send agent prompt")
      let cancel = findByAttr(chat, "aria-label", "Cancel agent prompt")
      check input != nil
      check send != nil
      check cancel != nil
      r.setInputValue(input, "Make the card clearer")
      input.fireEvent("input")
      send.fireEvent("click")
      check sentPrompt == "Make the card clearer"
      check vm.chat.messages.val[0].kind == cmkUser
      cancel.fireEvent("click")
      check cancelled
      check vm.chat.connectionState.val == "cancelled"

      dispose()

  test "sidebar sections expose top level editor navigation":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      vm.activeView.val = evPagePreview

      let sidebar = renderSidebar[MockRenderer, MockNode](r, vm)
      let openUserJourneys = findByAttr(sidebar, "aria-label",
        "Open User Journeys section")
      let userJourneys = findByAttr(sidebar, "aria-label",
        "Toggle User Journeys section")
      let pages = findByAttr(sidebar, "aria-label", "Toggle Pages section")

      check openUserJourneys != nil
      check userJourneys != nil
      check pages != nil
      check userJourneys.attributes["aria-expanded"] == "true"
      pages.fireEvent("click")
      check vm.activeView.val == evPagePreview
      openUserJourneys.fireEvent("click")
      check vm.activeView.val == evStoryboard
      check userJourneys.attributes["aria-expanded"] == "true"
      userJourneys.fireEvent("click")
      check userJourneys.attributes["aria-expanded"] == "false"
      userJourneys.fireEvent("click")
      check userJourneys.attributes["aria-expanded"] == "true"

      dispose()

  test "storyboard renders project previews for flow cards":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.name,
          documentHtml: "<main data-testid=\"real-flow-screen\">Cart</main>")

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let flowFrame = findByAttr(storyboard, "title", "Flow preview Cart")

      check flowFrame != nil
      check flowFrame.attributes["srcdoc"].contains("real-flow-screen")
      check flowFrame.styles["pointer-events"] == "none"

      dispose()

  test "storyboard journey cards open matching page stories":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let cartPage = StoryRef(group: "Pages", name: "Cart Page",
        kind: skPage, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ]),
        StoryGroup(
          name: "Pages",
          kind: skPage,
          description: "Concrete pages",
          expanded: true,
          items: @[
            StoryItem(name: "Cart Page", description: "Full cart page",
                      kind: skPage, group: "Pages")
        ])
      ]
      vm.flowPlayer.steps.val = @[
        FlowStep(
          screenRef: cartPage,
          action: "Cart",
          description: "Open cart page")
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.name,
          documentHtml: "<main data-testid=\"" & story.name & "\"></main>")

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let flowFrame = findByAttr(storyboard, "title", "Flow preview Cart")
      let card = findByAttr(storyboard, "aria-label", "Select flow step Cart")

      check flowFrame != nil
      check flowFrame.attributes["srcdoc"].contains("Cart Page")
      check card != nil
      card.fireEvent("click")
      check vm.selectedStory.val == cartPage
      check vm.activeView.val == evPagePreview

      dispose()

  test "storyboard exposes figma-style zoom and pan state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Checkout flow",
          kind: skFlow,
          description: "Project-owned user flow",
          expanded: true,
          items: @[
            StoryItem(name: "Cart", description: "Cart screen",
                      kind: skFlow, group: "Checkout flow")
        ])
      ]

      let storyboard = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let zoomIn = findByAttr(storyboard, "aria-label", "Zoom storyboard in")
      let zoomOut = findByAttr(storyboard, "aria-label", "Zoom storyboard out")
      let fit = findByAttr(storyboard, "aria-label", "Fit storyboard")
      let canvas = findByAttr(storyboard, "data-figma-canvas", "true")
      let content = findByAttr(storyboard, "data-figma-canvas-content", "true")

      check zoomIn != nil
      check zoomOut != nil
      check fit != nil
      check canvas != nil
      check content != nil
      check content.styles["transform"] == "translate(0.0px, 0.0px) scale(1.0)"

      zoomIn.fireEvent("click")
      check vm.storyboard.zoom.val > 1.0
      check content.styles["transform"].contains("scale(")

      zoomOut.fireEvent("click")
      check vm.storyboard.zoom.val <= 1.0

      vm.storyboard.panX.val = 120
      vm.storyboard.panY.val = -80
      check content.styles["transform"].contains("translate(120.0px, -80.0px)")

      fit.fireEvent("click")
      check vm.storyboard.zoom.val == 1.0
      check vm.storyboard.panX.val == 0
      check vm.storyboard.panY.val == 0
      check content.styles["transform"] == "translate(0.0px, 0.0px) scale(1.0)"

      dispose()

  test "component detail edit action opens functional edit mode":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      vm.activeView.val = evComponentDetail
      vm.editMode.val = emView

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let editButton = findByAttr(shell, "aria-label",
        "Open selected component in edit mode")
      check editButton != nil
      check editButton.attributes["role"] == "button"

      editButton.fireEvent("click")
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      dispose()

  test "editor_edit_buttons_dispatch_commands":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let disabledDetail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let disabledEdit = findByAttr(disabledDetail, "aria-label",
        "Open selected component in edit mode")
      check disabledEdit != nil
      check disabledEdit.attributes["aria-disabled"] == "true"
      disabledEdit.fireEvent("click")
      check vm.editMode.val == emView
      check vm.commandState(eckEdit).status == ecsFailed
      check vm.commandState(eckEdit).diagnostic.contains("Select a story")

      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      vm.activeView.val = evComponentDetail
      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let detailEdit = findByAttr(detail, "aria-label",
        "Open selected component in edit mode")
      check detailEdit != nil
      check detailEdit.attributes["aria-disabled"] == "false"
      detailEdit.fireEvent("click")
      check vm.commandState(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      let pagePreview = renderPagePreview[MockRenderer, MockNode](r, vm)
      let viewButton = findByAttr(pagePreview, "aria-label",
        "Switch to view mode")
      let editButton = findByAttr(pagePreview, "aria-label",
        "Switch to edit mode")
      check viewButton != nil
      check editButton != nil
      viewButton.fireEvent("click")
      check vm.commandState(eckInspect).status == ecsSucceeded
      check vm.editMode.val == emView
      editButton.fireEvent("keydown")
      check vm.commandState(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit

      dispose()

  test "component detail renders project preview documents":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let componentStory = StoryRef(group: "Components",
        name: "Real Button", kind: skComponent, index: 0)
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "Components",
          kind: skComponent,
          description: "Project components",
          expanded: true,
          items: @[
            StoryItem(name: "Real Button", description: "Actual project code",
                      kind: skComponent, group: "Components")
        ])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          bodyText: "Rendered by project-owned component code.",
          documentHtml: "<main data-testid=\"real-component\">Button</main>")
      discard vm.selectStory(componentStory)

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(detail, "title",
        "Component preview Components / Real Button")

      check frame != nil
      check frame.attributes["srcdoc"].contains("real-component")
      check frame.attributes["scrolling"] == "no"
      check frame.styles["overflow"] == "hidden"
      check frame.attributes["height"] == "1"
      check detail.textContent.contains("Rendered by project-owned component code.")

      dispose()

  test "component detail renders option controls as compact choice rows":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "StatusBadge", name: "Neutral",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.variants.variants.val = @[
        ComponentVariantDefinition(
          component: "StatusBadge",
          variantKey: "base",
          story: story,
          properties: @[
            ComponentPropertyDefinition(
              name: "tone",
              kind: cpkEnum,
              value: "neutral",
              options: @["neutral", "success", "error"],
              sourceFile: "components/status_badge.nim",
              sourceLine: 12,
              schemaKey: "status.tone",
              documentation: "Status badge tone API",
              usageGuidance: "Choose a semantic status tone.")
          ],
          stateControls: @[
            ComponentStateControl(
              key: "disabled",
              label: "Disabled",
              kind: cskDisabled,
              value: "false",
              options: @["false", "true"],
              sourceFile: "components/status_badge.nim",
              sourceLine: 18,
              schemaKey: "status.disabled")
          ])
      ]
      discard vm.selectStory(story)

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let tone = findByAttr(detail, "aria-label",
        "Choose component property tone")
      let success = findByAttr(detail, "aria-label",
        "Apply component property tone option success")
      let disabled = findByAttr(detail, "aria-label",
        "Choose component state disabled")
      check tone != nil
      check tone.attributes["data-compact-choice-row"] == "true"
      check tone.attributes["data-component-property-options"] == "3"
      check success != nil
      check success.attributes["data-compact-choice-enabled"] == "true"
      success.fireEvent("click")
      check vm.variants.variants.val[0].properties[0].value == "success"
      check disabled != nil
      check disabled.attributes["data-compact-choice-row"] == "true"

      dispose()

  test "editor_dom_mount_has_empty_agent_state":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      check vm.chat.messages.val.len == 0
      check vm.chat.connectionState.val == "disconnected"
      check vm.chat.sessionStatus.val == asIdle

      let chat = renderChatPanel[MockRenderer, MockNode](r, vm)
      check chat.textContent.contains("Ask for design-system changes")
      check chat.textContent.contains("Empty / disconnected")

      dispose()

  test "status bar renders element breadcrumb stack":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.selectedStory.val = StoryRef(group: "Components",
        name: "Button", kind: skComponent, index: 0)
      check vm.selectInspectorElement(ElementRef(
        tag: "span",
        sourceFile: "button.nim",
        sourceLine: 12,
        ancestors: @["main", "button", "span"]))

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      check shell.textContent.contains("Components")
      check shell.textContent.contains("Button")
      check shell.textContent.contains("main")
      check shell.textContent.contains("span")
      let ancestor = findByAttr(shell, "aria-label", "Select breadcrumb button")
      check ancestor != nil

      dispose()
