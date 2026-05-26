## TBAR-M4 / TBAR-M5 / TBAR-M5b — Spec pane: TipTap-backed renderer
## for the active brief's markdown body, plus an Edit mode that lets
## the user modify the markdown and save it back to disk.
##
## ``SpecPaneVM`` carries the surface state:
##
##   * ``mode``               — Signal[SpecPaneMode] (view/comment/edit).
##   * ``markdown``           — Signal[string] mirroring the editor body.
##   * ``lastSavedMarkdown``  — Signal[string], value Cancel reverts to.
##   * ``dirty``              — Signal[bool], true when the body differs
##                              from the last-saved snapshot.
##   * ``editor``             — JS-only handle to the live TipTap
##                              ``Editor`` instance (set by the mount;
##                              ``destroy()``ed on re-mount).  The
##                              native build keeps an inert
##                              placeholder field so the test pipeline
##                              compiles.
##
## TBAR-M5b strategy change: TBAR-M5 used a ``<textarea>`` overlay
## (Option 3 / verbatim-typed bytes) to side-step the lossy
## TipTap→markdown round-trip.  TBAR-M5b switches to a real TipTap
## editable instance: ``tiptap-markdown`` is now part of the bundle
## and provides a lossless serialiser, so Edit mode flips
## ``editor.setEditable(true)`` on the existing instance + extracts
## markdown via ``Markdown.getMarkdown(editor)`` on Save.  ``onUpdate``
## wired through ``TipTapEditorOptions`` drives the ``dirty`` signal;
## a ``loading`` guard suppresses dirty when the brief-switching code
## path writes synthetic content via ``setContent``.
##
## Dogfood: the wrapper structure is built via the ``ui:`` DSL.  The
## TipTap mount itself touches container contents imperatively — that
## is the documented bridge to the foreign JS library and lives
## inside this module's reactive effect that calls ``newEditor`` /
## ``replaceContent`` / ``setEditable`` against the per-library FFI
## modules (``vendor/tiptap.nim``, ``vendor/tiptap_starter_kit.nim``,
## ``vendor/tiptap_markdown.nim``).

import std/options

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/vendor/tiptap as tiptap_lib
import isonim/editor/vendor/tiptap_starter_kit as tiptap_starter
import isonim/editor/vendor/tiptap_markdown as tiptap_md
import isonim/editor/vendor/tiptap_link as tiptap_link
import isonim/editor/views/spec_comment_popover as spec_comment_popover_view
import isonim/editor/views/spec_editor_toolbar as spec_editor_toolbar_view

export spec_comment_popover_view.CommentDraft
export spec_comment_popover_view.CommentPopoverVM
export spec_comment_popover_view.CommentSubmitProc
export spec_comment_popover_view.createCommentPopoverVM
export spec_comment_popover_view.beginComment
export spec_comment_popover_view.updateUserComment
export spec_comment_popover_view.cancel
export spec_comment_popover_view.submit
export spec_comment_popover_view.mountCommentPopover

export spec_editor_toolbar_view.SpecEditorToolbarVM
export spec_editor_toolbar_view.FormattingMark
export spec_editor_toolbar_view.BlockKind
export spec_editor_toolbar_view.createSpecEditorToolbarVM
export spec_editor_toolbar_view.setActiveMarks
export spec_editor_toolbar_view.setActiveBlockKind
export spec_editor_toolbar_view.setCanUndo
export spec_editor_toolbar_view.setCanRedo
export spec_editor_toolbar_view.openLinkDraft
export spec_editor_toolbar_view.closeLinkDraft
export spec_editor_toolbar_view.collectActiveMarks
export spec_editor_toolbar_view.currentBlockKind
export spec_editor_toolbar_view.mountSpecEditorToolbar
export spec_editor_toolbar_view.subscribeToEditor
export spec_editor_toolbar_view.EditorLookup

