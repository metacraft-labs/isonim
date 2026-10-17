## Dispatch real view callbacks through MockRenderer: it replaces only the
## display/event transport so item identity and reactive effects run headlessly.
## Registered in native CI: the JS vector view mounts Fabric on a DOM host,
## which MockNode cannot supply. Browser-adapter coverage belongs in Playwright.
import std/[unittest, tables]
import isonim/core/[signals, owner, computation]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, user_project_vms]
import isonim/editor/views/[task_views, chat_panel, vector_editor]
import isonim/components/task_manager
import isonim/theming/theme

proc byAttr(node: MockNode; name, value: string): seq[MockNode] =
  if node.attributes.getOrDefault(name) == value:
    result.add node
  for child in node.children:
    result.add byAttr(child, name, value)

suite "Loop callback identity":
  test "every task filter and its highlight retain their item":
    createRoot do (dispose: proc()):
      let vm = createTaskAppVM()
      let root = renderTaskApp[MockRenderer, MockNode](MockRenderer(), vm)
      let pills = root.children[^2].children
      require pills.len == 3
      for i in [1, 0, 2, 0]:
        pills[i].fireEvent("click")
        check vm.filterBar.currentFilter.val == FilterMode(i)
        for j, pill in pills:
          check pill.styles["background-color"] ==
            (if i == j: themeColor("primary") else: "transparent")
          check pill.children[0].styles["color"] ==
            (if i == j: "#FFFFFF" else: themeColor("text-secondary"))
      dispose()

  test "every suggested prompt inserts its own text":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let root = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      let chips = root.byAttr("aria-label", "Insert suggested prompt")
      require chips.len == 4
      # Prompt chips are native buttons: keyboard activation arrives as click.
      for chip in chips:
        vm.chat.inputText.val = ""
        chip.fireEvent("click")
        check vm.chat.inputText.val == chip.children[1].textContent
      dispose()

  test "each Allow and Deny answers only its own permission request":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.chat.permissionRequests.val = @[
        AgentPermissionRequest(id: "first", title: "First"),
        AgentPermissionRequest(id: "second", title: "Second"),
        AgentPermissionRequest(id: "third", title: "Third")]
      let root = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      # Each answer rebuilds the review rows and retires the replaced rows'
      # listeners, so every click targets the row currently displayed.
      let ids = ["first", "second", "third"]
      proc current(label: string): MockNode =
        let found = root.byAttr("aria-label", label)
        doAssert found.len == 1, "expected one control labelled " & label &
          ", found " & $found.len
        found[0]
      for i, id in ids:
        current("Allow agent permission " & id).fireEvent("click")
        for j, request in vm.chat.permissionRequests.val:
          check request.status == (if j < i: apsDenied elif j == i: apsGranted else: apsPending)
        current("Deny agent permission " & id).fireEvent("click")
        for j, request in vm.chat.permissionRequests.val:
          check request.status == (if j <= i: apsDenied else: apsPending)
      dispose()

  test "every carousel dot selects its own usage":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      var pages: seq[StoryItem]
      for i in 0 ..< 5:
        pages.add StoryItem(name: "Page " & $i, kind: skPage,
          group: "Pages", usesVectorSymbols: @["Symbol"])
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Vector Symbols", kind: skVectorSymbol,
          items: @[StoryItem(name: "Symbol", kind: skVectorSymbol, group: "Vector Symbols")]),
        StoryGroup(name: "Pages", kind: skPage, items: pages)]
      require vm.openVectorEditor(StoryRef(group: "Vector Symbols",
        name: "Symbol", kind: skVectorSymbol, index: 0))
      let root = renderVectorEditor[MockRenderer, MockNode](MockRenderer(), vm)
      var dots: seq[MockNode]
      for i in 0 ..< 5:
        dots.add root.byAttr("data-vector-usage-dot", $i)[0]
      for dotIndex in [3, 1, 4, 2, 0]:
        for event in ["click", "keydown"]:
          dots[dotIndex].fireEvent(event)
          check vm.vectorEditorUsageIndex.val == dotIndex
      dispose()

  test "review comment actions retain each comment id and inclusion state":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.review.annotations.val = @[
        ReviewAnnotation(id: "first", includedInPrompt: true),
        ReviewAnnotation(id: "second", includedInPrompt: false),
        ReviewAnnotation(id: "third", includedInPrompt: true)]
      let root = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      # Each action rebuilds the review rows and retires the replaced rows'
      # listeners, so every click targets the row currently displayed.
      proc current(label: string): MockNode =
        let found = root.byAttr("aria-label", label)
        doAssert found.len == 1, "expected one control labelled " & label &
          ", found " & $found.len
        found[0]
      for i, id in ["first", "second", "third"]:
        current((if i == 1: "Include" else: "Exclude") & " review comment " & id).fireEvent("click")
        check vm.review.annotations.val[i].includedInPrompt == (i == 1)
        # Resolve and Dismiss are offered only while a comment is open, so
        # alternate them: each must address only its own comment.
        let closed = if i mod 2 == 0: ransResolved else: ransDismissed
        current((if i mod 2 == 0: "Resolve" else: "Dismiss") &
          " review comment " & id).fireEvent("click")
        for j, annotation in vm.review.annotations.val:
          check annotation.state == (
            if j < i: (if j mod 2 == 0: ransResolved else: ransDismissed)
            elif j == i: closed
            else: ransOpen)
      dispose()

  test "rejecting a proposed edit addresses only that proposal":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.chat.proposedEdits.val = @[
        AgentEditProposal(id: "first"), AgentEditProposal(id: "second"),
        AgentEditProposal(id: "third")]
      let root = renderChatPanel[MockRenderer, MockNode](MockRenderer(), vm)
      # Each rejection rebuilds the proposal rows and retires the replaced
      # rows' listeners, so every click targets the row currently displayed.
      for i, id in ["first", "second", "third"]:
        let found = root.byAttr("aria-label", "Reject agent edit " & id)
        require found.len == 1
        found[0].fireEvent("click")
        for j, proposal in vm.chat.proposedEdits.val:
          check (proposal.status == aepsRejected) == (j <= i)
      dispose()
