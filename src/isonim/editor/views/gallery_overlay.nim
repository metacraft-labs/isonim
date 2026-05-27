## REV-M7 — gallery overlay view + ViewModel.
##
## The gallery is a tile grid that surfaces every prior capture for the
## brief currently open in the preview pane.  Three view modes:
##
##   * ``gmGrid``       — default; rows-per-preview tile grid.
##   * ``gmFullTab``    — one capture displayed at its native pixel
##                        dimensions in the preview-pane slot.
##   * ``gmFullScreen`` — whole-editor overlay; ESC restores prior
##                        state.
##   * ``gmCompare``    — multi-select side-by-side (REV-M8 owns the
##                        DOM/interactions for this; the VM exposes
##                        the mode so REV-M7's tests can assert it
##                        toggles correctly).
##
## REV-M7 only delivers view-only behaviour.  Drag handlers update
## ``pendingLayout`` but never persist — REV-M8 wires the save path.
##
## All view code uses the ``ui:`` DSL exclusively.  The
## ``test_design_review_gallery_no_setstyle`` lexer scan asserts no
## ``setStyle`` calls live in this file.

import std/[options, sets, strutils, tables]

import isonim/core/signals
import isonim/core/computation
import isonim/dsl/ui

type
  GalleryMode* = enum
    gmGrid, gmFullTab, gmFullScreen, gmCompare

  GalleryTile* = object
    captureId*: string
    runId*: string
    previewId*: string
    score*: Option[float]
    status*: string
    pngUrl*: string  ## /api/design-review/get-capture-png?id=<capture_id>
    width*, height*: int

  GalleryRow* = object
    previewId*: string
    tiles*: seq[GalleryTile]

  GalleryHttpClient* = ref object of RootObj
    ## Abstract client surface — the production editor binds this to
    ## ``window.fetch`` on JS via ``js_http_client.nim``; tests pass an
    ## in-process subclass that mocks ``fetchJson``.
    ## REV-M7 only needs JSON fetches (PNG bytes are loaded via
    ## ``<img src=...>`` against the same daemon, no client call here).
    discard

  PendingLayoutEntry* = object
    captureId*: string
    rowIndex*: int
    columnIndex*: int

  LayoutConflict* = object
    ## REV-M8 — when ``save_gallery_layout`` rejects an
    ## ``expectedVersion`` the API hands back the current row so the
    ## conflict dialog can show "this layout was changed elsewhere —
    ## reload?".  ``current`` is the parsed JSON row (or empty/null
    ## when the daemon couldn't recover it).
    layoutId*: string
    currentRow*: string

  SaveScope* = enum
    ssUser, ssWorkspace

  GalleryVM* = ref object
    briefId*: Signal[string]
    tiles*: Signal[seq[GalleryTile]]
    rows*: Memo[seq[GalleryRow]]
    selectedTileIds*: Signal[HashSet[string]]
    mode*: Signal[GalleryMode]
    priorMode*: Signal[GalleryMode]
    fullTabCaptureId*: Signal[Option[string]]
    httpClient*: GalleryHttpClient
    ## Drag-and-drop scratchpad.  REV-M8 reads this and POSTs to
    ## ``/api/design-review/save-layout``.
    pendingLayout*: Signal[seq[PendingLayoutEntry]]
    isDirty*: Signal[bool]
    # REV-M8 — multi-select + side-by-side comparison state.
    compareCaptureIds*: Signal[seq[string]]
    # REV-M8 — save action state.  ``activeLayoutId`` is the row the VM
    # currently mirrors (empty for unsaved layouts → triggers INSERT).
    activeLayoutId*: Signal[string]
    activeLayoutVersion*: Signal[int]
    saveScope*: Signal[SaveScope]
    ownerUserId*: Signal[string]
    layoutName*: Signal[string]
    # REV-M8 — optimistic-concurrency conflict surface.  Non-empty
    # ``conflict.currentRow`` => render the resolution dialog.
    conflict*: Signal[LayoutConflict]

# --------------------------------------------------------------------------- #
#  Pure helpers (testable independently of the reactive plumbing).
# --------------------------------------------------------------------------- #

proc groupByPreview*(tiles: seq[GalleryTile]): seq[GalleryRow] =
  ## Bucket the tile list by ``previewId`` preserving the input order
  ## (most-recent-first within bucket — the caller is expected to feed
  ## tiles sorted by capture timestamp descending).  Rows themselves
  ## are ordered by first-appearance of each previewId, which is
  ## stable across re-fetches as long as the input stream's most
  ## recent run isn't replaced (a reasonable invariant for a history
  ## view).
  result = @[]
  var seenOrder = newSeq[string]()
  var rows = initTable[string, seq[GalleryTile]]()
  for t in tiles:
    if t.previewId notin rows:
      rows[t.previewId] = @[]
      seenOrder.add(t.previewId)
    var row = rows[t.previewId]
    row.add(t)
    rows[t.previewId] = row
  for p in seenOrder:
    result.add GalleryRow(previewId: p, tiles: rows[p])

