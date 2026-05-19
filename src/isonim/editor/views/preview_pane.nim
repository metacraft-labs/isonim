## REV-M2: Preview-pane helpers — brief tab integration.
##
## The legacy preview pane lives in ``shell.nim``'s
## ``renderPreviewPane`` proc. REV-M2 layers a "Brief" tab onto that
## existing pane via a side-mount: ``mountBriefTabIntoPreviewPane``
## attaches a tab-strip + brief-tab pair to whatever container the
## caller hands it.  The legacy preview chrome and the rest of the
## pane structure stay untouched.
##
## All chrome added here is built via the ``ui:`` DSL with no raw
## ``setStyle`` calls — the milestone's
## ``test_brief_tab_view_uses_ui_dsl_not_setstyle`` lexer scan covers
## both this file and ``brief_tab.nim``.

import std/[options]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index_static
import isonim/editor/views/brief_tab
import isonim/editor/viewmodels
import isonim/editor/types

export brief_tab

type
  PreviewPaneTabKind* = enum
    pptPreview, pptBrief

  PreviewPaneState = ref object
    briefVm: BriefTabVM
    activeStorySignal: Signal[Option[StoryRef]]
    activeBackendSignal: Signal[PreviewBackend]
    activeTab: Signal[PreviewPaneTabKind]

# Per-EditorVM cache so renderPreviewPane can be re-invoked (tests run
# the proc multiple times against the same VM) without re-building the
# brief tab plumbing each time.  Keying on the VM ref identity keeps
# the cache scoped to the editor lifetime — Nim refs compare with ``==``
# on both native and JS backends, so this is portable.
var previewPaneStates {.threadvar.}: seq[(EditorVM, PreviewPaneState)]

proc statefor(vm: EditorVM): PreviewPaneState =
  for (k, v) in previewPaneStates:
    if k == vm: return v
  let storySig = createSignal[Option[StoryRef]](none[StoryRef]())
  let backendSig = createSignal(vm.platform.val)
  # Mirror EditorVM.selectedStory + platform into the brief-tab inputs.
  let capturedVm = vm
  createRenderEffect proc() =
    let cur = capturedVm.selectedStory.val
    if cur.name.len > 0:
      storySig.val = some(cur)
    else:
      storySig.val = none[StoryRef]()
  createRenderEffect proc() =
    backendSig.val = capturedVm.platform.val
  let state = PreviewPaneState(
    briefVm: createBriefTabVM(builtInBriefIndex(), storySig, backendSig),
    activeStorySignal: storySig,
    activeBackendSignal: backendSig,
    activeTab: createSignal(pptPreview))
  previewPaneStates.add((vm, state))
  state

proc briefTabVMFor*(vm: EditorVM): BriefTabVM =
  statefor(vm).briefVm

proc previewPaneActiveTabFor*(vm: EditorVM): Signal[PreviewPaneTabKind] =
  statefor(vm).activeTab

const
  ppTabBg          = "#0F172A"
  ppTabPanelBg     = "#111827"
  ppTabBorder      = "#334155"
  ppTabBorderFaint = "#1E293B"
  ppTabAccent      = "#7C7AED"
  ppTabTextPrimary = "#F1F5F9"
  ppTabTextMuted   = "#94A3B8"

proc mountBriefTabIntoPreviewPane*[R, E](r: R; container: E;
                                         briefVm: BriefTabVM;
                                         activeTab: Signal[PreviewPaneTabKind]) =
  ## Append a tab-strip + brief-tab pair into ``container``. The
  ## tab-strip carries two tabs (``Preview`` and ``Brief``); the brief
  ## body is shown only when the active tab is ``pptBrief`` AND the
  ## brief VM reports a covered preview.
  let capturedActiveTab = activeTab
  let capturedBriefVm = briefVm

  var previewTabNode: E
  var briefTabNode: E
  var briefHost: E

  let stripContainer = ui(r):
    tdiv(
      `data-preview-pane-brief-strip` = "true",
      display = "flex", flex_direction = "column",
      gap = "8px",
      padding = "8px 14px",
      background_color = ppTabBg,
      border_top = "1px solid " & ppTabBorder):
      tdiv(
        display = "flex", flex_direction = "row", align_items = "center",
        gap = "6px",
        `role` = "tablist",
        `aria-label` = "Preview pane tabs",
        `data-preview-pane-tabs` = "true"):
        tdiv(
          ref = previewTabNode,
          `role` = "tab", tabindex = "0",
          `data-preview-pane-tab` = "preview",
          `aria-label` = "Preview tab",
          padding = "4px 12px",
          font_size = "11px", font_weight = "600",
          color = ppTabTextPrimary,
          background_color = ppTabPanelBg,
          border = "1px solid " & ppTabBorderFaint,
          border_radius = "4px",
          cursor = "pointer"):
          text "Preview"
        tdiv(
          ref = briefTabNode,
          `role` = "tab", tabindex = "0",
          `data-preview-pane-tab` = "brief",
          `aria-label` = "Brief tab",
          padding = "4px 12px",
          font_size = "11px", font_weight = "600",
          color = ppTabTextMuted,
          background_color = ppTabPanelBg,
          border = "1px solid " & ppTabBorderFaint,
          border_radius = "4px",
          cursor = "pointer"):
          text "Brief"
      tdiv(
        ref = briefHost,
        display = "flex", flex_direction = "column",
        `data-preview-pane-brief-host` = "true")

  r.appendChild(container, stripContainer)

  # Mount the brief-tab body once into ``briefHost`` (subsequent
  # reactivity is driven by the VM signals — we don't tear down the
  # mount on tab switches).
  mountBriefTab[R, E](r, briefHost, briefVm)

  proc selectPreview() = capturedActiveTab.val = pptPreview
  proc selectBrief()   = capturedActiveTab.val = pptBrief
  r.addEventListener(previewTabNode, "click", selectPreview)
  r.addEventListener(previewTabNode, "keydown", selectPreview)
  r.addEventListener(briefTabNode, "click", selectBrief)
  r.addEventListener(briefTabNode, "keydown", selectBrief)

  createRenderEffect proc() =
    let tab = capturedActiveTab.val
    let briefVisible = capturedBriefVm.briefTabVisible.val
    let activeTabId = case tab
      of pptPreview: "preview"
      of pptBrief:   "brief"
    r.setAttribute(stripContainer, "data-active-tab", activeTabId)
    r.setAttribute(previewTabNode, "aria-selected",
                   if tab == pptPreview: "true" else: "false")
    r.setAttribute(briefTabNode, "aria-selected",
                   if tab == pptBrief: "true" else: "false")
    r.setAttribute(briefTabNode, "data-brief-tab-coverage",
                   if briefVisible: "covered" else: "uncovered")
    r.setAttribute(briefHost, "data-brief-host-visible",
                   if tab == pptBrief: "true" else: "false")
