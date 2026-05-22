## TBAR-M6 — headless ViewModel test for the spec-comment popover VM
## and the surrounding selection-capture state machine on
## ``SpecPaneVM``.
##
## Pure VM coverage — no DOM, no TipTap, no HTTP transport. The
## :type:`CommentSubmitProc` indirection lets us substitute a
## deterministic stub so the test asserts the popover's reaction to
## both success and failure callbacks without booting a chat client.
##
## Coverage:
##
##   * ``createCommentPopoverVM`` defaults: no draft, not submitting,
##     no error.
##   * ``beginComment`` populates ``draft`` with the supplied text
##     and rect.
##   * ``updateUserComment`` writes the user's comment into the
##     active draft.
##   * ``cancel`` discards the draft + resets submitting / error.
##   * ``submit`` with a stub that reports success clears the draft
##     and ``isSubmitting``.
##   * ``submit`` with a stub that reports failure leaves the draft,
##     populates ``error``, and clears ``isSubmitting``.
##   * ``captureCommentSelection`` on ``SpecPaneVM`` only opens the
##     popover when the pane is in :enum:`spmComment` mode.
##   * Leaving Comment mode dismisses any active draft.

import std/[options, strutils, unittest]

import isonim/core/[signals, owner]
import isonim/editor/vendor/tiptap as tiptap_lib
import isonim/editor/views/spec_pane
import isonim/editor/views/spec_comment_popover
import isonim/editor/views/spec_comment_chat

proc sampleRect(left = 12.0; top = 34.0;
                right = 200.0; bottom = 58.0): TipTapSelectionRect =
  TipTapSelectionRect(left: left, top: top, right: right, bottom: bottom)

proc sampleSelection(text: string; isEmpty = false): TipTapSelection =
  TipTapSelection(text: text, isEmpty: isEmpty)

suite "TBAR-M6 spec comment popover VM":

  test "create_comment_popover_vm_defaults_are_empty":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      check vm.draft != nil
      check vm.isSubmitting != nil
      check vm.error != nil
      check vm.draft.val.isNone
      check vm.isSubmitting.val == false
      check vm.error.val == ""
      dispose()

  test "begin_comment_populates_draft_with_text_and_rect":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      let rect = sampleRect()
      vm.beginComment("hello world", rect)
      check vm.draft.val.isSome
      let d = vm.draft.val.get
      check d.selectedText == "hello world"
      check d.userComment == ""
      check d.anchorRect.left == rect.left
      check d.anchorRect.top == rect.top
      check d.anchorRect.right == rect.right
      check d.anchorRect.bottom == rect.bottom
      dispose()

  test "update_user_comment_writes_into_active_draft":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.beginComment("selected passage", sampleRect())
      vm.updateUserComment("Why is this duplicated?")
      check vm.draft.val.isSome
      check vm.draft.val.get.userComment == "Why is this duplicated?"
      # Subsequent writes replace the prior value.
      vm.updateUserComment("Different question")
      check vm.draft.val.get.userComment == "Different question"
      dispose()

  test "update_user_comment_is_noop_when_no_draft_active":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.updateUserComment("nothing to write to")
      check vm.draft.val.isNone
      dispose()

  test "cancel_discards_draft_and_clears_state":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.beginComment("selected", sampleRect())
      vm.updateUserComment("partial comment")
      vm.error.val = "stale failure message"
      vm.cancel()
      check vm.draft.val.isNone
      check vm.isSubmitting.val == false
      check vm.error.val == ""
      dispose()

  test "submit_success_clears_draft_and_resets_submitting":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.beginComment("selected passage", sampleRect())
      vm.updateUserComment("Why is this duplicated?")

      var observedDrafts: seq[CommentDraft] = @[]
      var resolveCb: proc(success: bool; reason: string)
      let stub: CommentSubmitProc = proc(draft: CommentDraft;
                                         cb: proc(success: bool;
                                                  reason: string)) =
        observedDrafts.add draft
        resolveCb = cb
      submit(vm, stub)
      check observedDrafts.len == 1
      check observedDrafts[0].selectedText == "selected passage"
      check observedDrafts[0].userComment == "Why is this duplicated?"
      check vm.isSubmitting.val == true
      check vm.error.val == ""
      # Drive the callback to "success" — the popover clears.
      resolveCb(true, "")
      check vm.isSubmitting.val == false
      check vm.draft.val.isNone
      check vm.error.val == ""
      dispose()

  test "submit_failure_keeps_draft_and_populates_error":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.beginComment("selected passage", sampleRect())
      vm.updateUserComment("Why is this duplicated?")

      var resolveCb: proc(success: bool; reason: string)
      let stub: CommentSubmitProc = proc(draft: CommentDraft;
                                         cb: proc(success: bool;
                                                  reason: string)) =
        resolveCb = cb
      submit(vm, stub)
      check vm.isSubmitting.val == true
      resolveCb(false, "daemon unreachable")
      check vm.isSubmitting.val == false
      check vm.draft.val.isSome
      check vm.draft.val.get.userComment == "Why is this duplicated?"
      check vm.error.val == "daemon unreachable"
      dispose()

  test "submit_without_active_draft_is_noop":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      var observed = 0
      let stub: CommentSubmitProc = proc(draft: CommentDraft;
                                         cb: proc(success: bool;
                                                  reason: string)) =
        inc observed
        cb(true, "")
      submit(vm, stub)
      check observed == 0
      check vm.isSubmitting.val == false
      dispose()

  test "submit_with_nil_handler_writes_error":
    createRoot do (dispose: proc()):
      let vm = createCommentPopoverVM()
      vm.beginComment("selected", sampleRect())
      submit(vm, nil)
      check vm.isSubmitting.val == false
      check vm.error.val.len > 0
      check vm.draft.val.isSome
      dispose()