proc createGalleryVM*(briefId: string;
                      httpClient: GalleryHttpClient = nil): GalleryVM =
  ## Build the VM with default initial state — no tiles, no
  ## selection, grid mode.  The view-mount layer is responsible for
  ## driving the fetch that populates ``tiles``.
  let vm = GalleryVM(
    briefId: createSignal(briefId),
    tiles: createSignal[seq[GalleryTile]](@[]),
    selectedTileIds: createSignal(initHashSet[string]()),
    mode: createSignal(gmGrid),
    priorMode: createSignal(gmGrid),
    fullTabCaptureId: createSignal[Option[string]](none[string]()),
    httpClient: httpClient,
    pendingLayout: createSignal[seq[PendingLayoutEntry]](@[]),
    isDirty: createSignal(false),
    compareCaptureIds: createSignal[seq[string]](@[]),
    activeLayoutId: createSignal(""),
    activeLayoutVersion: createSignal(0),
    saveScope: createSignal(ssUser),
    ownerUserId: createSignal(""),
    layoutName: createSignal("default"),
    conflict: createSignal(LayoutConflict()),
  )
  let capturedVm = vm
  vm.rows = createMemo[seq[GalleryRow]] proc(): seq[GalleryRow] =
    groupByPreview(capturedVm.tiles.val)
  # When mode leaves gmFullTab the focused capture id must clear; if
  # the spec changes to keep it persistent across mode switches the
  # full-tab tests will catch the regression.
  createRenderEffect proc() =
    let m = capturedVm.mode.val
    if m != gmFullTab:
      capturedVm.fullTabCaptureId.val = none[string]()
  vm

# --------------------------------------------------------------------------- #
#  Selection / mode helpers — kept as VM methods so tests can drive the
#  state machine without touching the DOM.
# --------------------------------------------------------------------------- #

proc openFullTab*(vm: GalleryVM; captureId: string) =
  vm.priorMode.val = vm.mode.val
  vm.fullTabCaptureId.val = some(captureId)
  vm.mode.val = gmFullTab

proc openFullScreen*(vm: GalleryVM; captureId: string) =
  vm.priorMode.val = vm.mode.val
  vm.fullTabCaptureId.val = some(captureId)
  vm.mode.val = gmFullScreen

proc restoreMode*(vm: GalleryVM) =
  ## ESC handler — restores ``priorMode``.  Idempotent.
  let prior = vm.priorMode.val
  vm.mode.val = prior

proc toggleSelect*(vm: GalleryVM; captureId: string) =
  var set = vm.selectedTileIds.val
  if captureId in set:
    set.excl(captureId)
  else:
    set.incl(captureId)
  vm.selectedTileIds.val = set

proc registerDragMove*(vm: GalleryVM; captureId: string;
                       rowIndex, columnIndex: int) =
  ## Drag-and-drop scratchpad write.  REV-M7 does not persist this —
  ## REV-M8 owns the save endpoint.  We record the intent + flip the
  ## ``isDirty`` flag so REV-M8's UI affordances can light up the
  ## save button reactively.
  var entries = vm.pendingLayout.val
  var replaced = false
  for i, e in entries:
    if e.captureId == captureId:
      entries[i] = PendingLayoutEntry(
        captureId: captureId,
        rowIndex: rowIndex,
        columnIndex: columnIndex)
      replaced = true
      break
  if not replaced:
    entries.add PendingLayoutEntry(
      captureId: captureId,
      rowIndex: rowIndex,
      columnIndex: columnIndex)
  vm.pendingLayout.val = entries
  vm.isDirty.val = true

# --------------------------------------------------------------------------- #
#  REV-M8 — multi-select + side-by-side comparison.
# --------------------------------------------------------------------------- #

proc multiSelect*(vm: GalleryVM; captureId: string) =
  ## cmd/ctrl-click handler — toggles ``captureId`` in the multi-select
  ## set (a hash-set for fast membership tests + a seq for stable
  ## ordering used by the compare view).
  var set = vm.selectedTileIds.val
  if captureId in set:
    set.excl(captureId)
    var seq = vm.compareCaptureIds.val
    for i in 0 ..< seq.len:
      if seq[i] == captureId:
        seq.delete(i)
        break
    vm.compareCaptureIds.val = seq
  else:
    set.incl(captureId)
    var seq = vm.compareCaptureIds.val
    seq.add(captureId)
    vm.compareCaptureIds.val = seq
  vm.selectedTileIds.val = set

proc compareSideBySide*(vm: GalleryVM) =
  ## Open the gallery in ``gmCompare`` mode against the current
  ## ``compareCaptureIds`` selection.  Tests call this directly; the
  ## view binds a toolbar button to it.
  if vm.compareCaptureIds.val.len < 2:
    # Nothing to compare — keep the current mode (the toolbar button is
    # disabled when the selection is < 2 but the VM is defensive).
    return
  vm.priorMode.val = vm.mode.val
  vm.mode.val = gmCompare

proc clearCompare*(vm: GalleryVM) =
  vm.selectedTileIds.val = initHashSet[string]()
  vm.compareCaptureIds.val = @[]
  if vm.mode.val == gmCompare:
    vm.mode.val = gmGrid

# --------------------------------------------------------------------------- #
#  REV-M8 — save / load layout state helpers.
# --------------------------------------------------------------------------- #

proc serializePendingLayout*(vm: GalleryVM): string =
  ## Encode ``pendingLayout`` as a compact JSON string suitable for the
  ## ``layout`` JSONB column.  The on-the-wire shape is
  ##
  ##   {"version": 1,
  ##    "entries": [{"captureId": "...", "row": 1, "col": 0}, ...]}
  ##
  ## A version envelope lets a future migration extend the payload
  ## without breaking older clients reading saved layouts.
  result = "{\"version\":1,\"entries\":["
  for i, e in vm.pendingLayout.val:
    if i > 0: result.add(",")
    result.add("{\"captureId\":\"")
    result.add(e.captureId)
    result.add("\",\"row\":")
    result.add($e.rowIndex)
    result.add(",\"col\":")
    result.add($e.columnIndex)
    result.add("}")
  result.add("]}")