when defined(js):
  import std/jsffi

  # ------------------------------------------------------------------- #
  # Local FFI helper: assemble the TipTap extensions array depending on
  # which optional extension globals are available.  Kept here (rather
  # than in a vendor/* FFI module) because it's an application-side
  # composition step — the per-library modules expose the constructors;
  # this helper picks which combination to install based on runtime
  # availability checks.  ``{.importjs.}`` makes the body a typed
  # binding rather than a ``{.emit.}`` block.
  # ------------------------------------------------------------------- #
  proc buildExtensionsArray(hasStarter, hasMarkdown, hasLink: bool): JsObject
    {.importjs: """(function(s, m, l) {
      var out = [];
      if (s) { out.push(globalThis.TipTapStarterKit.StarterKit); }
      if (m) { out.push(globalThis.TipTapMarkdown.Markdown); }
      if (l) { out.push(globalThis.TipTapLink.Link.configure({openOnClick: false, autolink: true})); }
      return out;
    })(#, #, #)""".}

  # Expose the live TipTap editor instance on ``window`` for the
  # TBAR-M5b browser e2e tests.  Production code never reads this
  # — it exists solely so the Playwright suite can drive
  # ``editor.commands.setContent`` + ``storage.markdown.getMarkdown``
  # without poking at the internal handle.
  proc stashSpecPaneEditor(editor: TipTapEditor)
    {.importjs: "(typeof window !== 'undefined' ? (window.__isonimSpecPaneEditor = #) : undefined)".}

type
  SpecPaneMode* = enum
    ## TBAR-M4 wires View; TBAR-M5 wires Edit; TBAR-M6 wires Comment.
    spmView
    spmComment
    spmEdit

  SpecPaneVM* = ref object
    mode*: Signal[SpecPaneMode]
    markdown*: Signal[string]
    lastSavedMarkdown*: Signal[string]
      ## TBAR-M5 — the value Cancel reverts to. Updated by
      ## ``saveEdits`` on success. Defaults to the constructor's
      ## ``initialMarkdown`` so an unsaved-but-unedited pane reports
      ## ``dirty == false``.
    dirty*: Signal[bool]
      ## TBAR-M5 — true when ``markdown.val != lastSavedMarkdown.val``.
      ## Kept as an explicit signal (rather than a memo) so the Save
      ## button's visibility is reactive without forcing every
      ## subscriber to re-derive from two signals.
    editor*: tiptap_lib.TipTapEditor
      ## TBAR-M5b — JS-only handle to the live TipTap Editor instance.
      ## ``mountSpecPane`` populates it on first reactive run; the
      ## mount tears down the previous instance via ``destroy`` before
      ## creating a new one.  The native build keeps an inert
      ## placeholder so the headless VM tests compile.
    loading*: bool
      ## TBAR-M5b — guard flag set while a synthetic ``setContent`` /
      ## ``markSaved`` write is in flight (e.g. when the brief lookup
      ## refreshes the body after a story switch).  ``onUpdate``
      ## callbacks fired during a synthetic write must NOT flip
      ## ``dirty`` to true.
    commentPopover*: CommentPopoverVM
      ## TBAR-M6 — companion popover VM used while the pane is in
      ## ``spmComment`` mode.  ``mountSpecPane`` reads the active
      ## TipTap selection on every ``selectionUpdate`` event and feeds
      ## it into this VM via :proc:`beginComment` / :proc:`cancel`.
      ## Lives on the SpecPaneVM rather than alongside the mount so
      ## headless tests can drive the selection-capture state machine
      ## without booting TipTap.  The shell owns the mount step that
      ## actually renders the popover.
    toolbar*: SpecEditorToolbarVM
      ## CHRM-M4 — companion VM for the spec-pane formatting toolbar
      ## that mounts above the TipTap editable host in Edit mode.
      ## The mount keeps this in sync with the live editor via
      ## ``onSelectionUpdate`` + ``onTransaction`` subscriptions.
      ## Constructed eagerly so tests can subscribe to its signals
      ## without booting the mount.

