## Phase K — headless tests for the Notion-style inline comment
## overlay widget (``src/isonim/editor/views/widgets/comment_overlay.nim``).
##
## Pure VM + MockRenderer coverage — no Playwright, no real DOM.  The
## live-browser flow is exercised separately by
## ``tests/browser/e2e_editor_comment_overlay_live.mjs``.
##
## Coverage:
##
##   1. Mounting the overlay with no annotations renders no anchor
##      markers.
##   2. Adding an annotation through ``addReviewAnnotationAtAnchor``
##      surfaces a numbered anchor at the right coordinates +
##      ``data-comment-anchor`` carries the annotation id.
##   3. Resolving an annotation flips ``data-comment-resolved`` from
##      ``"false"`` to ``"true"`` and the anchor's visual collapses
##      (background switches from accent to muted, size shrinks).
##   4. Toggling away from ``emComment`` hides the overlay root
##      (``display: none``); toggling back re-shows it.
##   5. Annotation data round-trips a mode toggle — anchors persist
##      across emComment → emView → emComment.
##   6. The thread popover surfaces the annotation's text + replies.
##   7. Sending a reply through ``addCommentToAnnotation`` appends to
##      the annotation's ``comments`` slot.
##   8. ``placeAnchorAt`` (the headless mirror of the underlay click)
##      creates a new annotation + leaves the overlay's open-popover
##      contract in the same shape the real-browser path produces.

