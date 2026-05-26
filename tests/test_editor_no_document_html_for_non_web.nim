## CHRM-M5 Fix B — assert the iframe-srcdoc ``documentHtml`` path is
## Web-only.
##
## The user reported that "after clicking on the buttons in the top
## bar for a while, the preview switched back to HTML rendering" —
## that's the ``preview.documentHtml`` srcdoc branch firing in the
## non-Web case when the canvas wasn't otherwise active. CHRM-M5
## gates the srcdoc branch on ``vm.platform.val == pbWeb`` across
## the three view files that consume ``documentHtml``:
##
##   * ``views/page_preview.nim``
##   * ``views/foundations_page.nim``
##   * ``views/component_detail.nim``
##
## CHRM-M5b extends the same gate to the two remaining consumers
## the original audit missed:
##
##   * ``views/storyboard.nim`` — the flow-card thumbnails
##   * ``views/component_edit.nim`` — the editable preview iframe
##
## The ``ProjectPreview.documentHtml`` field itself is preserved
## because the Web composition root genuinely needs it (Web has no
## streaming launcher — the editor itself is HTML, so the
## per-backend ``documentHtml`` IS the live Web render). This test
## locks in the Web-only invariant by exercising each view against
## a non-Web backend with a non-empty ``documentHtml`` and asserting
## the iframe's ``srcdoc`` attribute is empty.

