## TBAR-M4 — Spec pane: TipTap-backed read-only renderer for the
## active brief's markdown body. The TBAR-M3 placeholder used a raw
## ``<pre>``-equivalent block fed the brief's body string; this
## milestone replaces that with a TipTap editor mounted in
## ``editable: false`` mode so the spec body gains the same rendered-
## text affordances code already enjoys (headings, lists, code
## blocks, links, etc.).
##
## ``SpecPaneVM`` carries the surface state. Comment and Edit modes
## (TBAR-M5 / TBAR-M6) still re-use ``mountTipTapViewer`` for now —
## the editability flag is owned by the TipTap shim and is wired in
## those later milestones; in TBAR-M4 every mode renders read-only.
##
## Dogfood: the wrapper structure is built via the ``ui:`` DSL. The
## TipTap mount itself touches container contents imperatively — that
## is the documented bridge to the foreign JS library and lives
## inside ``mountTipTapViewer`` (which wraps a vendored UMD).
##
## Fallback: when ``isTipTapAvailable()`` returns false (e.g. a dev
## build forgot to copy ``vendor/tiptap/`` into ``build/editor/``),
## the mount writes the raw markdown into the body host so the user
## still sees the brief instead of a blank pane.

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/vendor/tiptap_shim

type
  SpecPaneMode* = enum
    ## TBAR-M4 only wires View; Comment and Edit are TBAR-M5 / M6.
    spmView
    spmComment
    spmEdit

  SpecPaneVM* = ref object
    mode*: Signal[SpecPaneMode]
    markdown*: Signal[string]

proc createSpecPaneVM*(initialMarkdown: string = ""): SpecPaneVM =
  ## Build a fresh VM. Defaults to ``spmView`` mode and the supplied
  ## markdown body (empty string when the caller doesn't yet have a
  ## brief).
  SpecPaneVM(
    mode: createSignal(spmView),
    markdown: createSignal(initialMarkdown),
  )

proc setMarkdown*(vm: SpecPaneVM; markdown: string) =
  ## Replace the markdown body. ``Signal[string]``'s default equality
  ## short-circuits identical writes so subscribers (and the
  ## ``createRenderEffect`` inside ``mountSpecPane``) do not re-fire
  ## when the brief lookup yields the same body across resolves.
  vm.markdown.val = markdown

proc setMode*(vm: SpecPaneVM; mode: SpecPaneMode) =
  ## Replace the active mode. TBAR-M4 only renders View, but the
  ## signal is reactive so downstream tests (and TBAR-M5 / M6) can
  ## subscribe.
  vm.mode.val = mode

# --------------------------------------------------------------------------- #
#  View — ui DSL wrapper + a single createRenderEffect that drives the
#  TipTap content updates. Per the milestone brief the inner TipTap
#  mount is the only place that touches the container imperatively.
# --------------------------------------------------------------------------- #

proc mountSpecPane*[R, E](r: R; parent: E; vm: SpecPaneVM) =
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
  let capturedVm = vm
  var hostNode: E
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

  # Reactive content driver. ``markdown`` is the only input today; in
  # TBAR-M5 / M6 the mode signal will also influence the mount call
  # (e.g. flipping the editor to editable). For TBAR-M4 the mount is
  # always read-only — Comment / Edit modes render the same way until
  # those milestones land.
  createRenderEffect proc() =
    let body = capturedVm.markdown.val
    discard capturedVm.mode.val   # subscribe so future-mode changes re-mount
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

  r.appendChild(parent, root)
