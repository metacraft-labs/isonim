## TBAR-M4 / TBAR-M5 — Spec pane: TipTap-backed renderer for the
## active brief's markdown body, plus an Edit mode that lets the user
## modify the markdown and save it back to disk.
##
## ``SpecPaneVM`` carries the surface state. TBAR-M5 adds:
##   * ``dirty`` — Signal[bool], true when the markdown body differs
##     from the last saved value.
##   * ``lastSavedMarkdown`` — Signal[string], the body we'd revert to
##     on Cancel; updated by a successful save.
##   * ``enterEdit`` / ``saveEdits`` / ``cancelEdits`` procs.
##
## Edit-mode strategy (per the TBAR-M5 milestone brief): we keep
## TipTap as the View-mode renderer and overlay a plain ``<textarea>``
## for Edit mode. This sidesteps the lossy TipTap→markdown round-trip
## by storing what the user typed verbatim. The textarea is created /
## hidden by ``setTipTapEditable`` in ``vendor/tiptap_shim.nim``;
## ``getTipTapMarkdown`` returns the textarea's current value.
##
## Dogfood: the wrapper structure is built via the ``ui:`` DSL. The
## TipTap mount itself touches container contents imperatively — that
## is the documented bridge to the foreign JS library and lives
## inside ``mountTipTapViewer`` (which wraps a vendored UMD).

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/vendor/tiptap_shim

type
  SpecPaneMode* = enum
    ## TBAR-M4 wires View; TBAR-M5 wires Edit; Comment is TBAR-M6.
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