suite "TBAR-M6 spec pane comment-mode selection capture":

  test "spec_pane_vm_constructs_comment_popover_eagerly":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      check vm.commentPopover != nil
      check vm.commentPopover.draft.val.isNone
      dispose()

  test "capture_selection_in_comment_mode_opens_popover":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      vm.setMode(spmComment)
      vm.captureCommentSelection(
        sampleSelection("a passage"), sampleRect(10, 20, 100, 40))
      check vm.commentPopover.draft.val.isSome
      check vm.commentPopover.draft.val.get.selectedText == "a passage"
      check vm.commentPopover.draft.val.get.anchorRect.left == 10.0
      check vm.commentPopover.draft.val.get.anchorRect.bottom == 40.0
      dispose()

  test "capture_selection_outside_comment_mode_is_ignored":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      check vm.mode.val == spmView
      vm.captureCommentSelection(
        sampleSelection("text outside comment mode"), sampleRect())
      check vm.commentPopover.draft.val.isNone
      vm.setMode(spmEdit)
      vm.captureCommentSelection(
        sampleSelection("text in edit mode"), sampleRect())
      check vm.commentPopover.draft.val.isNone
      dispose()

  test "capture_empty_selection_dismisses_draft_when_no_pending_comment":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      vm.setMode(spmComment)
      # Open a draft, then collapse the selection -> popover dismisses
      # because the user hasn't typed anything yet.
      vm.captureCommentSelection(
        sampleSelection("passage"), sampleRect())
      check vm.commentPopover.draft.val.isSome
      vm.captureCommentSelection(
        sampleSelection("", isEmpty = true), sampleRect())
      check vm.commentPopover.draft.val.isNone
      dispose()

  test "capture_empty_selection_keeps_draft_when_user_is_composing":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      vm.setMode(spmComment)
      vm.captureCommentSelection(
        sampleSelection("passage"), sampleRect())
      vm.commentPopover.updateUserComment("draft text user typed")
      # Selection collapses (e.g. user clicks into the popover
      # textarea) — the draft must NOT vanish because the user has
      # in-flight content.
      vm.captureCommentSelection(
        sampleSelection("", isEmpty = true), sampleRect())
      check vm.commentPopover.draft.val.isSome
      check vm.commentPopover.draft.val.get.userComment ==
        "draft text user typed"
      dispose()

  test "leaving_comment_mode_dismisses_active_draft":
    createRoot do (dispose: proc()):
      let vm = createSpecPaneVM("# Hello\n")
      vm.setMode(spmComment)
      vm.captureCommentSelection(
        sampleSelection("passage"), sampleRect())
      check vm.commentPopover.draft.val.isSome
      vm.setMode(spmView)
      check vm.commentPopover.draft.val.isNone
      # Same on a Comment→Edit flip.
      vm.setMode(spmComment)
      vm.captureCommentSelection(
        sampleSelection("again"), sampleRect())
      check vm.commentPopover.draft.val.isSome
      vm.setMode(spmEdit)
      check vm.commentPopover.draft.val.isNone
      dispose()

suite "TBAR-M6 spec comment prompt-body builder":

  test "build_spec_comment_prompt_has_all_required_fields":
    let draft = CommentDraft(
      selectedText: "the rendered tile grid is missing",
      userComment: "Why are some tiles missing for the inbox?",
      anchorRect: sampleRect(),
    )
    let body = buildSpecCommentPrompt("render.task-app", draft)
    check body.contains "SPEC COMMENT"
    check body.contains "briefId: render.task-app"
    check body.contains "selectedText: |"
    check body.contains "userComment: |"
    check body.contains "the rendered tile grid is missing"
    check body.contains "Why are some tiles missing for the inbox?"

  test "build_spec_comment_prompt_indents_multi_line_blocks":
    let draft = CommentDraft(
      selectedText: "line one\nline two\nline three",
      userComment: "first\nsecond",
      anchorRect: sampleRect(),
    )
    let body = buildSpecCommentPrompt("render.task-app", draft)
    check body.contains "  line one"
    check body.contains "  line two"
    check body.contains "  line three"
    check body.contains "  first"
    check body.contains "  second"

  test "build_spec_comment_prompt_handles_missing_brief_id":
    let draft = CommentDraft(
      selectedText: "x",
      userComment: "y",
      anchorRect: sampleRect(),
    )
    let body = buildSpecCommentPrompt("", draft)
    check body.contains "briefId: <unknown>"
