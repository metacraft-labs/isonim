## REV-M2: ViewModel-level tests for the brief tab.
##
## Drives ``BriefTabVM`` directly with hand-built ``Brief`` objects so
## we don't have to touch the filesystem. The view itself is mounted
## under a ``MockRenderer`` to exercise the DOM construction path and
## confirm ``ui:`` DSL output is well-formed.
##
## Test names match REV-M2's Verification block verbatim.

import std/[unittest, options, tables, strutils, algorithm]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/markdown
import isonim/editor/views/brief_tab
import isonim/editor/types

# --------------------------------------------------------------------------- #
#  Fixtures — small hand-built briefs so tests are self-contained.
# --------------------------------------------------------------------------- #

proc mkStoryRef(group, name: string; kind: StoryKind = skPage;
                index = 0): StoryRef =
  StoryRef(group: group, name: name, kind: kind, index: index)

proc mkCoverage(s: StoryRef; backends: openArray[PreviewBackend]):
                BriefPreviewCoverage =
  BriefPreviewCoverage(storyRef: s, backends: @backends)

proc mkBrief(briefId, title: string; kind: BriefKind;
             coversPreviews: openArray[BriefPreviewCoverage];
             viewports: openArray[BriefViewport] = @[];
             dimensions: openArray[BriefScoringDimension] = @[];
             body: string = ""): Brief =
  result.briefId = briefId
  result.schemaVersion = 1
  result.kind = kind
  result.title = title
  result.coversPreviews = @coversPreviews
  result.captureViewports = @viewports
  result.reviewerSchemaVersion = 1
  result.scoringDimensions = @dimensions
  result.relatedBriefs = @[]
  result.extra = initTable[string, string]()
  result.bodyMarkdown = body
  result.sourceFile = "<test>"

proc mkIndex(briefs: varargs[Brief]): BriefIndex =
  result = BriefIndex(
    byBriefId: initOrderedTable[string, Brief](),
    byPreview: initOrderedTable[string, seq[string]](),
    errors: @[]
  )
  for b in briefs:
    result.byBriefId[b.briefId] = b
  for b in briefs:
    for cov in b.coversPreviews:
      for backend in cov.backends:
        let previewId = canonicalPreviewId(cov.storyRef, backend)
        if previewId notin result.byPreview:
          result.byPreview[previewId] = @[]
        var lst = result.byPreview[previewId]
        if b.briefId notin lst:
          lst.add b.briefId
          result.byPreview[previewId] = lst
  # Maintain alphabetical ordering so memo output is stable.
  for previewId, ids in result.byPreview.mpairs:
    var sorted = ids
    sorted.sort()
    result.byPreview[previewId] = sorted

# --------------------------------------------------------------------------- #
#  Tests
# --------------------------------------------------------------------------- #