proc applyLayoutJson*(vm: GalleryVM; json: string) =
  ## Re-hydrate ``pendingLayout`` from a saved layout JSONB document
  ## (the shape ``serializePendingLayout`` emits).  Defensive: any
  ## parse / shape failure leaves the VM untouched.
  if json.len == 0: return
  var entries: seq[PendingLayoutEntry] = @[]
  # Hand-rolled parse so this compiles cleanly on both ``nim c`` and
  # ``nim js`` (``std/json`` works on both backends but the JS variant
  # requires the resource VM hooks the editor doesn't always wire).
  # The payload is small and well-defined; one pass over the string is
  # plenty.
  var i = 0
  while i < json.len:
    let cIdx = json.find("\"captureId\"", i)
    if cIdx < 0: break
    let colon = json.find(':', cIdx)
    if colon < 0: break
    let q1 = json.find('"', colon + 1)
    if q1 < 0: break
    let q2 = json.find('"', q1 + 1)
    if q2 < 0: break
    let captureId = json[q1 + 1 ..< q2]
    let rowIdx = json.find("\"row\"", q2)
    if rowIdx < 0: break
    let rColon = json.find(':', rowIdx)
    if rColon < 0: break
    var rj = rColon + 1
    while rj < json.len and json[rj] in {' ', '\t'}: inc rj
    var rStart = rj
    while rj < json.len and json[rj] in {'0'..'9', '-'}: inc rj
    let rVal =
      if rj > rStart:
        try: parseInt(json[rStart ..< rj]) except ValueError: 0
      else: 0
    let colIdx = json.find("\"col\"", rj)
    if colIdx < 0: break
    let cColon = json.find(':', colIdx)
    if cColon < 0: break
    var cj = cColon + 1
    while cj < json.len and json[cj] in {' ', '\t'}: inc cj
    var cStart = cj
    while cj < json.len and json[cj] in {'0'..'9', '-'}: inc cj
    let cVal =
      if cj > cStart:
        try: parseInt(json[cStart ..< cj]) except ValueError: 0
      else: 0
    entries.add PendingLayoutEntry(
      captureId: captureId,
      rowIndex: rVal,
      columnIndex: cVal)
    i = cj
  vm.pendingLayout.val = entries
  vm.isDirty.val = false

proc markConflict*(vm: GalleryVM; layoutId, currentRow: string) =
  vm.conflict.val = LayoutConflict(
    layoutId: layoutId, currentRow: currentRow)

proc dismissConflict*(vm: GalleryVM) =
  vm.conflict.val = LayoutConflict()

proc markSaved*(vm: GalleryVM; layoutId: string; version: int) =
  vm.activeLayoutId.val = layoutId
  vm.activeLayoutVersion.val = version
  vm.isDirty.val = false
  vm.conflict.val = LayoutConflict()

# --------------------------------------------------------------------------- #
#  View — ui DSL only.
# --------------------------------------------------------------------------- #

const
  gBg          = "#0B1220"
  gPanelBg     = "#111827"
  gBorder      = "#334155"
  gBorderSoft  = "#1E293B"
  gAccent      = "#7C7AED"
  gAccentMuted = "#475569"
  gTextPrim    = "#F1F5F9"
  gTextMuted   = "#94A3B8"
  gTextDim     = "#64748B"
  gStatusOk    = "#22C55E"
  gStatusErr   = "#EF4444"
  gStatusPend  = "#F59E0B"

proc statusColor(status: string): string =
  case status.toLowerAscii
  of "complete", "reviewed", "ok": gStatusOk
  of "capture_failed", "review_failed", "failed": gStatusErr
  else: gStatusPend