import std/[tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/views/widgets/comment_overlay
import isonim/testing/mock_dom

# --------------------------------------------------------------------------- #
#  Helpers
# --------------------------------------------------------------------------- #

proc mkRoot(): tuple[r: MockRenderer; root: MockNode] =
  let r = MockRenderer()
  let root = r.createElement("div")
  (r, root)

proc findByAttr(node: MockNode; attr, value: string): MockNode =
  if node == nil:
    return nil
  if node.kind == mnkElement and node.attributes.getOrDefault(attr) == value:
    return node
  for c in node.children:
    let hit = findByAttr(c, attr, value)
    if hit != nil:
      return hit
  return nil

proc findByAttrPresent(node: MockNode; attr: string): MockNode =
  if node == nil:
    return nil
  if node.kind == mnkElement and attr in node.attributes:
    return node
  for c in node.children:
    let hit = findByAttrPresent(c, attr)
    if hit != nil:
      return hit
  return nil

proc collectAttrPresent(node: MockNode; attr: string;
    acc: var seq[MockNode]) =
  if node == nil:
    return
  if node.kind == mnkElement and attr in node.attributes:
    acc.add node
  for c in node.children:
    collectAttrPresent(c, attr, acc)

proc allAnchorNodes(root: MockNode): seq[MockNode] =
  var acc: seq[MockNode] = @[]
  collectAttrPresent(root, "data-comment-anchor", acc)
  result = acc

# --------------------------------------------------------------------------- #
#  Tests
# --------------------------------------------------------------------------- #

suite "Phase K comment overlay — mount + anchor rendering":

  test "overlay_with_no_annotations_renders_no_anchors":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let overlay = findByAttr(root, "data-comment-overlay", "true")
      check overlay != nil
      let anchors = allAnchorNodes(root)
      check anchors.len == 0
      dispose()

  test "adding_annotation_renders_anchor_with_id_and_position":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let newId = vm.addReviewAnnotationAtAnchor(120.0, 80.0,
        selector = "#hero")
      check newId.len > 0

      let anchors = allAnchorNodes(root)
      check anchors.len == 1
      let anchor = anchors[0]
      check anchor.attributes.getOrDefault("data-comment-anchor") == newId
      check anchor.attributes.getOrDefault("data-comment-anchor-number") == "1"
      check anchor.attributes.getOrDefault("data-comment-resolved") == "false"
      # The marker's centre lands ON the click point — the render
      # effect subtracts half the marker width so the visual hot
      # spot sits at (anchorX, anchorY).  For the unresolved 24x24
      # marker that means left = 120 - 12 = 108 px, top = 80 - 12 =
      # 68 px.
      check anchor.styles.getOrDefault("left") == "108.0px"
      check anchor.styles.getOrDefault("top") == "68.0px"
      check anchor.styles.getOrDefault("width") == "24px"
      check anchor.styles.getOrDefault("height") == "24px"
      dispose()

  test "anchors_render_in_insertion_order_with_sequential_numbers":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let a = vm.addReviewAnnotationAtAnchor(10.0, 10.0)
      let b = vm.addReviewAnnotationAtAnchor(40.0, 40.0)
      let c = vm.addReviewAnnotationAtAnchor(80.0, 80.0)
      check a.len > 0 and b.len > 0 and c.len > 0

      let anchors = allAnchorNodes(root)
      check anchors.len == 3
      check anchors[0].attributes.getOrDefault("data-comment-anchor-number") == "1"
      check anchors[1].attributes.getOrDefault("data-comment-anchor-number") == "2"
      check anchors[2].attributes.getOrDefault("data-comment-anchor-number") == "3"
      dispose()

suite "Phase K comment overlay — resolve flips visual":

  test "resolving_annotation_flips_data_comment_resolved_and_shrinks_anchor":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let id = vm.addReviewAnnotationAtAnchor(100.0, 100.0)
      check id.len > 0

      var anchors = allAnchorNodes(root)
      check anchors.len == 1
      check anchors[0].attributes.getOrDefault("data-comment-resolved") == "false"
      # Unresolved marker is 24x24.
      check anchors[0].styles.getOrDefault("width") == "24px"

      check vm.review.resolveReviewAnnotation(id)

      anchors = allAnchorNodes(root)
      check anchors.len == 1
      check anchors[0].attributes.getOrDefault("data-comment-resolved") == "true"
      # Resolved marker shrinks to 14x14 (the "muted dot" the spec
      # asks for).
      check anchors[0].styles.getOrDefault("width") == "14px"
      check anchors[0].styles.getOrDefault("height") == "14px"
      # Opacity drops so the dot reads as quiet.
      check anchors[0].styles.getOrDefault("opacity") == "0.55"
      dispose()

suite "Phase K comment overlay — mode reactivity":

  test "toggling_away_from_comment_mode_hides_overlay_display":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let overlay = findByAttr(root, "data-comment-overlay", "true")
      check overlay != nil
      check overlay.styles.getOrDefault("display") == "block"

      vm.setEditMode(emView)
      check overlay.styles.getOrDefault("display") == "none"

      vm.setEditMode(emComment)
      check overlay.styles.getOrDefault("display") == "block"

      vm.setEditMode(emEdit)
      check overlay.styles.getOrDefault("display") == "none"
      dispose()

  test "underlay_pointer_events_track_comment_mode":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let underlay = findByAttr(root, "data-comment-overlay-underlay", "true")
      check underlay != nil
      check underlay.styles.getOrDefault("pointer-events") == "auto"

      vm.setEditMode(emView)
      check underlay.styles.getOrDefault("pointer-events") == "none"
      dispose()

  test "annotation_data_persists_across_mode_toggle":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let id = vm.addReviewAnnotationAtAnchor(50.0, 50.0)
      check id.len > 0
      check vm.review.annotations.val.len == 1

      vm.setEditMode(emView)
      # The annotations are not destroyed — the underlying signal is
      # untouched.  Anchor markers are simply hidden because the
      # overlay itself is ``display: none``.
      check vm.review.annotations.val.len == 1

      vm.setEditMode(emComment)
      let anchors = allAnchorNodes(root)
      check anchors.len == 1
      check anchors[0].attributes.getOrDefault("data-comment-anchor") == id
      dispose()

suite "Phase K comment overlay — thread popover":

  test "popover_starts_hidden_with_no_open_anchor":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let popover = findByAttr(root, "data-comment-thread-popover", "true")
      check popover != nil
      check popover.styles.getOrDefault("display") == "none"
      dispose()

  test "clicking_anchor_opens_popover_showing_annotation_text":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let id = vm.addReviewAnnotationAtAnchor(100.0, 100.0)
      check vm.review.addCommentToAnnotation(id, "Why is the hero so tall?")

      let anchors = allAnchorNodes(root)
      check anchors.len == 1
      fireEvent(anchors[0], "click")

      let popover = findByAttr(root, "data-comment-thread-popover", "true")
      check popover != nil
      check popover.styles.getOrDefault("display") == "flex"
      let title = findByAttr(root, "data-comment-thread-popover-title", "true")
      check title != nil
      check textContent(title) == "Comment 1"

      let firstComment = findByAttr(root,
        "data-comment-thread-popover-comment", "first")
      check firstComment != nil
      check textContent(firstComment) == "Why is the hero so tall?"
      dispose()

  test "sending_reply_appends_to_annotation_comments":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let id = vm.addReviewAnnotationAtAnchor(60.0, 60.0)
      check vm.review.addCommentToAnnotation(id, "First comment")
      # An empty first slot makes the second call the canonical
      # first comment.  Confirm the contract with a follow-up that
      # actually appends to ``comments``.
      check vm.review.addCommentToAnnotation(id, "Second reply")

      let after = vm.review.annotations.val
      check after.len == 1
      check after[0].text == "First comment"
      check after[0].comments.len == 1
      check after[0].comments[0].text == "Second reply"
      dispose()

  test "resolve_button_closes_popover_and_marks_state":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let id = vm.addReviewAnnotationAtAnchor(70.0, 70.0)
      check vm.review.addCommentToAnnotation(id, "Looks off.")

      let anchors = allAnchorNodes(root)
      check anchors.len == 1
      fireEvent(anchors[0], "click")
      let popover = findByAttr(root, "data-comment-thread-popover", "true")
      check popover.styles.getOrDefault("display") == "flex"

      let resolveBtn = findByAttr(root,
        "data-comment-thread-popover-resolve", "true")
      check resolveBtn != nil
      fireEvent(resolveBtn, "click")
      check popover.styles.getOrDefault("display") == "none"
      check vm.review.annotations.val[0].state == ransResolved

      # The anchor's resolved-attr / shrunken visual reflects the
      # state change too.
      let anchorsAfter = allAnchorNodes(root)
      check anchorsAfter.len == 1
      check anchorsAfter[0].attributes.getOrDefault("data-comment-resolved") == "true"
      dispose()

suite "Phase K comment overlay — click-to-place":

  test "underlay_click_drops_anchor_through_addReviewAnnotationAtAnchor":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      check vm.review.annotations.val.len == 0
      let underlay = findByAttr(root, "data-comment-overlay-underlay", "true")
      check underlay != nil
      fireEvent(underlay, "click")
      # Mock-renderer path lands the anchor at the origin so the
      # exact coordinates don't matter; what matters is that the
      # click intercept routes through the VM helper and persists
      # a new annotation that re-renders into a marker.
      check vm.review.annotations.val.len == 1
      let anchors = allAnchorNodes(root)
      check anchors.len == 1

      # The new anchor's popover opens automatically (sticky) so the
      # user can start typing.
      let popover = findByAttr(root, "data-comment-thread-popover", "true")
      check popover != nil
      check popover.styles.getOrDefault("display") == "flex"
      dispose()

  test "underlay_click_is_ignored_outside_comment_mode":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emView)
      let (r, root) = mkRoot()
      discard mountCommentOverlay[MockRenderer, MockNode](r, root, vm)

      let underlay = findByAttr(root, "data-comment-overlay-underlay", "true")
      check underlay != nil
      fireEvent(underlay, "click")
      check vm.review.annotations.val.len == 0
      dispose()

  test "placeAnchorAt_mirror_drops_annotation_at_supplied_coords":
    createRoot proc(dispose: proc()) =
      let vm = createEditorVM()
      vm.setEditMode(emComment)
      let id = vm.placeAnchorAt(220.0, 140.0, selector = "#cta")
      check id.len > 0
      check vm.review.annotations.val.len == 1
      check vm.review.annotations.val[0].anchorX == 220.0
      check vm.review.annotations.val[0].anchorY == 140.0
      check vm.review.annotations.val[0].selector == "#cta"
      check vm.review.annotations.val[0].state == ransOpen
      dispose()