suite "REV-M2 brief tab VM":

  test "test_brief_tab_vm_visible_for_covered_preview":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "Task App",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])])
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.briefTabVisible.val == true
      check vm.availableBriefs.val.len == 1
      check vm.availableBriefs.val[0].briefId == "render.task-app"
      dispose()

  test "test_brief_tab_vm_hidden_for_uncovered_preview":
    createRoot do (dispose: proc()):
      let coveredStory = mkStoryRef("Task App", "Inbox")
      let uncoveredStory = mkStoryRef("Settings App", "Theme")
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "Task App",
        kind = bkRender,
        coversPreviews = [mkCoverage(coveredStory, [pbWeb])])
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(uncoveredStory))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.briefTabVisible.val == false
      check vm.availableBriefs.val.len == 0
      dispose()

  test "test_brief_tab_vm_lists_all_briefs_for_preview":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let briefA = mkBrief(
        briefId = "render.alpha",
        title = "Alpha brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])])
      let briefB = mkBrief(
        briefId = "render.zebra",
        title = "Zebra brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])])
      let idx = mkIndex(briefA, briefB)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      let listed = vm.availableBriefs.val
      check listed.len == 2
      # Index ordering is alphabetical by briefId.
      check listed[0].briefId == "render.alpha"
      check listed[1].briefId == "render.zebra"
      dispose()

  test "test_brief_tab_vm_active_brief_default_is_first":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let briefA = mkBrief(
        briefId = "render.alpha",
        title = "Alpha brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])])
      let briefB = mkBrief(
        briefId = "render.zebra",
        title = "Zebra brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])])
      let idx = mkIndex(briefA, briefB)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.activeBriefIndex.val == 0
      check vm.activeBrief.val.isSome
      check vm.activeBrief.val.get.briefId == vm.availableBriefs.val[0].briefId
      dispose()

  test "test_brief_tab_vm_switching_active_brief_changes_rendered":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let briefA = mkBrief(
        briefId = "render.alpha",
        title = "Alpha brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])],
        body = "# Hello\n\nworld")
      let briefB = mkBrief(
        briefId = "render.zebra",
        title = "Zebra brief",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])],
        body = "# Bye\n\nfolks")
      let idx = mkIndex(briefA, briefB)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.activeBriefIndex.val == 0
      # alpha is first (alphabetical), so its body renders first.
      check vm.rendered.val == "<h1>Hello</h1>\n<p>world</p>"
      vm.activeBriefIndex.val = 1
      check vm.rendered.val == "<h1>Bye</h1>\n<p>folks</p>"
      dispose()

  test "test_brief_tab_vm_strips_frontmatter_from_body":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      # parseBrief strips frontmatter before populating bodyMarkdown.
      # We simulate that here: bodyMarkdown only contains the post-`---`
      # block. The frontmatter delimiters must NOT leak into rendered.
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "T",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])],
        body = "\n# Title\n")
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.rendered.val == "<h1>Title</h1>"
      check "---" notin vm.rendered.val
      check "briefId" notin vm.rendered.val
      dispose()

  test "test_brief_tab_vm_emits_chips_for_all_frontmatter_fields":
    createRoot do (dispose: proc()):
      let storyRef1 = mkStoryRef("Task App", "Inbox")
      let storyRef2 = mkStoryRef("Task App", "Completed")
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "Task App",
        kind = bkRender,
        coversPreviews = [
          mkCoverage(storyRef1, [pbWeb]),
          mkCoverage(storyRef2, [pbWeb])
        ],
        viewports = [
          BriefViewport(width: 1080, height: 720, label: "tablet"),
          BriefViewport(width: 1920, height: 1080, label: "wide")
        ],
        dimensions = [
          BriefScoringDimension(id: "chrome", label: "Editor Chrome",
                                weight: 0.4, scaleMin: 1, scaleMax: 10),
          BriefScoringDimension(id: "rendering", label: "App Rendering",
                                weight: 0.6, scaleMin: 1, scaleMax: 10)
        ])
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef1))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      let chips = vm.chips.val
      # One chip for kind, one for coversPreviews count, one per
      # viewport (2), one per dimension (2).
      check chips.len == 1 + 1 + 2 + 2
      check chips[0].kind == bckKind
      check chips[0].value == "render"
      check chips[1].kind == bckCount
      check chips[1].value == "2 previews"
      check chips[2].kind == bckViewport
      check chips[2].label == "tablet"
      check chips[2].value == "1080x720"
      check chips[3].kind == bckViewport
      check chips[3].label == "wide"
      check chips[3].value == "1920x1080"
      check chips[4].kind == bckDimension
      check chips[4].label == "Editor Chrome"
      check chips[4].value == "0.40"
      check chips[5].kind == bckDimension
      check chips[5].label == "App Rendering"
      check chips[5].value == "0.60"
      dispose()

  test "test_brief_tab_view_uses_ui_dsl_not_setstyle":
    ## Mount the brief tab into the mock renderer and assert that the
    ## constructed DOM is non-empty. The byte-level "no setStyle" check
    ## is enforced by ``test_design_review_brief_tab_no_setstyle.nim``;
    ## here we only confirm the view is mountable end-to-end and that
    ## the DSL-only construction path produces the expected attributes.
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "Task App",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb])],
        body = "# Hello\n\nworld")
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)

      let r = MockRenderer()
      let parent = createElement(r, "div")
      mountBriefTab[MockRenderer, MockNode](r, parent, vm)

      check parent.children.len == 1
      let root = parent.children[0]
      check root.attributes.getOrDefault(
        "data-design-review-brief-tab") == "true"
      check root.attributes.getOrDefault(
        "data-design-review-brief-visible") == "true"
      dispose()

  test "test_brief_tab_vm_changes_when_backend_changes":
    createRoot do (dispose: proc()):
      let storyRef = mkStoryRef("Task App", "Inbox")
      let brief = mkBrief(
        briefId = "render.task-app",
        title = "Task App",
        kind = bkRender,
        coversPreviews = [mkCoverage(storyRef, [pbWeb, pbAndroid])])
      let idx = mkIndex(brief)
      let activeStory = createSignal[Option[StoryRef]](some(storyRef))
      let activeBackend = createSignal(pbWeb)
      let vm = createBriefTabVM(idx, activeStory, activeBackend)
      check vm.briefTabVisible.val == true
      activeBackend.val = pbAndroid
      check vm.briefTabVisible.val == true
      activeBackend.val = pbIos
      check vm.briefTabVisible.val == false
      check vm.availableBriefs.val.len == 0
      dispose()

  test "markdown_renderer_handles_supported_subset":
    ## Sanity: ensure the markdown helper covers the headings,
    ## paragraphs, fenced code, inline code, and links the brief tab
    ## relies on.
    check renderMarkdown("# Title") == "<h1>Title</h1>"
    check renderMarkdown("## Subhead") == "<h2>Subhead</h2>"
    check renderMarkdown("### Three") == "<h3>Three</h3>"
    check renderMarkdown("hello world") == "<p>hello world</p>"
    check renderMarkdown("```\ncode\n```").contains("<pre><code>code</code></pre>")
    check renderMarkdown("see `foo` here").contains("<code>foo</code>")
    check renderMarkdown("[a](http://x)").contains(
      "<a href=\"http://x\">a</a>")
    check renderMarkdown("<script>alert(1)</script>").contains("&lt;script&gt;")