import std/[options, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/viewmodels
import isonim/editor/types
import isonim/editor/views/page_preview
import isonim/editor/views/component_detail
import isonim/editor/views/component_edit
import isonim/editor/views/foundations_page
import isonim/editor/views/storyboard

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

suite "CHRM-M5 Fix B: documentHtml iframe is Web-only":

  test "component_detail: non-Web backends never write documentHtml into the iframe srcdoc":
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let r = MockRenderer()
        let vm = createEditorVM()
        let story = StoryRef(group: "Components", name: "Real Button",
          kind: skComponent, index: 0)
        vm.sidebar.groups.val = @[
          StoryGroup(name: "Components", kind: skComponent, expanded: true,
            items: @[StoryItem(name: story.name, kind: story.kind,
              group: story.group)])
        ]
        # The project hook intentionally provides a non-empty
        # ``documentHtml`` even for non-Web backends — the user's
        # observed regression was exactly this case (HTML themed
        # output mounted into the iframe for a non-Web backend).
        vm.preview.hook = proc(story: StoryRef;
            platform: Platform): ProjectPreview =
          ProjectPreview(
            status: ppsRendered,
            story: story,
            title: story.group & " / " & story.name,
            bodyText: "Rendered by project-owned component code.",
            documentHtml: "<main>HTML-themed body</main>")
        discard vm.selectStory(story)
        vm.platform.val = backend

        let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
        let frame = findByAttr(detail, "data-component-project-frame", "true")
        check frame != nil
        # CHRM-M5 invariant: non-Web platforms NEVER load the
        # documentHtml into the iframe's srcdoc, regardless of
        # whether the canvas is active. The canvas takes over
        # above for non-Web; the iframe is dormant.
        check frame.attributes.getOrDefault("srcdoc", "") == ""
      dispose()

  test "component_detail: pbWeb still mounts documentHtml into the iframe":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "Components", name: "Real Button",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: story.group & " / " & story.name,
          bodyText: "Web body",
          documentHtml: "<main data-testid=\"web-component\">Button</main>")
      discard vm.selectStory(story)
      vm.platform.val = pbWeb

      let detail = renderComponentDetail[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(detail, "data-component-project-frame", "true")
      check frame != nil
      # Web composition root renders inside the iframe — the
      # srcdoc must carry the documentHtml.
      check "web-component" in frame.attributes.getOrDefault("srcdoc", "")
      dispose()

  test "page_preview: non-Web backends never write documentHtml into the iframe srcdoc":
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let r = MockRenderer()
        let vm = createEditorVM()
        # The page-preview view's HTML-srcdoc branch fires for
        # non-Page stories as well (the audit's exact concern —
        # see the elif at page_preview.nim:215-227 pre-CHRM-M5),
        # so exercise it with a Component story to hit that path.
        let story = StoryRef(group: "Components", name: "Card",
          kind: skComponent, index: 0)
        vm.sidebar.groups.val = @[
          StoryGroup(name: "Components", kind: skComponent, expanded: true,
            items: @[StoryItem(name: story.name, kind: story.kind,
              group: story.group)])
        ]
        vm.preview.hook = proc(story: StoryRef;
            platform: Platform): ProjectPreview =
          ProjectPreview(
            status: ppsRendered,
            story: story,
            title: story.group & " / " & story.name,
            bodyText: "non-Web preview body",
            documentHtml: "<main>HTML-themed body</main>")
        discard vm.selectStory(story)
        vm.platform.val = backend

        let pane = renderPagePreview[MockRenderer, MockNode](r, vm)
        let frame = findByAttr(pane, "data-page-project-frame", "true")
        check frame != nil
        # The user's reported regression: the iframe re-loaded
        # the HTML body after clicking around the top bar. With
        # CHRM-M5 the srcdoc stays empty for every non-Web
        # backend, regardless of which story is active.
        check frame.attributes.getOrDefault("srcdoc", "") == ""
      dispose()

  test "page_preview: pbWeb still mounts documentHtml into the iframe":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "Components", name: "Card",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: "Web Card",
          bodyText: "Web body",
          documentHtml: "<main data-testid=\"web-card\">Card</main>")
      discard vm.selectStory(story)
      vm.platform.val = pbWeb

      let pane = renderPagePreview[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(pane, "data-page-project-frame", "true")
      check frame != nil
      check "web-card" in frame.attributes.getOrDefault("srcdoc", "")
      dispose()

  test "foundations_page: non-Web backends never write documentHtml into the iframe srcdoc":
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let r = MockRenderer()
        let vm = createEditorVM()
        let story = StoryRef(group: "Typography", name: "Headings",
          kind: skFoundation, index: 0)
        vm.sidebar.groups.val = @[
          StoryGroup(name: "Typography", kind: skFoundation, expanded: true,
            items: @[StoryItem(name: story.name, kind: story.kind,
              group: story.group)])
        ]
        vm.preview.hook = proc(story: StoryRef;
            platform: Platform): ProjectPreview =
          ProjectPreview(
            status: ppsRendered,
            story: story,
            title: story.group & " / " & story.name,
            bodyText: "Foundation body",
            documentHtml: "<main>HTML-themed foundation</main>")
        discard vm.selectStory(story)
        vm.platform.val = backend

        let pane = renderFoundationsPage[MockRenderer, MockNode](r, vm)
        let frame = findByAttr(pane, "data-foundation-project-frame", "true")
        check frame != nil
        # Foundation HTML iframe path is Web-only after CHRM-M5;
        # non-Web backends use the canvas mount instead.
        check frame.attributes.getOrDefault("srcdoc", "") == ""
      dispose()

  test "foundations_page: pbWeb still mounts documentHtml into the iframe":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "Typography", name: "Headings",
        kind: skFoundation, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Typography", kind: skFoundation, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: "Web Typography",
          bodyText: "Web foundation",
          documentHtml: "<main data-testid=\"web-foundation\">Typography</main>")
      discard vm.selectStory(story)
      vm.platform.val = pbWeb

      let pane = renderFoundationsPage[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(pane, "data-foundation-project-frame", "true")
      check frame != nil
      check "web-foundation" in frame.attributes.getOrDefault("srcdoc", "")
      dispose()

  test "storyboard: non-Web backends never render the documentHtml flow-card iframe":
    # CHRM-M5b: the flow-card thumbnail in the storyboard canvas
    # previously consumed ``documentHtml`` regardless of backend,
    # so a TUI / GPUI / Freya / Cocoa / Android session would
    # display HTML-themed thumbnails. The platform gate routes
    # every non-Web backend to ``renderGenericMiniPreview``
    # (project-neutral mini snapshot); no ``data-flow-mini-preview``
    # iframe is created at all.
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        let r = MockRenderer()
        let vm = createEditorVM()
        let flowStory = StoryRef(group: "Flows", name: "Onboarding",
          kind: skFlow, index: 0)
        vm.sidebar.groups.val = @[
          StoryGroup(name: "Flows", kind: skFlow, expanded: true,
            items: @[StoryItem(name: "Open app", kind: skFlow,
              group: "Flows")])
        ]
        vm.preview.hook = proc(story: StoryRef;
            platform: Platform): ProjectPreview =
          ProjectPreview(
            status: ppsRendered,
            story: story,
            title: story.group & " / " & story.name,
            bodyText: "Flow body",
            documentHtml: "<main data-testid=\"flow-html\">Step</main>")
        discard vm.selectStory(flowStory)
        vm.platform.val = backend

        let pane = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
        let frame = findByAttr(pane, "data-flow-mini-preview", "true")
        # For non-Web backends the flow-card thumbnail never builds
        # the HTML iframe — the storyboard returns the
        # project-neutral mini preview instead, so the
        # ``data-flow-mini-preview`` iframe is absent from the tree.
        check frame == nil
      dispose()

  test "storyboard: pbWeb still mounts documentHtml into the flow-card iframe":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let flowStory = StoryRef(group: "Flows", name: "Onboarding",
        kind: skFlow, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Flows", kind: skFlow, expanded: true,
          items: @[StoryItem(name: "Open app", kind: skFlow,
            group: "Flows")])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: "Web Flow",
          bodyText: "Web flow body",
          documentHtml: "<main data-testid=\"web-flow\">Step</main>")
      discard vm.selectStory(flowStory)
      vm.platform.val = pbWeb

      let pane = renderStoryboardCanvas[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(pane, "data-flow-mini-preview", "true")
      check frame != nil
      check "web-flow" in frame.attributes.getOrDefault("srcdoc", "")
      dispose()

  test "component_edit: non-Web backends never write documentHtml into the editable iframe srcdoc":
    # CHRM-M5b: the editable component view's iframe is an HTML
    # selection-bridge surface — the editor injects bridge JS into
    # the project ``documentHtml`` so users can click elements to
    # select them. For non-Web backends the HTML surface
    # misrepresents what the actual backend renders, and the
    # canvas-mounted live-stream lives in the detail view. Gate
    # the srcdoc on Web; non-Web blanks it.
    createRoot do (dispose: proc()):
      for backend in [pbTui, pbGpui, pbFreya, pbCocoa, pbAndroid]:
        for mode in [emView, emEdit]:
          let r = MockRenderer()
          let vm = createEditorVM()
          let story = StoryRef(group: "Components", name: "Real Button",
            kind: skComponent, index: 0)
          vm.sidebar.groups.val = @[
            StoryGroup(name: "Components", kind: skComponent, expanded: true,
              items: @[StoryItem(name: story.name, kind: story.kind,
                group: story.group)])
          ]
          vm.preview.hook = proc(story: StoryRef;
              platform: Platform): ProjectPreview =
            ProjectPreview(
              status: ppsRendered,
              story: story,
              title: story.group & " / " & story.name,
              bodyText: "Editable component body",
              documentHtml: "<main data-testid=\"edit-html\"><body>x</body></main>")
          discard vm.selectStory(story)
          vm.platform.val = backend
          vm.editMode.val = mode

          let pane = renderComponentEditView[MockRenderer, MockNode](r, vm)
          let frame = findByAttr(pane, "data-component-edit-frame", "true")
          check frame != nil
          check frame.attributes.getOrDefault("srcdoc", "") == ""
      dispose()

  test "component_edit: pbWeb still mounts documentHtml into the editable iframe":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      let story = StoryRef(group: "Components", name: "Real Button",
        kind: skComponent, index: 0)
      vm.sidebar.groups.val = @[
        StoryGroup(name: "Components", kind: skComponent, expanded: true,
          items: @[StoryItem(name: story.name, kind: story.kind,
            group: story.group)])
      ]
      vm.preview.hook = proc(story: StoryRef;
          platform: Platform): ProjectPreview =
        ProjectPreview(
          status: ppsRendered,
          story: story,
          title: "Web Component",
          bodyText: "Web edit body",
          documentHtml: "<main data-testid=\"web-edit\"><body>x</body></main>")
      discard vm.selectStory(story)
      vm.platform.val = pbWeb
      vm.editMode.val = emView

      let pane = renderComponentEditView[MockRenderer, MockNode](r, vm)
      let frame = findByAttr(pane, "data-component-edit-frame", "true")
      check frame != nil
      check "web-edit" in frame.attributes.getOrDefault("srcdoc", "")
      dispose()
