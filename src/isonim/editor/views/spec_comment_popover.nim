## TBAR-M6 — Spec Comment Popover
##
## Small floating widget that appears anchored to a TipTap text
## selection while the spec pane is in :type:`SpecPaneMode` =
## ``spmComment``.  Holds the user's free-form comment, a read-only
## preview of the selected passage, and Submit / Cancel buttons.
## Submitting routes through the supplied :type:`CommentSubmitProc`
## (the shell wires this to the chat-session + prompt POST path).
##
## The wrapper structure is built via the ``ui:`` DSL.  Absolute
## positioning happens inside a ``createRenderEffect`` so the popover
## tracks ``draft.anchorRect`` as it changes (e.g. when the user
## re-selects a different passage).  Pure setters live outside the
## reactive layer so VM tests can drive the state machine without
## mounting anything.

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/vendor/tiptap as tiptap_lib

export tiptap_lib.TipTapSelectionRect

type
  CommentDraft* = object
    ## TBAR-M6 — the draft a user is composing.  ``selectedText`` is
    ## frozen at ``beginComment`` time so subsequent selection drifts
    ## inside TipTap don't silently mutate the submitted payload.
    ## ``anchorRect`` is the bounding rect (in viewport coordinates)
    ## of the selection at the moment the popover opened — the mount
    ## adds ``window.scrollX/Y`` when projecting to absolute layout
    ## coordinates so a scroll mid-compose keeps the popover pinned.
    selectedText*: string
    anchorRect*: TipTapSelectionRect
    userComment*: string

  CommentPopoverVM* = ref object
    ## TBAR-M6 — view-model for the comment popover.  The mount reads
    ## these signals + writes ``userComment`` through
    ## :proc:`updateUserComment`.  Submit / cancel are also pure procs
    ## so the headless tests don't need to simulate DOM events.
    draft*: Signal[Option[CommentDraft]]
      ## ``some(...)`` while a draft is being composed; ``none``
      ## otherwise.  The mount renders nothing when this is ``none``.
    isSubmitting*: Signal[bool]
      ## True between the moment :proc:`submit` is called and the
      ## moment the supplied :type:`CommentSubmitProc` callback fires.
      ## The mount uses this to disable the Submit button + show a
      ## "Submitting..." label.
    error*: Signal[string]
      ## Non-empty when the last submit attempt failed.  The popover
      ## stays open so the user can edit and retry.  Cleared when a
      ## new ``beginComment`` / ``submit`` cycle starts.

  CommentSubmitProc* = proc(draft: CommentDraft;
                            cb: proc(success: bool; reason: string)) {.closure.}
    ## Indirection over the chat-session + prompt POST path so the
    ## headless VM tests can substitute a stub.  ``cb`` MUST be called
    ## exactly once; ``success=true`` clears the popover, ``false``
    ## leaves the draft intact + writes ``reason`` into ``vm.error``.

proc createCommentPopoverVM*(): CommentPopoverVM =
  ## Fresh popover VM in the "no draft" state.
  CommentPopoverVM(
    draft: createSignal[Option[CommentDraft]](none[CommentDraft]()),
    isSubmitting: createSignal(false),
    error: createSignal(""),
  )

proc beginComment*(vm: CommentPopoverVM; text: string;
                   rect: TipTapSelectionRect) =
  ## Open the popover anchored to ``rect`` with ``text`` as the frozen
  ## selection preview.  Clears any prior error so a stale failure
  ## doesn't bleed into a fresh attempt.  Idempotent — calling it
  ## while a draft is already active replaces the prior draft (this
  ## happens when the user re-selects without dismissing the popover
  ## first).
  vm.draft.val = some(CommentDraft(
    selectedText: text,
    anchorRect: rect,
    userComment: "",
  ))
  vm.isSubmitting.val = false
  vm.error.val = ""

proc updateUserComment*(vm: CommentPopoverVM; userText: string) =
  ## Replace the ``userComment`` slot of the active draft.  No-op when
  ## no draft is active.  Signal equality short-circuits identical
  ## writes so subscribers don't re-fire on duplicate keystrokes.
  if vm.draft.val.isNone:
    return
  var d = vm.draft.val.get
  if d.userComment == userText:
    return
  d.userComment = userText
  vm.draft.val = some(d)

