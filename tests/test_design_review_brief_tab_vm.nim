## Historical REV-M2 entrypoint, now testing the current Spec pane contract.
## MockRenderer observes the real shell/Spec VM and reactive owners without
## a browser DOM. The optional mount observer captures the same production VM;
## it neither substitutes selection logic nor manufactures brief content.
## Native TipTap is an import placeholder: these tests do not claim browser
## editing, HTTP persistence, Markdown rendering or physical input coverage.
## The baked production index supplies real story/backend/multiple coverage;
## test_design_review_brief_index separately exercises real FS/parser inputs.

import std/[tables, strutils, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types]
import isonim/editor/design_review/[brief_index_static, brief_format]
import isonim/editor/views/[shell, spec_pane, design_review_mount]

proc find(node: MockNode; key, value: string): MockNode =
  if node.kind == mnkElement and node.attributes.getOrDefault(key) == value:
    return node
  for child in node.children:
    let found = find(child, key, value)
    if found != nil: return found

proc inbox(): StoryRef =
  StoryRef(group: "Task App / Pages", name: "Inbox", kind: skPage, index: 0)
proc appearance(): StoryRef =
  StoryRef(group: "Settings App / Group", name: "Appearance", kind: skComponent,
    index: 0)

suite "REV-M2 current Spec pane compatibility":
  test "covered story mounts title and complete body in editable Spec with AI":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.selectedStory.val = inbox()
      vm.setEditMode(emSpec)
      var spec: SpecPaneVM
      var observations = 0
      let node = renderEditorShell[MockRenderer, MockNode](MockRenderer(), vm,
        proc(mounted: SpecPaneVM) =
          spec = mounted
          inc observations)
      check observations == 1
      require spec != nil
      let idx = builtInBriefIndex()
      require "render.task-app" in idx.byBriefId
      check spec.markdown.val == "# Task App — cross-backend visual review\n\n" &
        idx.byBriefId["render.task-app"].bodyMarkdown
      check "The **Task App** demo" in spec.markdown.val
      check not spec.markdown.val.contains("schemaVersion:")
      check spec.mode.val == spmEdit
      check not spec.dirty.val
      check find(node, "data-spec-pane-mode", "edit") != nil
      check find(node, "data-sidebar-content", "ai-assistant") != nil
      check find(node, "data-preview-pane-tab", "brief") == nil
      dispose()

  test "multiple coverage prefers render and non-render falls back deterministically":
    let idx = builtInBriefIndex()
    require "Task App %2F Pages/Inbox:page#0@web" in idx.byPreview
    let ids = idx.byPreview["Task App %2F Pages/Inbox:page#0@web"]
    check ids.len > 1
    check ids[0] == "chrome.gallery-compare"
    check ids[^1] == "render.task-app"
    check resolveBriefId(inbox(), pbWeb) == "render.task-app"
    require "Settings App %2F Group/Appearance:component#0@web" in idx.byPreview
    check idx.byPreview["Settings App %2F Group/Appearance:component#0@web"] ==
      @["chrome.story-selected-laptop", "chrome.story-selected-wide"]
    check resolveBriefId(appearance(), pbWeb) == "chrome.story-selected-laptop"

  test "private routing snapshots agree and standalone callers remain isolated":
    let privateIndex = builtInBriefIndex()
    let otherIndex = builtInBriefIndex()
    require privateIndex != nil and otherIndex != nil
    check privateIndex != otherIndex
    for story in [inbox(), appearance(), StoryRef()]:
      for backend in PreviewBackend:
        check resolveBriefId(story, backend, privateIndex) ==
          resolveBriefId(story, backend)
    require "render.task-app" in privateIndex.byBriefId
    privateIndex.byBriefId.del("render.task-app")
    check resolveBriefId(inbox(), pbWeb, otherIndex) == "render.task-app"
    check resolveBriefId(inbox(), pbWeb) == "render.task-app"

  test "backend and uncovered selection reactively replace the actual mounted body":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.selectedStory.val = appearance()
      vm.setEditMode(emSpec)
      var spec: SpecPaneVM
      discard renderEditorShell[MockRenderer, MockNode](MockRenderer(), vm,
        proc(mounted: SpecPaneVM) = spec = mounted)
      require spec != nil
      let idx = builtInBriefIndex()
      check spec.markdown.val == "# Story Selected — laptop viewport\n\n" &
        idx.byBriefId["chrome.story-selected-laptop"].bodyMarkdown
      vm.platform.val = pbTui
      check spec.markdown.val == "# Spec\n\nNo brief available for the selected story."
      vm.selectedStory.val = inbox()
      check spec.markdown.val == "# Task App — cross-backend visual review\n\n" &
        idx.byBriefId["render.task-app"].bodyMarkdown
      vm.selectedStory.val = StoryRef(group: "uncovered", name: "uncovered",
        kind: skPage, index: 0)
      check spec.markdown.val == "# Spec\n\nNo brief available for the selected story."
      vm.selectedStory.val = StoryRef()
      check spec.markdown.val == "# Spec\n\nNo brief available for the selected story."
      dispose()

  test "unchanged brief preserves dirty edits while changed identity resets baseline":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.selectedStory.val = inbox()
      vm.setEditMode(emSpec)
      var spec: SpecPaneVM
      let node = renderEditorShell[MockRenderer, MockNode](MockRenderer(), vm,
        proc(mounted: SpecPaneVM) = spec = mounted)
      require spec != nil
      let saved = spec.lastSavedMarkdown.val
      spec.setMarkdown("# Unsaved user text")
      check spec.dirty.val
      let controls = find(node, "data-spec-pane-edit-controls", "true")
      require controls != nil
      check controls.styles.getOrDefault("display") == "flex"
      vm.platform.val = pbTui  # Same render brief: preserve the dirty body.
      check spec.markdown.val == "# Unsaved user text"
      check spec.lastSavedMarkdown.val == saved
      check spec.dirty.val
      vm.setEditMode(emView)
      vm.setEditMode(emSpec)
      check spec.markdown.val == "# Unsaved user text"
      check spec.mode.val == spmEdit
      vm.selectedStory.val = appearance() # TUI has no coverage: real identity change.
      check spec.markdown.val == "# Spec\n\nNo brief available for the selected story."
      check spec.lastSavedMarkdown.val == spec.markdown.val
      check not spec.dirty.val
      check controls.styles.getOrDefault("display") == "none"
      dispose()

  test "disposing the actual shell retires Spec selection and view subscriptions":
    var vm: EditorVM
    createRoot do (disposeVm: proc()):
      vm = createEditorVM()
      vm.selectedStory.val = inbox()
      vm.setEditMode(emSpec)
      let baseline = vm.selectedStory.observers.len
      var spec: SpecPaneVM
      var node: MockNode
      createRoot do (disposeShell: proc()):
        node = renderEditorShell[MockRenderer, MockNode](MockRenderer(), vm,
          proc(mounted: SpecPaneVM) = spec = mounted)
        require spec != nil
        check vm.selectedStory.observers.len > baseline
        check spec.markdown.observers.len > 0
        disposeShell()
      let retiredBody = spec.markdown.val
      let controls = find(node, "data-spec-pane-edit-controls", "true")
      require controls != nil
      let retiredDisplay = controls.styles.getOrDefault("display")
      check vm.selectedStory.observers.len == baseline
      check spec.markdown.observers.len == 0
      vm.selectedStory.val = appearance()
      vm.platform.val = pbTui
      check spec.markdown.val == retiredBody
      spec.setMarkdown("# After disposal")
      check controls.styles.getOrDefault("display") == retiredDisplay
      disposeVm()
    check vm.selectedStory.observers.len == 0