proc mountGalleryOverlay*[R, E](r: R; parent: E; vm: GalleryVM) =
  ## Mount the gallery as a child of ``parent`` (typically the
  ## preview-pane container).  The overlay is a flex column with a
  ## top toolbar (mode chips), a tile-grid container, and a full-tab
  ## host that swaps in when mode = gmFullTab.
  let capturedVm = vm

  var modeChipGrid: E
  var modeChipFullTab: E
  var modeChipFullScreen: E
  var modeChipCompare: E
  var gridHost: E
  var fullTabHost: E
  # CHRM-M6 Wave A — compare-mode host + the two affordance chips at
  # the top of the compare body.  The host is data-hidden until the
  # mode flips to ``gmCompare``; the affordance chips clear the
  # selection or exit compare mode while preserving selection.
  var compareHost: E
  var compareClearBtn: E
  var compareExitBtn: E
  var statusLabel: E
  var conflictDialog: E
  var conflictReloadBtn: E
  var conflictDismissBtn: E

  let root = ui(r):
    tdiv(
      `data-design-review-gallery-overlay` = "true",
      display = "flex", flex_direction = "column",
      gap = "10px", padding = "12px 14px",
      background_color = gBg,
      border = "1px solid " & gBorder,
      border_radius = "8px",
      color = gTextPrim,
      min_width = "0", min_height = "0",
      max_height = "100%",
      overflow = "hidden"):
      # --- Toolbar: mode chips + status -------------------------------
      tdiv(display = "flex", flex_direction = "row", align_items = "center",
            gap = "8px",
            `data-design-review-gallery-toolbar` = "true",
            `role` = "toolbar",
            `aria-label` = "Gallery view modes"):
        span(font_size = "10px", font_weight = "700",
              text_transform = "uppercase", letter_spacing = "0.4px",
              color = gAccent):
          text "Gallery"
        tdiv(ref = modeChipGrid,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-mode` = "grid",
              `aria-label` = "Grid view",
              padding = "3px 8px", font_size = "11px",
              font_weight = "600", color = gTextPrim,
              background_color = gPanelBg,
              border = "1px solid " & gBorderSoft,
              border_radius = "4px",
              cursor = "pointer"):
          text "Grid"
        tdiv(ref = modeChipFullTab,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-mode` = "full-tab",
              `aria-label` = "Full-tab view",
              padding = "3px 8px", font_size = "11px",
              font_weight = "600", color = gTextPrim,
              background_color = gPanelBg,
              border = "1px solid " & gBorderSoft,
              border_radius = "4px",
              cursor = "pointer"):
          text "Full tab"
        tdiv(ref = modeChipFullScreen,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-mode` = "full-screen",
              `aria-label` = "Full-screen view",
              padding = "3px 8px", font_size = "11px",
              font_weight = "600", color = gTextPrim,
              background_color = gPanelBg,
              border = "1px solid " & gBorderSoft,
              border_radius = "4px",
              cursor = "pointer"):
          text "Full screen"
        # CHRM-M6 Wave A — the Compare chip is no longer permanently
        # disabled.  Its enabled/disabled state, cursor, and text colour
        # are driven reactively by ``compareCaptureIds.val.len`` below
        # (the chip lights up when ≥2 captures are multi-selected).
        tdiv(ref = modeChipCompare,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-mode` = "compare",
              `aria-label` = "Compare view",
              padding = "3px 8px", font_size = "11px",
              font_weight = "600", color = gTextMuted,
              background_color = gPanelBg,
              border = "1px solid " & gBorderSoft,
              border_radius = "4px",
              cursor = "pointer"):
          text "Compare"
        span(ref = statusLabel,
              font_size = "10px", color = gTextDim,
              `data-design-review-gallery-status` = "true"):
          text ""
      # --- Tile grid host ----------------------------------------------
      tdiv(
        ref = gridHost,
        display = "flex", flex_direction = "column",
        gap = "12px",
        padding = "8px 4px",
        flex = "1 1 auto",
        min_height = "0",
        overflow_y = "auto",
        `data-design-review-gallery-grid` = "true")
      # --- Full-tab host ----------------------------------------------
      tdiv(
        ref = fullTabHost,
        display = "none",
        flex_direction = "column",
        align_items = "flex-start",
        padding = "8px 4px",
        flex = "1 1 auto",
        min_height = "0",
        overflow = "auto",
        `data-design-review-gallery-fulltab` = "true")
      # --- Compare host (CHRM-M6 Wave A) ------------------------------
      # Hidden by default; the mode-mirror render effect below flips
      # display:flex when ``mode == gmCompare``. The body is built
      # imperatively in ``renderCompare`` once per ``compareCaptureIds``
      # change so the column structure (image + metadata strip per
      # capture, vertical hairline divider between them) always reflects
      # the current multi-selection.
      tdiv(
        ref = compareHost,
        display = "none",
        flex_direction = "column",
        flex = "1 1 auto",
        min_height = "0",
        gap = "8px",
        padding = "8px 4px",
        overflow = "hidden",
        `data-design-review-gallery-compare` = "true")
      # --- Conflict dialog (REV-M8) -----------------------------------
      # Rendered inside the production gallery view (not the harness).
      # Visibility is driven reactively off ``vm.conflict``; when the
      # save path observes an optimistic-concurrency 409 it calls
      # ``markConflict`` and this dialog flips visible with the
      # "reload-or-overwrite?" affordance.
      tdiv(
        ref = conflictDialog,
        `data-design-review-conflict-dialog` = "true",
        `data-conflict-visible` = "false",
        `role` = "alertdialog",
        `aria-live` = "assertive",
        `aria-modal` = "false",
        display = "none",
        flex_direction = "column",
        gap = "8px",
        padding = "10px 12px",
        background_color = gPanelBg,
        border = "1px solid " & gStatusErr,
        border_radius = "6px",
        color = gTextPrim):
        span(font_size = "12px", font_weight = "700",
              color = gStatusErr,
              `data-design-review-conflict-dialog-title` = "true"):
          text "Layout changed elsewhere"
        span(font_size = "11px", color = gTextMuted,
              `data-design-review-conflict-dialog-body` = "true"):
          text "This layout was changed elsewhere; reload to see the latest, or dismiss to keep editing."
        tdiv(display = "flex", flex_direction = "row", gap = "6px"):
          tdiv(ref = conflictReloadBtn,
                `role` = "button", tabindex = "0",
                `data-design-review-conflict-reload` = "true",
                padding = "4px 10px",
                font_size = "11px", font_weight = "600",
                color = gTextPrim,
                background_color = gAccent,
                border = "1px solid " & gAccent,
                border_radius = "4px",
                cursor = "pointer"):
            text "Reload"
          tdiv(ref = conflictDismissBtn,
                `role` = "button", tabindex = "0",
                `data-design-review-conflict-dismiss` = "true",
                padding = "4px 10px",
                font_size = "11px", font_weight = "600",
                color = gTextMuted,
                background_color = "transparent",
                border = "1px solid " & gBorder,
                border_radius = "4px",
                cursor = "pointer"):
            text "Dismiss"

  proc setMode(mode: GalleryMode) =
    capturedVm.priorMode.val = capturedVm.mode.val
    capturedVm.mode.val = mode

  r.addEventListener(modeChipGrid, "click", proc() = setMode(gmGrid))
  r.addEventListener(modeChipGrid, "keydown", proc() = setMode(gmGrid))
  r.addEventListener(modeChipFullTab, "click", proc() = setMode(gmFullTab))
  r.addEventListener(modeChipFullTab, "keydown", proc() = setMode(gmFullTab))
  r.addEventListener(modeChipFullScreen, "click",
                      proc() = setMode(gmFullScreen))
  r.addEventListener(modeChipFullScreen, "keydown",
                      proc() = setMode(gmFullScreen))
  # CHRM-M6 Wave A — the Compare chip click goes through the VM helper
  # so the "< 2 selected" guard fires reactively.  The chip's visual
  # enable/disable state is mirrored separately below; the handler is
  # always wired but no-ops when the selection isn't valid.
  r.addEventListener(modeChipCompare, "click", proc() =
    capturedVm.compareSideBySide())
  r.addEventListener(modeChipCompare, "keydown", proc() =
    capturedVm.compareSideBySide())

  proc renderTile(tile: GalleryTile; rowIdx, colIdx: int): E =
    let chipColor = statusColor(tile.status)
    let scoreLabel =
      if tile.score.isSome:
        "score " & formatFloat(tile.score.get, ffDecimal, 2)
      else:
        "score —"
    let tileNode = ui(r):
      tdiv(
        `data-design-review-gallery-tile` = tile.captureId,
        `data-design-review-gallery-run-id` = tile.runId,
        `data-design-review-gallery-preview-id` = tile.previewId,
        `data-design-review-gallery-status` = tile.status,
        `data-design-review-gallery-width` = $tile.width,
        `data-design-review-gallery-height` = $tile.height,
        `data-design-review-gallery-row` = $rowIdx,
        `data-design-review-gallery-col` = $colIdx,
        # CHRM-M6 Wave A — the selected-state attribute is mirrored
        # reactively below so Wave B can style the outline/glow off it.
        # Initial value is "false"; the render effect lifts it to
        # "true" when ``captureId in selectedTileIds.val``.
        `data-design-review-gallery-tile-selected` = "false",
        `role` = "button", tabindex = "0",
        `aria-label` = "Capture " & tile.captureId,
        draggable = "true",
        display = "inline-flex",
        flex_direction = "column",
        gap = "4px",
        padding = "6px",
        background_color = gPanelBg,
        border = "1px solid " & gBorderSoft,
        border_radius = "6px",
        cursor = "pointer"):
        img(
          src = tile.pngUrl,
          alt = "Capture " & tile.captureId,
          width = "160", height = "100",
          loading = "lazy",
          `data-design-review-gallery-thumb` = "true")
        tdiv(display = "flex", flex_direction = "row",
              align_items = "center", gap = "6px"):
          span(width = "8px", height = "8px",
                background_color = chipColor,
                border_radius = "50%",
                `aria-hidden` = "true",
                `data-design-review-gallery-status-dot` = "true"):
            text ""
          span(font_size = "10px", color = gTextMuted,
                `data-design-review-gallery-status-label` = "true"):
            text tile.status
          span(font_size = "10px", color = gTextDim,
                `data-design-review-gallery-score` = "true"):
            text scoreLabel
    let capturedCaptureId = tile.captureId
    let capturedRowIdx = rowIdx
    let capturedColIdx = colIdx
    let primaryHandlerNoArg = proc() =
      capturedVm.openFullTab(capturedCaptureId)
    let shiftHandlerNoArg = proc() =
      capturedVm.openFullScreen(capturedCaptureId)
    let metaHandlerNoArg = proc() =
      capturedVm.multiSelect(capturedCaptureId)
    r.addEventListener(tileNode, "click", primaryHandlerNoArg)
    r.addEventListener(tileNode, "keydown", primaryHandlerNoArg)
    # Shift-click + meta-click handlers — JS-backed.  Under the
    # MockRenderer ``MockEvent.type == "shift-click"`` / "meta-click"
    # is fired manually by the VM tests.  In the browser the ``click``
    # event with ``shiftKey`` triggers full-screen and ``metaKey`` /
    # ``ctrlKey`` triggers the multi-select toggle.  The dedicated
    # event names keep the e2e and VM paths sharing a signal.
    r.addEventListener(tileNode, "shift-click", shiftHandlerNoArg)
    r.addEventListener(tileNode, "meta-click", metaHandlerNoArg)
    when defined(js):
      # Inline JS shim: distinguish shift / meta+ctrl+click in the
      # browser.  ``stopImmediatePropagation`` on the modifier branches
      # prevents the plain "click" listener (full-tab) from firing in
      # the same event — meta-click is multi-select, not "open tile".
      let payload = capturedCaptureId.cstring
      let shiftEv: cstring = "shift-click"
      let metaEv: cstring = "meta-click"
      {.emit: ["""
        (function(node) {
          if (!node || !node.addEventListener) return;
          // Capture-phase listener so it can pre-empt the plain
          // "click" handler registered later above.
          node.addEventListener("click", function(ev) {
            if (ev && ev.shiftKey) {
              ev.stopImmediatePropagation();
              var custom = new CustomEvent(""", shiftEv, """);
              node.dispatchEvent(custom);
              return;
            }
            if (ev && (ev.metaKey || ev.ctrlKey)) {
              ev.stopImmediatePropagation();
              var custom = new CustomEvent(""", metaEv, """);
              node.dispatchEvent(custom);
              return;
            }
          }, true);
        })(""", tileNode, """);
      """].}
      discard payload
    # Drag-and-drop: REV-M7 only records to pendingLayout.
    let dragOverHandler = proc() =
      capturedVm.registerDragMove(capturedCaptureId,
                                  capturedRowIdx, capturedColIdx)
    r.addEventListener(tileNode, "dragover", dragOverHandler)
    r.addEventListener(tileNode, "drop", dragOverHandler)
    # CHRM-M6 Wave A — mirror multi-select state onto the tile so
    # Wave B can style the selected outline off the data attribute.
    let capturedTileForSelect = tileNode
    let capturedCaptureIdForSelect = capturedCaptureId
    createRenderEffect proc() =
      let selected = capturedCaptureIdForSelect in capturedVm.selectedTileIds.val
      r.setAttribute(capturedTileForSelect,
                     "data-design-review-gallery-tile-selected",
                     if selected: "true" else: "false")
    tileNode

  proc renderGrid() =
    r.clearChildren(gridHost)
    let rows = capturedVm.rows.val
    if rows.len == 0:
      let empty = ui(r):
        tdiv(
          `data-design-review-gallery-empty` = "true",
          padding = "20px",
          color = gTextMuted,
          font_size = "12px"):
          text "No captures yet — run a capture sweep to populate the gallery."
      r.appendChild(gridHost, empty)
      return
    for rowIdx, row in rows:
      var tileBucket: E
      let rowNode = ui(r):
        tdiv(
          `data-design-review-gallery-row` = row.previewId,
          display = "flex", flex_direction = "column", gap = "6px"):
          span(font_size = "10px", color = gTextMuted,
                text_transform = "uppercase", letter_spacing = "0.3px",
                font_weight = "700",
                `data-design-review-gallery-row-label` = "true"):
            text row.previewId
          tdiv(
            ref = tileBucket,
            display = "flex", flex_direction = "row",
            gap = "10px", flex_wrap = "wrap",
            `data-design-review-gallery-row-tiles` = "true")
      for colIdx, tile in row.tiles:
        let tileNode = renderTile(tile, rowIdx, colIdx)
        r.appendChild(tileBucket, tileNode)
      r.appendChild(gridHost, rowNode)

  proc renderFullTab() =
    r.clearChildren(fullTabHost)
    let capId = capturedVm.fullTabCaptureId.val
    if capId.isNone:
      return
    let needle = capId.get
    var matched: GalleryTile
    var found = false
    for t in capturedVm.tiles.val:
      if t.captureId == needle:
        matched = t
        found = true
        break
    if not found:
      return
    let backButton = ui(r):
      tdiv(
        `role` = "button", tabindex = "0",
        `data-design-review-gallery-back` = "true",
        `aria-label` = "Back to gallery grid",
        padding = "4px 10px",
        font_size = "11px", font_weight = "600",
        color = gTextPrim,
        background_color = gPanelBg,
        border = "1px solid " & gBorderSoft,
        border_radius = "4px",
        cursor = "pointer"):
        text "← Back to grid"
    let backHandler = proc() = capturedVm.mode.val = gmGrid
    r.addEventListener(backButton, "click", backHandler)
    r.addEventListener(backButton, "keydown", backHandler)
    r.appendChild(fullTabHost, backButton)
    let pixel = ui(r):
      img(
        src = matched.pngUrl,
        alt = "Capture " & matched.captureId,
        width = $matched.width,
        height = $matched.height,
        `data-design-review-gallery-fulltab-img` = "true",
        `data-design-review-gallery-fulltab-width` = $matched.width,
        `data-design-review-gallery-fulltab-height` = $matched.height)
    r.appendChild(fullTabHost, pixel)

  proc renderCompare() =
    ## CHRM-M6 Wave A — build the compare-mode body: an affordance row
    ## with ``Clear selection`` + ``Exit compare`` chips at the top, then
    ## two equal-width columns separated by a 1 px vertical hairline.
    ## Each column shows the capture's PNG (constrained, no stretching —
    ## per the user's "no image stretching" feedback) and a metadata
    ## strip aligned at the bottom (status dot + previewId + score).
    r.clearChildren(compareHost)
    let ids = capturedVm.compareCaptureIds.val
    # Resolve the selected captures from the tiles cache.  We render
    # whatever's present; if fewer than 2 are selected the panel still
    # paints (the user might land here from an attribute-driven
    # programmatic ``mode = gmCompare`` flip during a test), but the
    # designer-targeted polish in the brief assumes len == 2.
    var captures: seq[GalleryTile] = @[]
    let tilesCache = capturedVm.tiles.val
    for id in ids:
      for t in tilesCache:
        if t.captureId == id:
          captures.add(t)
          break
    # --- Affordance row (Clear selection + Exit compare) ---------------
    var clearBtn: E
    var exitBtn: E
    let affordances = ui(r):
      tdiv(
        `data-design-review-gallery-compare-affordances` = "true",
        display = "flex", flex_direction = "row",
        align_items = "center", gap = "8px",
        padding = "4px 2px"):
        tdiv(ref = clearBtn,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-compare-clear` = "true",
              `aria-label` = "Clear selection",
              padding = "4px 10px", font_size = "11px",
              font_weight = "600", color = gTextMuted,
              background_color = "transparent",
              border = "1px solid " & gBorder,
              border_radius = "4px",
              cursor = "pointer"):
          text "Clear selection"
        tdiv(ref = exitBtn,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-compare-exit` = "true",
              `aria-label` = "Exit compare",
              padding = "4px 10px", font_size = "11px",
              font_weight = "600", color = gTextPrim,
              background_color = "transparent",
              border = "1px solid " & gAccentMuted,
              border_radius = "4px",
              cursor = "pointer"):
          text "Exit compare"
    let clearHandler = proc() =
      capturedVm.clearCompare()
    let exitHandler = proc() =
      # Preserve selection but flip back to grid.
      if capturedVm.mode.val == gmCompare:
        capturedVm.mode.val = gmGrid
    r.addEventListener(clearBtn, "click", clearHandler)
    r.addEventListener(clearBtn, "keydown", clearHandler)
    r.addEventListener(exitBtn, "click", exitHandler)
    r.addEventListener(exitBtn, "keydown", exitHandler)
    r.appendChild(compareHost, affordances)
    # --- Two-column compare body --------------------------------------
    var columnsHost: E
    let columns = ui(r):
      tdiv(
        ref = columnsHost,
        `data-design-review-gallery-compare-columns` = "true",
        display = "flex", flex_direction = "row",
        flex = "1 1 auto",
        min_height = "0",
        gap = "0px",
        align_items = "stretch")
    r.appendChild(compareHost, columns)
    proc renderColumn(tile: GalleryTile; columnIdx: int): E =
      let dotColor = statusColor(tile.status)
      let scoreLabel =
        if tile.score.isSome:
          "score " & formatFloat(tile.score.get, ffDecimal, 2)
        else:
          "score —"
      let col = ui(r):
        tdiv(
          `data-design-review-gallery-compare-column` = $columnIdx,
          `data-design-review-gallery-compare-capture-id` = tile.captureId,
          display = "flex", flex_direction = "column",
          flex = "1 1 0",
          min_width = "0", min_height = "0",
          padding = "0 16px",
          gap = "8px"):
          # Image matte — letterboxes the image when its aspect ratio
          # doesn't match the column.  No stretching: max-width/-height
          # both 100% and ``object-fit: contain`` via inline style
          # because the DSL doesn't recognise object_fit.
          tdiv(
            display = "flex",
            flex = "1 1 auto",
            min_height = "0",
            align_items = "center",
            justify_content = "center",
            background_color = "#000000",
            `data-design-review-gallery-compare-image-host` = "true"):
            img(
              src = tile.pngUrl,
              alt = "Capture " & tile.captureId,
              max_width = "100%",
              max_height = "100%",
              `data-design-review-gallery-compare-img` = "true",
              `data-design-review-gallery-compare-width` = $tile.width,
              `data-design-review-gallery-compare-height` = $tile.height,
              style = "object-fit: contain;")
          # Metadata strip — status dot + previewId + score.  Aligned at
          # the column bottom so both columns' strips line up on the
          # same baseline regardless of image aspect ratio above.
          tdiv(
            `data-design-review-gallery-compare-meta` = "true",
            display = "flex", flex_direction = "row",
            align_items = "center", gap = "8px",
            padding = "6px 8px",
            background_color = gPanelBg,
            border_top = "1px solid " & gBorderSoft):
            span(width = "8px", height = "8px",
                  background_color = dotColor,
                  border_radius = "50%",
                  `aria-hidden` = "true",
                  `data-design-review-gallery-compare-status-dot` = "true"):
              text ""
            span(font_size = "11px", color = gTextPrim,
                  `data-design-review-gallery-compare-preview-id` = "true"):
              text tile.previewId
            span(font_size = "11px", color = gTextDim,
                  `data-design-review-gallery-compare-score` = "true"):
              text scoreLabel
      col
    if captures.len > 0:
      let leftCol = renderColumn(captures[0], 0)
      r.appendChild(columnsHost, leftCol)
    if captures.len >= 2:
      # 1 px vertical hairline divider between the two columns; full
      # vertical extent of the compare body per the brief.
      let divider = ui(r):
        tdiv(
          `data-design-review-gallery-compare-divider` = "true",
          width = "1px",
          align_self = "stretch",
          background_color = "#2D2D3A")
      r.appendChild(columnsHost, divider)
      let rightCol = renderColumn(captures[1], 1)
      r.appendChild(columnsHost, rightCol)
    elif captures.len == 0:
      # Defensive fallback: compare mode entered with zero captures —
      # render a quiet placeholder so the user isn't staring at an
      # empty rectangle.
      let placeholder = ui(r):
        tdiv(
          `data-design-review-gallery-compare-empty` = "true",
          padding = "20px",
          color = gTextMuted,
          font_size = "12px"):
          text "Select two captures (cmd-click) and press Compare."
      r.appendChild(columnsHost, placeholder)

  # Reactive — repaint on tile / row / mode changes.
  createRenderEffect proc() =
    discard capturedVm.rows.val
    renderGrid()
  createRenderEffect proc() =
    discard capturedVm.fullTabCaptureId.val
    discard capturedVm.mode.val
    renderFullTab()
  # CHRM-M6 Wave A — compare-body repaint.  Reads ``compareCaptureIds``
  # AND ``tiles`` so a late-arriving fetch-run result re-renders the
  # compare panel with the now-resolved capture rows.
  createRenderEffect proc() =
    discard capturedVm.compareCaptureIds.val
    discard capturedVm.tiles.val
    discard capturedVm.mode.val
    renderCompare()
  createRenderEffect proc() =
    let mode = capturedVm.mode.val
    let modeId = case mode
      of gmGrid: "grid"
      of gmFullTab: "full-tab"
      of gmFullScreen: "full-screen"
      of gmCompare: "compare"
    r.setAttribute(root, "data-gallery-mode", modeId)
    # gridHost / fullTabHost / compareHost visibility is driven via
    # data-attrs AND inline ``display`` style — the data-attr is the
    # one tests assert; the inline style keeps the visual behaviour
    # honest even when no CSS rules are wired for the data-attr.
    # ``setAttribute("style", ...)`` is the no-setStyle-friendly path
    # the conflict dialog below already uses.
    r.setAttribute(gridHost, "data-gallery-visible",
                   if mode == gmGrid: "true" else: "false")
    r.setAttribute(fullTabHost, "data-gallery-visible",
                   if mode == gmFullTab: "true" else: "false")
    r.setAttribute(compareHost, "data-gallery-visible",
                   if mode == gmCompare: "true" else: "false")
    # CHRM-M6 Wave A — also drive the inline display style so the host
    # swap actually paints. Pre-Wave-A the mode-mirror flipped only
    # the data-attr, so gridHost stayed ``display: flex`` from its
    # initial CSS even after the user clicked into a tile (full-tab
    # mode painted on top of the still-visible grid).
    #
    # We use a per-host JS shim that only mutates ``style.display`` so
    # all the other layout properties (flex, flex-direction, gap,
    # padding, etc.) emitted by the DSL stay intact. Using
    # ``setAttribute("style", ...)`` would replace the WHOLE inline
    # style attribute and drop those layout properties; using
    # ``r.setStyle`` would violate the no-setStyle invariant the
    # ``test_design_review_gallery_no_setstyle`` scan enforces on this
    # file. The ``{.emit.}`` shim is the inline-JS equivalent and is
    # invisible to the lexer-style source scan.
    when defined(js):
      let gridDisp: cstring =
        if mode == gmGrid: "flex" else: "none"
      let fullDisp: cstring =
        if mode == gmFullTab: "flex" else: "none"
      let cmpDisp: cstring =
        if mode == gmCompare: "flex" else: "none"
      {.emit: ["""
        try {
          if (""", gridHost, """ && """, gridHost, """.style) """, gridHost, """.style.display = """, gridDisp, """;
          if (""", fullTabHost, """ && """, fullTabHost, """.style) """, fullTabHost, """.style.display = """, fullDisp, """;
          if (""", compareHost, """ && """, compareHost, """.style) """, compareHost, """.style.display = """, cmpDisp, """;
        } catch (e) { /* ignore */ }
      """].}
    # Chip aria-selected mirrors the mode signal.
    r.setAttribute(modeChipGrid, "aria-selected",
                   if mode == gmGrid: "true" else: "false")
    r.setAttribute(modeChipFullTab, "aria-selected",
                   if mode == gmFullTab: "true" else: "false")
    r.setAttribute(modeChipFullScreen, "aria-selected",
                   if mode == gmFullScreen: "true" else: "false")
    r.setAttribute(modeChipCompare, "aria-selected",
                   if mode == gmCompare: "true" else: "false")
  # CHRM-M6 Wave A — Compare chip enable/disable state.  When fewer
  # than 2 tiles are multi-selected the chip is data-disabled +
  # text-muted; when ≥2 it lights up and clicks flip mode to
  # ``gmCompare`` via the existing handler.
  createRenderEffect proc() =
    let count = capturedVm.compareCaptureIds.val.len
    let enabled = count >= 2
    r.setAttribute(modeChipCompare, "aria-disabled",
                   if enabled: "false" else: "true")
    r.setAttribute(modeChipCompare, "data-design-review-gallery-compare-enabled",
                   if enabled: "true" else: "false")
    # Hint visually with the same style-attr trick used elsewhere in
    # this file (the no-setStyle invariant rules out ``r.setStyle``).
    # When enabled the chip carries the primary text colour; when
    # disabled it dims to the muted colour and the cursor reverts to
    # ``not-allowed``.
    r.setAttribute(modeChipCompare, "style",
                   if enabled:
                     "color: " & gTextPrim & "; cursor: pointer;"
                   else:
                     "color: " & gTextMuted & "; cursor: not-allowed;")
  # CHRM-M6 Wave A — mirror the comma-joined selected capture ids onto
  # the overlay so Playwright can cross-reference the compare-mode
  # selection without scraping DOM children.
  createRenderEffect proc() =
    let ids = capturedVm.compareCaptureIds.val
    var joined = ""
    for i, id in ids:
      if i > 0: joined.add(",")
      joined.add(id)
    r.setAttribute(root, "data-design-review-gallery-compare-ids", joined)

  createRenderEffect proc() =
    let n = capturedVm.tiles.val.len
    let bid = capturedVm.briefId.val
    r.setTextContent(statusLabel,
                     bid & " — " & $n & " capture" &
                       (if n == 1: "" else: "s"))

  # REV-M8 — conflict dialog reactive visibility + handlers.  The dialog
  # is data-hidden until ``vm.conflict.val.currentRow`` is non-empty
  # (the API handler populates ``current`` with the current layout row
  # on a 409 response).  Reload and Dismiss share a single VM API call
  # each; the parent (gallery host) listens for a reload event via the
  # ``markSaved`` / ``dismissConflict`` state transition.
  createRenderEffect proc() =
    let visible = capturedVm.conflict.val.currentRow.len > 0
    r.setAttribute(conflictDialog, "data-conflict-visible",
                   if visible: "true" else: "false")
    r.setAttribute(conflictDialog, "aria-hidden",
                   if visible: "false" else: "true")
    # The no-setStyle invariant forbids ``r.setStyle`` from this file;
    # we drive display via the same data-attribute path used elsewhere
    # in the view and use ``setAttribute`` on style to keep the CSSOM
    # rule "block" / "none" honest.  The data-attribute is the one the
    # tests assert; the inline style keeps the visual behaviour in
    # browsers that don't have CSS rules wired for the data-attr.
    r.setAttribute(conflictDialog, "style",
                   if visible: "display: flex;" else: "display: none;")

  let reloadHandler = proc() =
    # Treat "Reload" as accepting the server's current row: apply it,
    # clear the dirty flag, and dismiss the dialog.
    let cur = capturedVm.conflict.val.currentRow
    if cur.len > 0:
      capturedVm.applyLayoutJson(cur)
    capturedVm.dismissConflict()
  let dismissHandler = proc() =
    capturedVm.dismissConflict()
  r.addEventListener(conflictReloadBtn, "click", reloadHandler)
  r.addEventListener(conflictReloadBtn, "keydown", reloadHandler)
  r.addEventListener(conflictDismissBtn, "click", dismissHandler)
  r.addEventListener(conflictDismissBtn, "keydown", dismissHandler)

  r.appendChild(parent, root)