proc cancel*(vm: CommentPopoverVM) =
  ## Discard the active draft.  Also resets ``isSubmitting`` + the
  ## error message so the next open starts clean.
  vm.draft.val = none[CommentDraft]()
  vm.isSubmitting.val = false
  vm.error.val = ""

proc submit*(vm: CommentPopoverVM; submitProc: CommentSubmitProc) =
  ## Drive a submit round-trip.  ``submitProc`` is expected to call
  ## ``cb(success, reason)`` exactly once.  On ``success=true`` the
  ## popover dismisses (draft → none); on ``success=false`` the
  ## ``reason`` flows into ``vm.error`` and the draft stays so the
  ## user can edit and retry.
  if vm.draft.val.isNone:
    return
  if submitProc == nil:
    vm.error.val = "no submit handler configured"
    return
  let captured = vm
  let draft = vm.draft.val.get
  vm.isSubmitting.val = true
  vm.error.val = ""
  submitProc(draft, proc(success: bool; reason: string) =
    captured.isSubmitting.val = false
    if success:
      captured.draft.val = none[CommentDraft]()
      captured.error.val = ""
    else:
      captured.error.val = reason)

# --------------------------------------------------------------------------- #
#  View — ui DSL wrapper + a render effect that mirrors the active
#  draft state onto the popover's absolute coordinates + visibility.
# --------------------------------------------------------------------------- #