proc createSpecPaneVM*(initialMarkdown: string = ""): SpecPaneVM =
  ## Build a fresh VM. Defaults to ``spmView`` mode and the supplied
  ## markdown body (empty string when the caller doesn't yet have a
  ## brief). The initial markdown also seeds ``lastSavedMarkdown`` so
  ## ``dirty`` starts at ``false``.
  SpecPaneVM(
    mode: createSignal(spmView),
    markdown: createSignal(initialMarkdown),
    lastSavedMarkdown: createSignal(initialMarkdown),
    dirty: createSignal(false),
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
  vm.mode.val = mode

proc enterEdit*(vm: SpecPaneVM) =
  ## TBAR-M5 — flip the pane into Edit mode. The mount's editable-
  ## sync effect picks up the mode change and calls
  ## ``setTipTapEditable(host, true)``. ``dirty`` stays false until
  ## the user types something (the mount listens for textarea input).
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
  ## mount when it observes a textarea ``input`` event (we don't yet
  ## know the new markdown value at that moment; the spec-pane just
  ## flips the flag and the next save reads the textarea's current
  ## content).
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
    ## textarea via ``getTipTapMarkdown``.  ``onCancel`` runs on the
    ## Cancel button; the mount routes it through ``cancelEdits``.
    onSaveRequested*: proc(markdown: string) {.closure.}
    onCancelRequested*: proc() {.closure.}

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
  ##   3. A ``createRenderEffect`` that calls
  ##      ``mountTipTapViewer(host, vm.markdown.val)`` on every
  ##      change. The shim destroys the previous Editor first so
  ##      we don't leak ProseMirror state.
  ##   4. A second ``createRenderEffect`` syncs the mode signal onto a
  ##      ``data-spec-pane-mode`` attribute so downstream views can
  ##      react to the active mode without subscribing to the
  ##      VM directly.
  ##   5. TBAR-M5: a third effect calls ``setTipTapEditable`` when the
  ##      mode signal changes — Edit mode swaps in the textarea
  ##      overlay; View / Comment modes restore the read-only TipTap
  ##      surface.
  ##   6. TBAR-M5: a Save / Cancel button row, visible only when
  ##      ``mode == spmEdit and dirty``.
  let capturedVm = vm
  let capturedCallbacks = callbacks
  var hostNode: E
  var saveBtn: E
  var cancelBtn: E
  var buttonRow: E
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

  # Reactive content driver. ``markdown`` is the only input today.
  # TBAR-M5: we explicitly do NOT track ``mode.val`` here — the
  # editable-state effect below handles mode flips by calling
  # ``setTipTapEditable`` (a textarea overlay swap, not a re-mount).
  # Re-mounting TipTap on every mode flip would have two bad
  # consequences: (a) the View-mode ``mountViewer`` call resets
  # ``data-tiptap-editable`` to ``"false"`` and would race with the
  # editable effect's ``setAttribute('data-tiptap-editable', 'true')``;
  # (b) any user-typed textarea content (Edit mode) would be
  # destroyed when the editor re-mounts.
  createRenderEffect proc() =
    let body = capturedVm.markdown.val
    when defined(js):
      # Foreign-JS bridge: imperatively swap the TipTap content. The
      # shim deduplicates per-container so this is also safe to call
      # repeatedly with the same body.
      if isTipTapAvailable():
        mountTipTapViewer(cast[Element](hostNode), body)
      else:
        # Fallback path: the vendor UMD didn't load. Render the raw
        # markdown body via setTextContent so the user still sees the
        # brief content rather than a blank pane. This keeps the dev
        # loop forgiving when ``build/editor/vendor/tiptap/`` is
        # missing.
        r.setAttribute(hostNode, "data-tiptap-mounted", "false")
        r.setTextContent(hostNode, body)
    else:
      # Native build: there is no DOM; just keep the attribute in
      # sync so headless tests can assert behaviour without depending
      # on the browser pipeline.
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

  # TBAR-M5: editability sync.  When the mode flips to Edit the shim
  # swaps in the textarea overlay; flipping back to View / Comment
  # hides it.  ``isTipTapAvailable`` gating means a fallback build
  # (no vendor UMD) silently degrades to a plain markdown <pre>
  # rendering without crashing the editor.
  createRenderEffect proc() =
    let mode = capturedVm.mode.val
    when defined(js):
      if isTipTapAvailable():
        setTipTapEditable(cast[Element](hostNode), mode == spmEdit)
    else:
      setTipTapEditable(cast[Element](hostNode), mode == spmEdit)

  # TBAR-M5: Save/Cancel button row visibility.  Visible only when
  # ``mode == spmEdit and dirty == true``.  Reading both signals
  # subscribes the effect to either changing.
  createRenderEffect proc() =
    let isEdit = capturedVm.mode.val == spmEdit
    let isDirty = capturedVm.dirty.val
    r.setStyle(buttonRow, "display",
      if isEdit and isDirty: "flex" else: "none")

  # TBAR-M5: click handlers.  Save pulls the latest markdown body
  # from the textarea (the source of truth in Edit mode) and routes
  # it to the supplied callback; Cancel routes to the callback (the
  # caller wires ``cancelEdits`` there).
  when defined(js):
    proc onSaveClick() =
      let cb = capturedCallbacks
      if cb == nil or cb.onSaveRequested == nil: return
      let md = getTipTapMarkdown(cast[Element](hostNode))
      cb.onSaveRequested(md)
    proc onCancelClick() =
      let cb = capturedCallbacks
      if cb == nil or cb.onCancelRequested == nil: return
      cb.onCancelRequested()
    r.addEventListener(saveBtn, "click", onSaveClick)
    r.addEventListener(cancelBtn, "click", onCancelClick)

    # TBAR-M5: hook a textarea-input listener so typing flips
    # ``dirty`` to true.  The shim's ``setTipTapEditable`` attaches
    # a JS-side ``input`` listener on the textarea that dispatches a
    # bubbling ``isonim-spec-dirty`` CustomEvent on the host; the
    # Nim closure ``onSpecDirty`` consumes it via the renderer's
    # ``input`` overload (CustomEvent names go through the same
    # ``addEventListener`` plumbing).
    let dirtyVm = capturedVm
    proc onSpecDirty() =
      dirtyVm.markDirty()
    r.addEventListener(hostNode, "isonim-spec-dirty", onSpecDirty)
    # Also dispatch the synthetic event manually whenever the
    # browser's native ``input`` event fires on a textarea inside
    # the host — Playwright-driven dispatchEvent calls land here
    # first in some browsers, so the dirty signal survives even if
    # the shim's listener hasn't been wired yet (e.g. because the
    # initial mount in View mode never created the textarea).
    proc onAnyInput() =
      dirtyVm.markDirty()
    r.addEventListener(hostNode, "input", onAnyInput)

  r.appendChild(parent, root)