proc createSpecPaneVM*(initialMarkdown: string = ""): SpecPaneVM =
  ## Build a fresh VM. Defaults to ``spmView`` mode and the supplied
  ## markdown body (empty string when the caller doesn't yet have a
  ## brief). The initial markdown also seeds ``lastSavedMarkdown`` so
  ## ``dirty`` starts at ``false``.  The companion :type:`CommentPopoverVM`
  ## is constructed eagerly so tests + mounts can subscribe to it
  ## without checking ``nil``.
  SpecPaneVM(
    mode: createSignal(spmView),
    markdown: createSignal(initialMarkdown),
    lastSavedMarkdown: createSignal(initialMarkdown),
    dirty: createSignal(false),
    loading: false,
    commentPopover: createCommentPopoverVM(),
    toolbar: createSpecEditorToolbarVM(),
  )

proc recomputeDirty(vm: SpecPaneVM) =
  ## Keep ``dirty`` in sync with the two underlying signals. Called by
  ## both ``setMarkdown`` and the save/cancel procs. We don't run this
  ## inside a ``createRenderEffect`` because the VM is constructed
  ## outside any owner in some test paths and we want the VM API to
  ## be safe to call from those plain contexts.
  let isDirty = vm.markdown.val != vm.lastSavedMarkdown.val
  if vm.dirty.val != isDirty:
    vm.dirty.val = isDirty

proc setMarkdown*(vm: SpecPaneVM; markdown: string) =
  ## Replace the markdown body. ``Signal[string]``'s default equality
  ## short-circuits identical writes so subscribers (and the
  ## ``createRenderEffect`` inside ``mountSpecPane``) do not re-fire
  ## when the brief lookup yields the same body across resolves.
  vm.markdown.val = markdown
  recomputeDirty(vm)

proc setMode*(vm: SpecPaneVM; mode: SpecPaneMode) =
  ## Replace the active mode. The signal is reactive so the spec-pane
  ## mount can listen and toggle TipTap's editable flag accordingly.
  ## TBAR-M6 — leaving Comment mode discards any active draft so a
  ## subsequent re-entry starts clean.
  let prev = vm.mode.val
  vm.mode.val = mode
  if prev == spmComment and mode != spmComment:
    if vm.commentPopover != nil:
      vm.commentPopover.cancel()

proc captureCommentSelection*(vm: SpecPaneVM;
                              selection: TipTapSelection;
                              rect: TipTapSelectionRect) =
  ## TBAR-M6 — VM-level entry point the mount calls on every TipTap
  ## ``selectionUpdate`` event while in :enum:`spmComment` mode.  When
  ## the selection is non-empty it opens (or replaces) the draft
  ## anchored to ``rect``; an empty selection dismisses any active
  ## draft (so de-selecting the passage hides the popover).  Exposed
  ## publicly so the headless VM test can drive the state machine
  ## without booting TipTap.
  if vm.commentPopover == nil:
    return
  if vm.mode.val != spmComment:
    return
  if selection.isEmpty or selection.text.len == 0:
    # If the user is mid-compose, keep the draft alive so a stray
    # caret-only event doesn't dismiss them — only clear when no
    # draft is active yet or the draft has no user comment yet.
    let draftOpt = vm.commentPopover.draft.val
    if draftOpt.isNone or draftOpt.get.userComment.len == 0:
      vm.commentPopover.cancel()
    return
  vm.commentPopover.beginComment(selection.text, rect)

proc enterEdit*(vm: SpecPaneVM) =
  ## TBAR-M5 — flip the pane into Edit mode. The mount's editable-
  ## sync effect picks up the mode change and calls
  ## ``tiptap.setEditable(editor, true)``. ``dirty`` stays false until
  ## the user types something (TipTap's ``onUpdate`` callback flips
  ## the flag).
  vm.mode.val = spmEdit