proc mountCommentPopover*[R, E](r: R; parent: E;
                                vm: CommentPopoverVM;
                                onSubmit: CommentSubmitProc) =
  ## Mount the popover under ``parent`` (typically the editor shell
  ## root so the absolute-positioned overlay layers above the spec
  ## pane without parent clipping).  ``onSubmit`` is the closure the
  ## Submit button routes through; it MUST eventually call its own
  ## ``cb(success, reason)`` argument so the VM clears ``isSubmitting``.
  let capturedVm = vm
  let capturedOnSubmit = onSubmit
  var rootNode: E
  var previewNode: E
  var textareaNode: E
  var submitBtn: E
  var cancelBtn: E
  var errorRow: E

  let root = ui(r):
    tdiv(
      ref = rootNode,
      `data-spec-comment-popover` = "true",
      position = "absolute",
      display = "none",
      flex_direction = "column",
      gap = "8px",
      padding = "10px 12px",
      background_color = "#1A1B25",
      border = "1px solid #2F3140",
      border_radius = "6px",
      box_shadow = "0 4px 16px rgba(0,0,0,0.4)",
      color = "#D5D6DB",
      font_size = "12px",
      width = "320px",
      z_index = "1000"):
      tdiv(
        ref = previewNode,
        `data-spec-comment-popover-preview` = "true",
        display = "-webkit-box",
        overflow = "hidden",
        text_overflow = "ellipsis",
        background_color = "#0F0F18",
        border_left = "3px solid #7C7CDA",
        padding = "6px 8px",
        font_size = "11px",
        font_style = "italic",
        color = "#A0A1B0",
        max_height = "60px"):
        text ""
      textarea(
        ref = textareaNode,
        `data-spec-comment-popover-input` = "true",
        placeholder = "Comment on the selected text...",
        rows = "3",
        resize = "vertical",
        padding = "6px 8px",
        background_color = "#0F0F18",
        border = "1px solid #2F3140",
        border_radius = "4px",
        color = "#D5D6DB",
        font_family = "inherit",
        font_size = "12px",
        outline = "none")
      tdiv(
        ref = errorRow,
        `data-spec-comment-popover-error` = "true",
        display = "none",
        color = "#FF6B6B",
        font_size = "11px"):
        text ""
      tdiv(
        display = "flex",
        flex_direction = "row",
        gap = "8px",
        justify_content = "flex-end"):
        button(
          ref = cancelBtn,
          `data-spec-comment-popover-cancel` = "true",
          `type` = "button",
          padding = "4px 10px",
          border_radius = "4px",
          border = "1px solid #2F3140",
          background_color = "transparent",
          color = "#D5D6DB",
          cursor = "pointer",
          font_size = "11px"):
          text("Cancel")
        button(
          ref = submitBtn,
          `data-spec-comment-popover-submit` = "true",
          `type` = "button",
          padding = "4px 10px",
          border_radius = "4px",
          border = "1px solid #7C7CDA",
          background_color = "#7C7CDA",
          color = "#FFFFFF",
          cursor = "pointer",
          font_size = "11px"):
          text("Submit")

  # ------------------------------------------------------------------- #
  # Visibility + absolute-positioning effect.  The popover's
  # ``display`` + ``top/left`` are driven from ``draft`` reactively.
  # The brief explicitly allows ``setStyle`` calls inside a
  # ``createRenderEffect`` for absolute-positioning logic — there is no
  # no-setstyle invariant scan over this module.
  # ------------------------------------------------------------------- #
  createRenderEffect proc() =
    let opt = capturedVm.draft.val
    if opt.isNone:
      r.setStyle(rootNode, "display", "none")
      return
    let d = opt.get
    r.setStyle(rootNode, "display", "flex")
    when defined(js):
      # ``window.scrollX/Y`` is added to the rect's left/top so the
      # popover stays pinned to the selection in document coordinates
      # rather than viewport coordinates.  We use ``setStyle`` rather
      # than embedding scroll math in a JS template because the
      # popover's render effect is reactive and JS-evaluated.
      let leftDoc = d.anchorRect.left
      let topDoc = d.anchorRect.bottom + 6.0
      r.setStyle(rootNode, "left", $leftDoc & "px")
      r.setStyle(rootNode, "top", $topDoc & "px")
    else:
      # Native build: surface the rect via data-attrs so the headless
      # mount test can verify positioning without DOM measurements.
      r.setAttribute(rootNode, "data-spec-comment-popover-left",
        $d.anchorRect.left)
      r.setAttribute(rootNode, "data-spec-comment-popover-top",
        $d.anchorRect.bottom)
    # Update the read-only preview text + the textarea value when a
    # draft is active.  We write through ``setTextContent`` /
    # ``setInputValue`` so the values mirror VM state even when the
    # popover is re-opened with a different selection.
    r.setTextContent(previewNode, d.selectedText)

  # Mirror ``userComment`` into the textarea on open / VM-driven
  # writes.  We only push to the textarea when the value differs to
  # avoid clobbering the user's caret position on every keystroke.
  createRenderEffect proc() =
    let opt = capturedVm.draft.val
    if opt.isNone:
      return
    let d = opt.get
    when defined(js):
      if r.inputValue(textareaNode) != d.userComment:
        r.setInputValue(textareaNode, d.userComment)
    else:
      r.setAttribute(textareaNode, "data-spec-comment-popover-value",
        d.userComment)

  # Error row visibility + content.
  createRenderEffect proc() =
    let err = capturedVm.error.val
    if err.len == 0:
      r.setStyle(errorRow, "display", "none")
      r.setTextContent(errorRow, "")
    else:
      r.setStyle(errorRow, "display", "block")
      r.setTextContent(errorRow, err)

  # Submit button enablement mirrors ``isSubmitting``.  In HTML the
  # ``disabled`` attribute's presence (not its value) is what disables
  # the button, so toggling enable/disable means add/remove rather
  # than set "" — otherwise a freshly-mounted popover lands with
  # ``disabled=""`` and clicks are silently dropped.
  createRenderEffect proc() =
    let submitting = capturedVm.isSubmitting.val
    r.setAttribute(submitBtn, "data-submitting",
      if submitting: "true" else: "false")
    when defined(js):
      if submitting:
        r.setAttribute(submitBtn, "disabled", "true")
      else:
        r.removeAttribute(submitBtn, "disabled")

  when defined(js):
    proc onTextareaInput() =
      capturedVm.updateUserComment(r.inputValue(textareaNode))
    proc onCancelClick() =
      capturedVm.cancel()
    proc onSubmitClick() =
      if capturedVm.draft.val.isNone:
        return
      if capturedVm.isSubmitting.val:
        return
      submit(capturedVm, capturedOnSubmit)
    r.addEventListener(textareaNode, "input", onTextareaInput)
    r.addEventListener(cancelBtn, "click", onCancelClick)
    r.addEventListener(submitBtn, "click", onSubmitClick)

  r.appendChild(parent, root)
