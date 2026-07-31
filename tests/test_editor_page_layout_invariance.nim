## Layout-invariance regression test for the editor's View/Edit modes.
##
## Bug (operator-reported): opening a PAGE story in View mode then
## toggling the mode chip to Edit re-laid-out the previewed page — the
## composed page re-wrapped at a different width and chrome relocated —
## because entering emEdit swapped ``activeView`` from ``evPagePreview``
## (the viewport-sized device-frame render) to ``evComponentEdit`` (the
## source-edit canvas, an iframe sized to the fluid centre-column width).
## Switching back to View left the surface on ``evComponentEdit``, so the
## post-Edit layout never matched the pre-Edit layout.
##
## Invariant under test: for a given page story + viewport the previewed
## page renders IDENTICALLY across View / Comment / Edit — the surface the
## shell mounts (``activeView``) and the device-frame layout stay constant,
## and Edit only OVERLAYS the selection/inspector bridge on the same page
## render. Leaving Edit restores the exact prior surface (round-trip
## invariance). Component stories keep their evComponentDetail →
## evComponentEdit split unchanged.

import std/[unittest, strutils, tables]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/viewmodel
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/shell

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

const pageDocMarker = "isonim-page-layout-root"

proc buildPageVM(): EditorVM =
  let vm = createEditorVM()
  vm.sidebar.groups.val = @[
    StoryGroup(
      name: "Docs Shell", kind: skPage,
      description: "Composed docs pages", expanded: true,
      items: @[
        StoryItem(name: "Full page", description: "Full composed page",
                  kind: skPage, group: "Docs Shell")
    ])
  ]
  # The composed page document the Web iframe renders (srcdoc). A body
  # marker lets us assert the SAME base page markup is present in both
  # View and Edit; the editable-bridge marker (below) asserts Edit only
  # adds an overlay.
  vm.preview.hook = proc(story: StoryRef; platform: Platform): ProjectPreview =
    ProjectPreview(
      status: ppsRendered,
      story: story,
      title: story.name,
      documentHtml: "<main data-testid=\"" & pageDocMarker &
        "\">composed docs page</main>")
  vm

suite "Editor preview layout invariance across View/Edit":

  test "page story keeps the same preview surface + device-frame layout in View and Edit":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = buildPageVM()
      check vm.selectStory(StoryRef(group: "Docs Shell", name: "Full page",
        kind: skPage, index: 0))
      # Selecting a page story routes to the page-preview surface.
      check vm.activeView.val == evPagePreview

      # --- View mode ------------------------------------------------------
      vm.setEditMode(emView)
      check vm.activeView.val == evPagePreview
      let viewShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let viewPage = findByAttr(viewShell, "data-page-preview", "true")
      let viewEdit = findByAttr(viewShell, "data-component-edit", "true")
      check viewPage != nil
      check viewEdit != nil
      # The page-preview surface is the mounted one; the source-edit
      # canvas stays hidden.
      check viewPage.styles["display"] == "flex"
      check viewEdit.styles["display"] == "none"
      let viewFrame = findByAttr(viewShell, "aria-label", "Preview device frame")
      let viewIframe = findByAttr(viewShell, "data-page-project-frame", "true")
      check viewFrame != nil
      check viewIframe != nil
      let viewWidth = viewFrame.styles["width"]
      check viewWidth.len > 0
      let viewSrcdoc = viewIframe.attributes["srcdoc"]
      check viewSrcdoc.contains(pageDocMarker)
      # View mode does not inject the editor selection bridge.
      check not viewSrcdoc.contains("isonim-editor-selection-style")

      # --- Edit mode ------------------------------------------------------
      vm.setEditMode(emEdit)
      # THE FIX: entering Edit must NOT swap a page story to the
      # differently-laid-out source-edit canvas — the surface stays put.
      check vm.editMode.val == emEdit
      check vm.activeView.val == evPagePreview
      let editShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let editPage = findByAttr(editShell, "data-page-preview", "true")
      let editEdit = findByAttr(editShell, "data-component-edit", "true")
      check editPage != nil
      check editEdit != nil
      check editPage.styles["display"] == "flex"
      check editEdit.styles["display"] == "none"
      let editFrame = findByAttr(editShell, "aria-label", "Preview device frame")
      let editIframe = findByAttr(editShell, "data-page-project-frame", "true")
      check editFrame != nil
      check editIframe != nil
      # Same viewport → identical device-frame width (no re-layout).
      check editFrame.styles["width"] == viewWidth
      let editSrcdoc = editIframe.attributes["srcdoc"]
      # Same base page markup renders …
      check editSrcdoc.contains(pageDocMarker)
      # … with the selection/inspector bridge overlaid on top so Edit can
      # still select elements + drive the property inspector (variable
      # binding). The overlay is additive; the base layout is unchanged.
      check editSrcdoc.contains("isonim-editor-selection-style")

      # --- Round-trip back to View ---------------------------------------
      vm.setEditMode(emView)
      check vm.activeView.val == evPagePreview
      let backShell = renderEditorShell[MockRenderer, MockNode](r, vm)
      let backPage = findByAttr(backShell, "data-page-preview", "true")
      let backFrame = findByAttr(backShell, "aria-label", "Preview device frame")
      let backIframe = findByAttr(backShell, "data-page-project-frame", "true")
      check backPage.styles["display"] == "flex"
      # View-after == View-before: same surface, same width, no bridge.
      check backFrame.styles["width"] == viewWidth
      check not backIframe.attributes["srcdoc"].contains(
        "isonim-editor-selection-style")

      dispose()

  test "component story still opens the source-edit canvas in Edit (unchanged)":
    ## Guard against over-broadening the fix: component stories keep their
    ## existing evComponentDetail → evComponentEdit behavior.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.sidebar.groups.val = @[
        StoryGroup(
          name: "TaskRow", kind: skComponent,
          description: "Row component", expanded: true,
          items: @[
            StoryItem(name: "Active task", description: "Active state",
                      kind: skComponent, group: "TaskRow")
        ])
      ]
      check vm.selectStory(StoryRef(group: "TaskRow", name: "Active task",
        kind: skComponent, index: 0))
      check vm.activeView.val == evComponentDetail
      vm.setEditMode(emEdit)
      check vm.editMode.val == emEdit
      check vm.activeView.val == evComponentEdit
      # Leaving to View keeps the component-story behavior as it was.
      dispose()
