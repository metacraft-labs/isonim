## CHRM-M2 — assertion that the legacy in-pane Preview/Brief tab strip
## is gone from the editor view stack.
##
## The strip used to mount below the chrome bar via
## ``preview_pane.mountBriefTabIntoPreviewPane`` (called from
## ``shell.nim:2519`` in the pre-CHRM-M2 tree). CHRM-M2 deletes the
## mount + the ``preview_pane.nim`` + ``brief_tab.nim`` + the
## ``design_review/markdown.nim`` renderer.
##
## This test mounts the full editor shell against a story covered by a
## brief and asserts the deleted DOM markers are absent.

import std/[options, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/stories
import isonim/editor/views/shell

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc findAllByAttr(node: MockNode; name, value: string): seq[MockNode] =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    result.add node
  for child in node.children:
    result.add findAllByAttr(child, name, value)

suite "CHRM-M2 in-pane mode-toggle row removed":

  test "no in-pane brief tab strip below the chrome bar":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      # Pick a story that the pre-CHRM-M2 strip would have shown for.
      # The exact story doesn't matter — the strip is unconditionally
      # gone after CHRM-M2.
      vm.selectedStory.val = StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0)

      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # Every DOM marker the deleted strip used to emit must be absent.
      for marker in [
          "data-preview-pane-brief-strip",
          "data-preview-pane-tabs",
          "data-preview-pane-brief-host",
          "data-design-review-brief-tab",
          "data-design-review-brief-header",
          "data-design-review-brief-subtabs",
          "data-design-review-brief-chips",
          "data-design-review-brief-body",
          "data-design-review-brief-actions",
          "data-design-review-review-button",
          "data-design-review-brief-empty"]:
        check findByAttr(shell, marker, "true") == nil

      # Per-tab markers (``data-preview-pane-tab="preview"`` /
      # ``data-preview-pane-tab="brief"``) also gone.
      check findByAttr(shell, "data-preview-pane-tab", "preview") == nil
      check findByAttr(shell, "data-preview-pane-tab", "brief") == nil
      dispose()

  test "no review-preview button after CHRM-M5":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.sidebar.groups.val = buildStoryboard()
      let shell = renderEditorShell[MockRenderer, MockNode](r, vm)

      # CHRM-M5 deleted the "Review this preview" button: the
      # campaign workflow + AI Assistant chat sidebar cover the
      # same affordance, and the user reported the button as
      # confusing. The DOM marker must be absent.
      let btn = findByAttr(shell, "data-chrome-action", "review-preview")
      check btn == nil
      dispose()
