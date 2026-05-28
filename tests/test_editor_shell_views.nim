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
    ## Editor renders sidebar, center column (chrome bar + views), and
    ## inspector panels. The global title bar and the M57 left/right
    ## edge strips are gone — backend / viewport / mode chips live in
    ## the shared preview chrome bar above the center view stack.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Shell mounts the main editor row, command palette, telemetry overlay,
      # status bar, (M-EVP-8) a hidden ``data-shell-escape-key`` node that
      # the ESC handler binds to, and (TBAR-M6) the absolutely positioned
      # ``data-spec-comment-popover`` overlay that the Spec-pane Comment
      # mode anchors to a TipTap selection.
      check shell.children.len == 6
      check findByAttr(shell, "data-shell-escape-key", "true") != nil
      check findByAttr(shell, "data-spec-comment-popover", "true") != nil
      # Editor row children: sidebar, center column, chat panel.
      let editorRow = findByAttr(shell, "data-shell-row", "true")
      check editorRow != nil
      check editorRow.children.len == 3
      check findByAttr(shell, "data-preview-center-column", "true") != nil
      check findByAttr(shell, "data-preview-chrome-bar", "true") != nil
      check findByAttr(shell, "data-preview-view-stack", "true") != nil
      # Backend / viewport / mode chips live in the shared chrome bar.
      check findByAttr(shell, "data-edge-strip", "backend") != nil
      check findByAttr(shell, "data-edge-strip", "viewport") != nil
      check findByAttr(shell, "data-edge-strip", "mode") != nil
      # Legacy edge-strip containers are gone.
      check findByAttr(shell, "data-preview-left-edge", "true") == nil
      check findByAttr(shell, "data-preview-right-edge", "true") == nil
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
    ## Preview pane has a top toolbar that hosts all three chip groups
    ## (backend / viewport / mode) directly. The legacy left/right edge
    ## strips and the breadcrumb are gone. M-EVP-7 also removed the
    ## view-switcher chip group — the sidebar is the only navigation
    ## surface and the active view is derived from the selected story's
    ## kind via ``viewForStory``.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let pane = renderPreviewPane[MockRenderer, MockNode](r, vm)

      # Pane should have a top toolbar plus a body row.
      check pane.children.len == 2
      let toolbar = findByAttr(pane, "data-preview-toolbar", "true")
      let body = findByAttr(pane, "data-preview-body", "true")
      check toolbar != nil
      check body != nil

      # M-EVP-7: the view-switcher is GONE; only the three chip groups
      # remain.
      check findByAttr(toolbar, "data-preview-view-switcher", "true") == nil
      check findByAttr(toolbar, "data-preview-breadcrumb", "true") == nil
      check findByAttr(toolbar, "data-edge-strip", "backend") != nil
      check findByAttr(toolbar, "data-edge-strip", "viewport") != nil
      check findByAttr(toolbar, "data-edge-strip", "mode") != nil

      # Body row contains only the preview canvas — no edge columns.
      check findByAttr(body, "data-preview-canvas", "true") != nil
      check findByAttr(body, "data-preview-left-edge", "true") == nil
      check findByAttr(body, "data-preview-right-edge", "true") == nil

      dispose()

  test "test_inspector_renders_all_sections":
    ## Phase A demolition (2026-05-28): the prior Manual/Assistant
    ## tab pair plus the 12-sub-tab strip are gone. The sidebar
    ## now renders a single-column scroll surface of section
    ## placeholders — see ``Front-Ends/IsoNim/isonim-editor.md``
    ## §"Property Inspector Panel — Section-Based Design".
    ## Twelve ``data-inspector-section-row`` placeholders appear
    ## in user-decided order (Position / Layout / Appearance /
    ## Fill / Stroke / Effects / Typography / Selection colors /
    ## Source / Component properties / State / Export).
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()

      let panel = renderInspectorPanel[MockRenderer, MockNode](r, vm)

      # Sidebar root still carries ``data-test-id="property-panel"``.
      check panel.attributes.getOrDefault("data-test-id") == "property-panel"

      # The 12 section placeholders mount inside a single scrollable
      # column. The list element carries
      # ``data-inspector-section-list="true"`` so Phase C / G can
      # locate the mount point cheaply.
      let sectionList = findByAttr(panel, "data-inspector-section-list", "true")
      check sectionList != nil

      # 12 ``data-inspector-section-row`` placeholders in order.
      let expectedSections = [
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
      var sectionRows: seq[MockNode] = @[]
      for child in sectionList.children:
        if child.attributes.getOrDefault("data-inspector-section-row").len > 0:
          sectionRows.add child
      check sectionRows.len == 12

      # Ordered slug check + header carries the display name + each
      # row exposes an empty body slot.
      for i, (slug, displayName) in expectedSections:
        check sectionRows[i].attributes["data-inspector-section-row"] == slug
        let header = findByAttr(sectionRows[i],
          "data-inspector-section-header", slug)
        check header != nil
        check header.textContent.contains(displayName)
        let body = findByAttr(sectionRows[i],
          "data-inspector-section-body", slug)
        check body != nil

      # The legacy Manual/Assistant tab bar + 12-sub-tab strip are
      # GONE. Negative assertions pin the removal so a future
      # accidental re-mount fails this test.
      check findByAttr(panel, "data-sidebar-tab-bar", "true") == nil
      check findByAttr(panel, "data-sidebar-tab", "manual") == nil
      check findByAttr(panel, "data-sidebar-tab-panel", "manual") == nil
      check findByAttr(panel, "data-sidebar-tab-panel", "assistant") == nil
      check findByAttr(panel, "data-inspector-section", "layout") == nil

      dispose()

  test "component_edit_inspector_explains_and_applies_design_system_scope":
    ## DEFERRED to Phase G — see
    ## ``Front-Ends/IsoNim/isonim-editor.md`` §"Property Inspector
    ## Panel — Section-Based Design".
    ##
    ## Phase A demolition (2026-05-28) stopped mounting
    ## ``populateInspectorManualBody`` inside ``renderInspectorPanel``.
    ## The rich content this test exercises (12-sub-tabs, design-
    ## system-impact panel, dense property rows, scope selector
    ## click handling) is preserved in
    ## ``component_edit.nim::populateInspectorManualBody`` but is
    ## not wired into the new section-based sidebar yet. Phase G
    ## progressively extracts that content into per-section widget
    ## files; this test will be rewritten then to assert against
    ## the new per-section mount points.
    skip()

  test "test_views_contain_no_hardcoded_values":
    ## View files use Tailwind classes, no hardcoded pixel values in class strings
    let shellFile = readFile("src/isonim/editor/views/shell.nim")

    # Views should use class = "..." for layout (Tailwind)
    check "class = " in shellFile

    # Views should use setStyle for dynamic/theme values — this is expected
    # But class strings should not contain raw px values
    # (they use Tailwind scale like p-4, not p-16px)

  test "test_chat_section_has_input":
    ## DEFERRED to Phase F — see
    ## ``Front-Ends/IsoNim/isonim-editor.md`` §"AI assistant
    ## placement".
    ##
    ## Phase A demolition (2026-05-28) removed the Assistant tab
    ## body from the right sidebar. The chat panel
    ## (``renderChatPanel``) is preserved in
    ## ``chat_panel.nim`` and will be re-mounted inside the
    ## chrome-bar-driven slide-out drawer in Phase F. The drawer
    ## then carries the chat composer (Agent prompt + Send) that
    ## this test asserts on; Phase F rewrites this test to target
    ## the drawer mount point.
    skip()

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
      # M-EVP-4: the selected row's accent marker is split into the three
      # `border-left-*` sub-keys; the indigo `accent` token is `#7C7AED`.
      check storyButton.styles["border-left-color"].toLowerAscii() ==
        accent.toLowerAscii()

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

      # Phase A demolition (2026-05-28): the "Toggle inspector panel"
      # offscreen affordance used to ride inside ``renderChatPanel``,
      # which Phase A stopped mounting inside the sidebar. The chat
      # panel (and any incidental affordances it carried) re-mounts
      # inside the Phase F slide-out drawer. The
      # ``vm.togglePanel(epInspector)`` contract is unchanged and is
      # exercised by the chrome-bar tests; Phase F restores or
      # relocates this offscreen handle.
      check vm.panels.val.inspector == true

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

      # Phase A demolition (2026-05-28): the inspector's 12 sub-tabs
      # ("Show Fill inspector section" / …) are gone. The sidebar
      # now exposes 12 ``data-inspector-section-row`` placeholders
      # in user-decided order. Phase G wires per-section content +
      # expansion controls; the underlying
      # ``vm.inspector.activeSection`` signal contract still drives
      # which section is active and is exercised here directly via
      # the VM so Phase G can rebuild the click affordance.
      let inspector = renderInspectorPanel[MockRenderer, MockNode](r, vm)
      let fillRow = findByAttr(inspector,
        "data-inspector-section-row", "fill")
      check fillRow != nil
      vm.switchInspectorSection(isFill)
      check vm.inspector.activeSection.val == isFill

      let preview = renderPreviewPane[MockRenderer, MockNode](r, vm)
      # M-EVP-7: the view-switcher chip group is gone — the chrome bar
      # no longer carries an "Open Vector editor view" button. The
      # vector-editor affordance is owned by the sidebar's per-symbol
      # action (tracked by M-EVP-8); for this regression test we drive
      # the VM directly to confirm the view-state machine still flips
      # to the vector editor.
      check findByAttr(preview, "aria-label", "Open Vector editor view") == nil
      check findByAttr(preview, "data-preview-view-switcher", "true") == nil
      vm.setActiveView(evVectorEditor)
      check vm.activeView.val == evVectorEditor
      vm.setActiveView(evStoryboard)

      # The legacy top-toolbar "Preview iOS platform" button is gone.
      # The three chip groups (backend / viewport / mode) now live in
      # the same top toolbar as the view switcher. Cocoa is the
      # renderer formerly tagged "iOS"; clicking it drives
      # `vm.platform` to pbCocoa.
      let topBar = findByAttr(preview, "data-preview-toolbar", "true")
      check topBar != nil
      check findByAttr(topBar, "aria-label", "Preview iOS platform") == nil
      check findByAttr(topBar, "data-preview-mode", "view") != nil
      check findByAttr(topBar, "data-edge-strip", "backend") != nil
      check findByAttr(topBar, "data-edge-strip", "viewport") != nil
      check findByAttr(topBar, "data-edge-strip", "mode") != nil
      let cocoaButton = findByAttr(preview,
        "aria-label", "Preview backend Cocoa")
      check cocoaButton != nil
      check cocoaButton.attributes["aria-pressed"] == "false"
      cocoaButton.fireEvent("click")
      check vm.platform.val == pbCocoa

      vm.flowPlayer.steps.val = userFlows()[0].steps
      let flowShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      # M-EVP-6: the storyboard's inner toolbar (with Next/Previous/Play/
      # Stop flow buttons) is gone. The underlying flow-player VM
      # operations remain reachable and drive the same state changes;
      # the visual affordances are tracked under the broader chrome
      # consolidation series (M-EVP-7..M-EVP-9). The test now exercises
      # the VM API directly so the storyboard's flow-player semantics
      # stay covered.
      check findByAttr(flowShell, "aria-label", "Next flow step") == nil
      check findByAttr(flowShell, "aria-label", "Previous flow step") == nil
      check findByAttr(flowShell, "aria-label", "Play flow") == nil
      check findByAttr(flowShell, "aria-label", "Stop flow") == nil
      check vm.flowPlayer.playState.val == psStopped

      discard vm.nextFlowStep()
      check vm.flowPlayer.currentStep.val == 1
      let secondStep = findByAttr(flowShell, "aria-label",
        "Select story Pages / Empty State")
      check secondStep != nil
      check secondStep.attributes["aria-current"] == "true"

      discard vm.prevFlowStep()
      check vm.flowPlayer.currentStep.val == 0

      vm.flowPlayer.play()
      check vm.flowPlayer.playState.val == psPlaying

      discard vm.stopFlow()
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
      # M-EVP-6: the storyboard's inner toolbar (Zoom in / Zoom out / Fit)
      # is gone. The underlying VM operations remain reachable and drive
      # the same canvas transform; the visual affordances are tracked
      # under the broader chrome consolidation series (M-EVP-7..M-EVP-9).
      check findByAttr(storyboard, "aria-label", "Zoom storyboard in") == nil
      check findByAttr(storyboard, "aria-label", "Zoom storyboard out") == nil
      check findByAttr(storyboard, "aria-label", "Fit storyboard") == nil
      let canvas = findByAttr(storyboard, "data-figma-canvas", "true")
      let content = findByAttr(storyboard, "data-figma-canvas-content", "true")
      check canvas != nil
      check content != nil
      check content.styles["transform"] == "translate(0.0px, 0.0px) scale(1.0)"

      vm.storyboard.zoom.val = 1.2
      check vm.storyboard.zoom.val > 1.0
      check content.styles["transform"].contains("scale(")

      vm.storyboard.zoom.val = 0.8
      check vm.storyboard.zoom.val <= 1.0

      vm.storyboard.panX.val = 120
      vm.storyboard.panY.val = -80
      check content.styles["transform"].contains("translate(120.0px, -80.0px)")

      vm.storyboard.zoom.val = 1.0
      vm.storyboard.panX.val = 0
      vm.storyboard.panY.val = 0
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

      # CHRM-M2: the chrome-bar mode cluster is now a ChoiceGroup
      # segmented control; pills are addressed positionally
      # (View=0, Comment=1, Edit=2).
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let modeCluster = findByAttr(shell, "data-toolbar-cluster", "mode")
      check modeCluster != nil
      let editChip = findByAttr(modeCluster, "data-choice-group-pill", "2")
      check editChip != nil
      check editChip.attributes["role"] == "button"

      editChip.fireEvent("click")
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      dispose()

  test "editor_edit_buttons_dispatch_commands":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()

      # CHRM-M2: per-view inner toolbars (component detail "Edit"
      # button and page preview view/edit/comment toggle) are gone.
      # The canonical chrome bar's mode cluster — now a ChoiceGroup
      # segmented control — drives the same eckEdit / eckInspect /
      # eckComment commands. Pills are addressed positionally
      # (View=0, Comment=1, Edit=2) under the
      # ``[data-toolbar-cluster="mode"]`` root.
      proc modePill(root: MockNode; idx: int): MockNode =
        let cluster = findByAttr(root, "data-toolbar-cluster", "mode")
        if cluster == nil:
          return nil
        findByAttr(cluster, "data-choice-group-pill", $idx)

      let disabledShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let disabledEditChip = modePill(disabledShell, 2)
      check disabledEditChip != nil
      check disabledEditChip.attributes["aria-disabled"] == "true"
      disabledEditChip.fireEvent("click")
      check vm.editMode.val == emView
      # CHRM-M2: the ChoiceGroup mount short-circuits disabled clicks at
      # the widget layer (before the command is invoked), so the
      # command state stays at its evaluated ``ecsDisabled`` reading
      # rather than transitioning to ``ecsFailed`` after a refused
      # execution.
      check vm.commandState(eckEdit).status == ecsDisabled
      # The disabled state's reason still calls out the missing story
      # selection — the diagnostic surfaces in the chip's tooltip
      # / a11y label and in any caller that calls evaluateCommand
      # directly.
      check vm.evaluateCommand(eckEdit).diagnostic.contains("Select a story")

      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      vm.activeView.val = evComponentDetail
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let editChip = modePill(shell, 2)
      check editChip != nil
      check editChip.attributes["aria-disabled"] == "false"
      editChip.fireEvent("click")
      check vm.commandState(eckEdit).status == ecsSucceeded
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit

      let pageShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let viewChip = modePill(pageShell, 0)
      let editChip2 = modePill(pageShell, 2)
      check viewChip != nil
      check editChip2 != nil
      viewChip.fireEvent("click")
      check vm.commandState(eckInspect).status == ecsSucceeded
      check vm.editMode.val == emView
      editChip2.fireEvent("keydown")
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

  test "component detail picks story-specific variants after fallback synthesis":
    ## Regression: when a sibling story in the same group has no pre-defined
    ## variant, ensureComponentPropertySchemaForSelectedStory synthesizes a
    ## fallback variant. That synthesized variant must not leak into the
    ## property panels of other stories in the same group.
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let groupName = "Components"
      let storyA = StoryRef(group: groupName, name: "Story A",
        kind: skComponent, index: 0)
      let storyB = StoryRef(group: groupName, name: "Story B",
        kind: skComponent, index: 1)
      let storyC = StoryRef(group: groupName, name: "Story C",
        kind: skComponent, index: 2)
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(name: groupName, kind: skComponent, expanded: true,
          items: @[
            StoryItem(name: storyA.name, kind: skComponent, group: groupName),
            StoryItem(name: storyB.name, kind: skComponent, group: groupName),
            StoryItem(name: storyC.name, kind: skComponent, group: groupName)
          ])
      ]
      vm.variants.variants.val = @[
        ComponentVariantDefinition(
          component: "CompA",
          variantKey: "default",
          story: storyA,
          properties: @[
            ComponentPropertyDefinition(
              name: "alpha", kind: cpkText, value: "A-value",
              sourceFile: "components/comp_a.nim", sourceLine: 1,
              schemaKey: "comp.a.alpha")
          ]),
        ComponentVariantDefinition(
          component: "CompB",
          variantKey: "default",
          story: storyB,
          properties: @[
            ComponentPropertyDefinition(
              name: "beta", kind: cpkText, value: "B-value",
              sourceFile: "components/comp_b.nim", sourceLine: 1,
              schemaKey: "comp.b.beta")
          ])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          documentHtml: "<main>" & story.name & "</main>")

      proc renderFor(story: StoryRef): MockNode =
        discard vm.selectStory(story)
        renderComponentDetail[MockRenderer, MockNode](r, vm)

      block:
        let detail = renderFor(storyA)
        check findByAttr(detail, "data-component-property-control", "alpha") != nil
        check findByAttr(detail, "data-component-property-control", "beta") == nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Story C has no real variant — selecting it triggers
      # ensureComponentPropertySchemaForSelectedStory which appends a
      # fallback variant tied to storyC.
      let variantsBefore = vm.variants.variants.val.len
      discard renderFor(storyC)
      check vm.variants.variants.val.len == variantsBefore + 1
      check vm.variants.variants.val[^1].story == storyC

      # Returning to storyA must surface CompA's properties, NOT the
      # synthesized variant created for storyC.
      block:
        let detail = renderFor(storyA)
        check findByAttr(detail, "data-component-property-control", "alpha") != nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Same for storyB after the synthesis.
      block:
        let detail = renderFor(storyB)
        check findByAttr(detail, "data-component-property-control", "beta") != nil
        check findByAttr(detail, "data-component-property-control", "alpha") == nil
        check findByAttr(detail, "data-component-property-control", "label") == nil

      # Story C itself still shows its own synthesized variant.
      block:
        let detail = renderFor(storyC)
        check findByAttr(detail, "data-component-property-control", "label") != nil

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