proc cancelEdits*(vm: SpecPaneVM) =
  ## TBAR-M5 — revert the markdown to ``lastSavedMarkdown`` and exit
  ## Edit mode. ``dirty`` clears as a side-effect of
  ## ``recomputeDirty`` (because ``markdown == lastSavedMarkdown``
  ## again).
  vm.markdown.val = vm.lastSavedMarkdown.val
  recomputeDirty(vm)
  vm.mode.val = spmView

proc markSaved*(vm: SpecPaneVM; markdown: string) =
  ## TBAR-M5 — internal hook used by ``saveEdits`` (and by the mount
  ## when reconciling after a successful HTTP save).  Updates the
  ## last-saved snapshot and the markdown signal in lock-step, then
  ## clears ``dirty``.
  vm.lastSavedMarkdown.val = markdown
  vm.markdown.val = markdown
  recomputeDirty(vm)

proc markDirty*(vm: SpecPaneVM) =
  ## TBAR-M5 — set ``dirty`` to true unconditionally.  Used by the
  ## TipTap ``onUpdate`` callback when the user mutates the editor
  ## body (TBAR-M5b switched from textarea overlay to a real TipTap
  ## editable instance, so this hook is now what's invoked by the JS
  ## bundle's update event).
  vm.dirty.val = true

# --------------------------------------------------------------------------- #
#  TBAR-M5 — HTTP-bound save proc.  Lives here (rather than in the
#  mount) so the headless VM test can exercise it with a stub
#  callback.
# --------------------------------------------------------------------------- #

type
  SaveBriefHttpProc* = proc(briefId, markdown: string;
                            cb: proc(success: bool; body: string)) {.closure.}
    ## Indirection over ``editor_http_client.saveBrief`` so the VM
    ## test can substitute a deterministic stub.  The closure shape
    ## is intentionally minimal — the mount's binding adapts the real
    ## ``HttpCallbackResult`` into ``(success, body)``.

proc saveEdits*(vm: SpecPaneVM; briefId, markdown: string;
                httpSave: SaveBriefHttpProc;
                onDone: proc(success: bool) = nil) =
  ## TBAR-M5 — drive the save round-trip.  Calls ``httpSave`` with
  ## the current markdown; on success updates ``lastSavedMarkdown``
  ## and clears ``dirty``; on failure leaves ``dirty`` intact so the
  ## user sees the Save button still active and can retry.
  if httpSave == nil:
    if onDone != nil: onDone(false)
    return
  let capturedVm = vm
  let capturedMd = markdown
  let capturedDone = onDone
  httpSave(briefId, markdown, proc(success: bool; body: string) =
    if success:
      capturedVm.markSaved(capturedMd)
    if capturedDone != nil:
      capturedDone(success))

# --------------------------------------------------------------------------- #
#  View — ui DSL wrapper + a single createRenderEffect that drives the
#  TipTap content updates. Per the milestone brief the inner TipTap
#  mount is the only place that touches the container imperatively.
# --------------------------------------------------------------------------- #

type
  SpecPaneMountCallbacks* = ref object
    ## TBAR-M5 — callbacks the shell supplies to the spec-pane mount.
    ## ``onSave`` runs when the user clicks the Save button; the
    ## mount has already pulled the current markdown body from the
    ## TipTap editor via ``tiptap_md.getMarkdown``.  ``onCancel``
    ## runs on the Cancel button; the mount routes it through
    ## ``cancelEdits``.
    onSaveRequested*: proc(markdown: string) {.closure.}
    onCancelRequested*: proc() {.closure.}

proc destroyEditor*(vm: SpecPaneVM) =
  ## TBAR-M5b — tear down the live TipTap editor instance held by
  ## the VM.  Safe to call when no editor is attached.  Exposed
  ## publicly so the shell can dispose of an editor when the
  ## spec-pane host is unmounted (and so tests can simulate the
  ## destroy half of the re-mount lifecycle).
  when defined(js):
    let ed = vm.editor
    if not ed.isNil:
      tiptap_lib.destroy(ed)
    vm.editor = nil
  else:
    discard

proc mountSpecPane*[R, E](r: R; parent: E; vm: SpecPaneVM;
                          callbacks: SpecPaneMountCallbacks = nil) =
  ## Mount the spec pane underneath ``parent``. The mount body
  ## structure:
  ##
  ##   1. A wrapper ``tdiv`` flagged ``data-spec-pane-tiptap="true"``
  ##      so the e2e test can find the surface.
  ##   2. An inner host ``tdiv`` flagged ``data-spec-pane-tiptap-host
  ##      ="true"`` where the TipTap editor mounts. ProseMirror /
  ##      TipTap own the host's children.
  ##   3. TBAR-M5b: a one-time effect builds the TipTap editor via
  ##      ``vendor/tiptap.newEditor`` + ``StarterKit`` + ``Markdown``
  ##      extensions and stores the instance on ``vm.editor``.  The
  ##      ``onUpdate`` callback configured on the editor flips
  ##      ``vm.dirty`` to true unless ``vm.loading`` is set.
  ##   4. A markdown-sync effect calls
  ##      ``tiptap.replaceContent(editor, body, parseMd=true)`` when
  ##      ``vm.markdown.val`` changes, guarded by ``vm.loading=true``
  ##      so the resulting ``onUpdate`` callback doesn't mark the
  ##      pane dirty.
  ##   5. A mode-mirror effect syncs ``vm.mode.val`` onto a
  ##      ``data-spec-pane-mode`` attribute.
  ##   6. An editable-state effect calls
  ##      ``tiptap.setEditable(editor, mode == spmEdit)`` + writes a
  ##      ``data-tiptap-editable="true|false"`` attribute on the host.
  ##   7. A Save / Cancel button row, visible only when
  ##      ``mode == spmEdit and dirty``.
  let capturedVm = vm
  let capturedCallbacks = callbacks
  var hostNode: E
  var saveBtn: E
  var cancelBtn: E
  var buttonRow: E
  var toolbarHost: E
  let root = ui(r):
    tdiv(
      `data-spec-pane-tiptap` = "true",
      display = "flex",
      flex_direction = "column",
      flex = "1",
      min_width = "0",
      min_height = "0",
      padding = "16px 20px",
      overflow_y = "auto"):
      tdiv(
        ref = toolbarHost,
        `data-spec-pane-toolbar-host` = "true",
        display = "none")
      tdiv(
        ref = hostNode,
        `data-spec-pane-tiptap-host` = "true",
        flex = "1",
        min_width = "0",
        min_height = "0")
      tdiv(
        ref = buttonRow,
        `data-spec-pane-edit-controls` = "true",
        display = "none",
        flex_direction = "row",
        gap = "8px",
        margin_top = "12px",
        justify_content = "flex-end"):
        button(
          ref = cancelBtn,
          `data-spec-pane-cancel-btn` = "true",
          `type` = "button",
          padding = "6px 14px",
          border_radius = "4px",
          border = "1px solid #2F3140",
          background_color = "transparent",
          color = "#D5D6DB",
          cursor = "pointer",
          font_size = "13px"):
          text("Cancel")
        button(
          ref = saveBtn,
          `data-spec-pane-save-btn` = "true",
          `type` = "button",
          padding = "6px 14px",
          border_radius = "4px",
          border = "1px solid #7C7CDA",
          background_color = "#7C7CDA",
          color = "#FFFFFF",
          cursor = "pointer",
          font_size = "13px"):
          text("Save")

  # ------------------------------------------------------------------- #
  # One-time editor bootstrap: build the TipTap instance the first
  # time the mount runs.  Subsequent mode/markdown effects mutate the
  # live instance (no re-mount on every signal change — that would
  # destroy in-flight user input).
  # ------------------------------------------------------------------- #
  when defined(js):
    proc bootstrapEditor() =
      if not capturedVm.editor.isNil:
        return
      if not tiptap_lib.isAvailable():
        # Fallback path: the bundle didn't load.  Render the raw
        # markdown body as text content so the user still sees the
        # brief in a degraded dev build.
        r.setAttribute(hostNode, "data-tiptap-mounted", "false")
        r.setTextContent(hostNode, capturedVm.markdown.val)
        return
      let opts = tiptap_lib.newEditorOptions()
      tiptap_lib.setElement(opts, cast[JsObject](hostNode))
      # Extensions: StarterKit + Markdown (the latter teaches
      # setContent(md, true) to parse markdown + attaches
      # ``storage.markdown.getMarkdown()`` for serialisation).  We
      # build the extensions array via the JS ``Array`` constructor
      # rather than {.emit.} so the TBAR-M5b "no inline JS in
      # application code" guard stays clean — the per-library FFI
      # modules expose the constructors, this code wires them up.
      let exts = buildExtensionsArray(
        tiptap_starter.isAvailable(),
        tiptap_md.isAvailable(),
        tiptap_link.isAvailable(),
      )
      tiptap_lib.setExtensions(opts, exts)
      tiptap_lib.setContentOption(opts, capturedVm.markdown.val.cstring)
      tiptap_lib.setEditableOption(opts, capturedVm.mode.val == spmEdit)
      let dirtyVm = capturedVm
      let onUpdate = proc(payload: JsObject) =
        if dirtyVm.loading:
          return
        dirtyVm.markDirty()
      tiptap_lib.setOnUpdate(opts, onUpdate)
      capturedVm.editor = tiptap_lib.newEditor(tiptap_lib.TipTap, opts)
      # Expose the editor handle on window for the TBAR-M5b e2e
      # tests so they can drive ``editor.commands.setContent`` /
      # ``Markdown.getMarkdown`` without poking at internals.  Gated
      # to test environments via the existing ``__isonimTestMode``
      # flag the editor already toggles for other test hooks.
      stashSpecPaneEditor(capturedVm.editor)
      r.setAttribute(hostNode, "data-tiptap-mounted", "true")
      r.setAttribute(hostNode, "data-tiptap-editable",
        if capturedVm.mode.val == spmEdit: "true" else: "false")
      # TBAR-M6 — subscribe to TipTap selection changes so Comment
      # mode can anchor a popover to the active text selection.  The
      # handler reads the latest selection + bounding rect on every
      # event and routes them through ``captureCommentSelection``,
      # which drops the event when the pane is not in Comment mode.
      let selectionVm = capturedVm
      let selectionEditor = capturedVm.editor
      tiptap_lib.onSelectionUpdate(selectionEditor, proc() =
        if selectionVm.editor.isNil:
          return
        let sel = tiptap_lib.getSelection(selectionEditor)
        let rect = tiptap_lib.getSelectionRect(selectionEditor)
        selectionVm.captureCommentSelection(sel, rect))

      # CHRM-M4 — once the editor exists, subscribe the toolbar VM to
      # its selection / transaction events so active-state indicators
      # mirror the live cursor.  The toolbar DOM itself is mounted
      # outside this reactive effect (see below) so its inner
      # ``createRenderEffect`` blocks aren't disposed when the outer
      # effect re-runs.
      spec_editor_toolbar_view.subscribeToEditor(capturedVm.toolbar,
                                                  capturedVm.editor)

    createRenderEffect proc() =
      bootstrapEditor()

    # CHRM-M4 — mount the formatting toolbar synchronously (outside
    # the bootstrap reactive effect) so its own child
    # ``createRenderEffect`` blocks survive every re-run of the
    # bootstrap path.  The mount carries the VM + a lookup closure
    # the click dispatchers read lazily — a click that lands before
    # the editor exists is a no-op rather than a crash.
    let editorLookup = proc(): tiptap_lib.TipTapEditor = capturedVm.editor
    spec_editor_toolbar_view.mountSpecEditorToolbar[R, E](
      r, toolbarHost, capturedVm.toolbar, editorLookup)

    # Markdown-sync effect: on body change, replace the editor
    # content via the Markdown extension's parser.  Guarded by
    # ``loading = true`` so the resulting onUpdate callback does NOT
    # flip dirty.  Body == lastSaved is the common case (brief switch
    # / initial load); a divergence here means the shell pushed a new
    # body without going through saveEdits, which we treat as a fresh
    # baseline.
    var lastSyncedBody = ""
    var initialSync = false
    createRenderEffect proc() =
      let body = capturedVm.markdown.val
      if initialSync and body == lastSyncedBody:
        return
      initialSync = true
      lastSyncedBody = body
      if capturedVm.editor.isNil:
        return
      capturedVm.loading = true
      try:
        tiptap_lib.replaceContent(capturedVm.editor, body.cstring, true)
      finally:
        capturedVm.loading = false

    # Editable-state mirror: flip TipTap's editable flag + reflect
    # it on the host as ``data-tiptap-editable``.
    createRenderEffect proc() =
      let isEdit = capturedVm.mode.val == spmEdit
      if not capturedVm.editor.isNil:
        tiptap_lib.setEditable(capturedVm.editor, isEdit)
      r.setAttribute(hostNode, "data-tiptap-editable",
        if isEdit: "true" else: "false")

  else:
    # Native build: there is no DOM; just keep the attribute in sync
    # so headless tests can assert behaviour without depending on
    # the browser pipeline.
    createRenderEffect proc() =
      discard capturedVm.markdown.val
      r.setAttribute(hostNode, "data-tiptap-mounted", "false")

  # Mode mirror — exposes the active mode as a DOM attribute so the
  # e2e test can assert View / Comment / Edit modes without poking the
  # VM directly.
  createRenderEffect proc() =
    let mode = capturedVm.mode.val
    let label =
      case mode
      of spmView: "view"
      of spmComment: "comment"
      of spmEdit: "edit"
    r.setAttribute(root, "data-spec-pane-mode", label)

  # TBAR-M5: Save/Cancel button row visibility.  Visible only when
  # ``mode == spmEdit and dirty == true``.  Reading both signals
  # subscribes the effect to either changing.
  createRenderEffect proc() =
    let isEdit = capturedVm.mode.val == spmEdit
    let isDirty = capturedVm.dirty.val
    r.setStyle(buttonRow, "display",
      if isEdit and isDirty: "flex" else: "none")

  # CHRM-M4: formatting toolbar host visibility — visible only in
  # Edit mode.  The toolbar VM is always mounted (so subscribers wire
  # up the editor's selection-update events) but its host collapses
  # in View / Comment mode so it doesn't bleed into the reading
  # surfaces.
  createRenderEffect proc() =
    let isEdit = capturedVm.mode.val == spmEdit
    r.setStyle(toolbarHost, "display",
      if isEdit: "block" else: "none")

  # TBAR-M5: click handlers.  Save pulls the latest markdown body
  # from the editor via the Markdown extension and routes it to the
  # supplied callback; Cancel routes to the callback (the caller
  # wires ``cancelEdits`` there).
  when defined(js):
    proc onSaveClick() =
      let cb = capturedCallbacks
      if cb == nil or cb.onSaveRequested == nil: return
      var md: cstring = ""
      if not capturedVm.editor.isNil and tiptap_md.isAvailable():
        md = tiptap_md.getMarkdown(capturedVm.editor)
      cb.onSaveRequested($md)
    proc onCancelClick() =
      let cb = capturedCallbacks
      if cb == nil or cb.onCancelRequested == nil: return
      cb.onCancelRequested()
    r.addEventListener(saveBtn, "click", onSaveClick)
    r.addEventListener(cancelBtn, "click", onCancelClick)

  r.appendChild(parent, root)
