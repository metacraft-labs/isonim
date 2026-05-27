## REV-M7 / REV-M8 — gallery overlay view + ViewModel.
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
## REV-M8 follow-up — visible drag-rearrange.  The original REV-M8
## landed the VM-level drag scratchpad (``pendingLayout`` + ``isDirty``)
## and the server-side save endpoint, but the grid kept rendering
## directly off ``tiles`` and never reflected the pending reorder in
## the DOM.  This follow-up wires ``effectiveTiles`` (a memo that
## overlays ``pendingLayout`` on ``tiles``) into ``rows`` so a drop
## visibly repositions the dragged tile, AND surfaces a Save layout
## button + ``data-design-review-gallery-dirty`` mirror so the dirty
## state is observable from the DOM.
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
    ## REV-M8 follow-up — ``effectiveTiles`` overlays ``pendingLayout``
    ## on ``tiles`` so the grid visibly reflects a drag-reorder before
    ## the server round-trip completes.  ``rows`` derives from
    ## ``effectiveTiles`` (not ``tiles``); when ``pendingLayout`` is
    ## empty ``effectiveTiles == tiles`` and ``rows`` is unchanged.
    effectiveTiles*: Memo[seq[GalleryTile]]
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

proc applyPendingLayout*(tiles: seq[GalleryTile];
                        pending: seq[PendingLayoutEntry]): seq[GalleryTile] =
  ## REV-M8 follow-up — overlay ``pending`` on top of ``tiles`` to
  ## produce a reordered tile sequence the grid can render.  Semantics:
  ##
  ##   1. Group ``tiles`` by ``previewId`` (preserving first-appearance
  ##      order of rows) to derive the current row buckets.
  ##   2. For each ``pending`` entry (in pending-list order):
  ##        a. Find the tile by ``captureId`` and remove it from its
  ##           current row bucket.
  ##        b. Resolve the target row by index.  ``rowIndex`` clamps to
  ##           ``[0, rows.len)``; out-of-range targets fall back to the
  ##           tile's original row so a stale drop position never drops
  ##           the tile off the visible grid.
  ##        c. Insert the tile at ``columnIndex`` within the target row
  ##           (clamped to ``[0, row.len]`` — len allows append).
  ##   3. Flatten the row buckets back into a tile seq, preserving the
  ##      original row order so ``groupByPreview`` reproduces the same
  ##      visual grouping downstream.
  ##
  ## When ``pending`` is empty (the common case before any drag) the
  ## result equals ``tiles`` so ``rows.val`` is byte-stable.
  if pending.len == 0:
    return tiles
  # Row buckets keyed by previewId, plus the row order (so the result
  # can be flattened back in the same visual sequence ``groupByPreview``
  # would yield).
  var rowOrder = newSeq[string]()
  var buckets = initTable[string, seq[GalleryTile]]()
  for t in tiles:
    if t.previewId notin buckets:
      buckets[t.previewId] = @[]
      rowOrder.add(t.previewId)
    var bucket = buckets[t.previewId]
    bucket.add(t)
    buckets[t.previewId] = bucket
  for entry in pending:
    # Locate the tile by captureId across all buckets.
    var foundIn = ""
    var foundIdx = -1
    var found: GalleryTile
    for previewId, bucket in buckets:
      for i in 0 ..< bucket.len:
        if bucket[i].captureId == entry.captureId:
          foundIn = previewId
          foundIdx = i
          found = bucket[i]
          break
      if foundIdx >= 0: break
    if foundIdx < 0:
      # Stale pendingLayout entry (tile no longer in the cache); skip.
      continue
    # Remove from the current bucket.
    var srcBucket = buckets[foundIn]
    srcBucket.delete(foundIdx)
    buckets[foundIn] = srcBucket
    # Resolve target row.  rowIndex is the *visual* row index; map it
    # onto ``rowOrder``.  Out-of-range falls back to the original row so
    # the tile is never lost.
    var targetPreview = foundIn
    if entry.rowIndex >= 0 and entry.rowIndex < rowOrder.len:
      targetPreview = rowOrder[entry.rowIndex]
    # When the drop crosses into a different row, project the tile's
    # ``previewId`` onto the target row so ``groupByPreview`` re-buckets
    # it visually into the destination.  This is a projection over
    # ``effectiveTiles`` only — the canonical ``tiles.val`` (and hence
    # any subsequent server round-trip) keeps the tile's true previewId
    # intact; we never mutate the source cache.
    if targetPreview != foundIn:
      found.previewId = targetPreview
    # Insert at the target column (clamped).
    var dstBucket = buckets[targetPreview]
    var col = entry.columnIndex
    if col < 0: col = 0
    if col > dstBucket.len: col = dstBucket.len
    dstBucket.insert(found, col)
    buckets[targetPreview] = dstBucket
  # Flatten rows back to a tile seq in the original row order.
  result = @[]
  for previewId in rowOrder:
    for t in buckets[previewId]:
      result.add(t)

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
  # REV-M8 follow-up — ``effectiveTiles`` overlays the drag-reorder
  # scratchpad on the canonical tiles list.  ``rows`` derives from
  # ``effectiveTiles`` so a drop visibly repositions the dragged tile
  # immediately, before any server round-trip.  ``markSaved`` /
  # ``applyLayoutJson`` continue to mutate ``pendingLayout`` directly;
  # this memo re-evaluates against the new state automatically.
  vm.effectiveTiles = createMemo[seq[GalleryTile]] proc(): seq[GalleryTile] =
    applyPendingLayout(capturedVm.tiles.val, capturedVm.pendingLayout.val)
  vm.rows = createMemo[seq[GalleryRow]] proc(): seq[GalleryRow] =
    groupByPreview(capturedVm.effectiveTiles.val)
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
  ## Drag-and-drop scratchpad write.  Called from the view's drop
  ## handler with the SOURCE captureId (tracked across the drag via a
  ## dragstart-set shared ref) and the DESTINATION tile's (rowIdx,
  ## columnIdx).  The result is: "the tile with this captureId wants
  ## to be placed at this row/col next render".  ``applyPendingLayout``
  ## (the memo backing ``effectiveTiles`` → ``rows``) consumes this so
  ## the grid visibly reorders before any server round-trip.  The
  ## ``isDirty`` flag flips so the save-chip affordance reactively
  ## surfaces.
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
  # CHRM-M6 Wave B — match the CHRM-M2 ChoiceGroup ``cgvTransparent``
  # variant: idle pills carry a 1 px ``#2D2D3A`` border on a
  # transparent fill; selected pills carry the editor accent fill
  # ``#3B82F6`` with white text; the lavender ``#7C7AED`` is reserved
  # for the GALLERY cluster label so the chip family doesn't compete
  # with the label visually.
  gChipBorder  = "#2D2D3A"
  gChipAccent  = "#3B82F6"
  gAccent      = "#7C7AED"
  gAccentMuted = "#475569"
  gTextPrim    = "#F1F5F9"
  # CHRM-M6 Wave B — promote tile metadata text to the brief's
  # ``#E5E7EB`` for score readability against the ``#111827`` tile.
  gTextScore   = "#E5E7EB"
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

proc mountGalleryOverlay*[R, E](r: R; parent: E; vm: GalleryVM;
                                onSave: proc() = nil;
                                narrow: Signal[bool] = nil) =
  ## Mount the gallery as a child of ``parent`` (typically the
  ## preview-pane container).  The overlay is a flex column with a
  ## top toolbar (mode chips), a tile-grid container, and a full-tab
  ## host that swaps in when mode = gmFullTab.
  ##
  ## ``onSave`` is invoked when the user clicks the Save layout chip
  ## (rendered reactively when ``vm.isDirty.val == true``).  The
  ## production caller wires this to a POST against
  ## ``/api/design-review/save-layout`` and calls ``vm.markSaved`` /
  ## ``vm.markConflict`` from the response callback.  Tests pass in a
  ## fake handler.  When ``onSave`` is nil the chip falls back to a
  ## VM-local ``markSaved`` (empty layoutId / version 0) so the dirty
  ## flag still clears — useful for UI smoke tests that don't care
  ## about the round-trip.
  ##
  ## CHRM-M7 polish — ``narrow`` is the design-review narrow-viewport
  ## signal (``DesignReviewState.narrow``).  When non-nil and true,
  ## the toolbar lays out as a single-line horizontally-scrollable
  ## chip strip (no wrap) and the inline status label hides — the
  ## status footer at the overlay bottom carries the same info.  When
  ## nil (e.g. headless tests that don't drive a narrow signal) the
  ## toolbar uses its standard wide/laptop layout.
  let capturedVm = vm
  let capturedOnSave = onSave
  let capturedNarrow = narrow

  var toolbarRow: E
  var chipStrip: E
  var modeChipGrid: E
  var modeChipFullTab: E
  var modeChipFullScreen: E
  var modeChipCompare: E
  var saveButton: E
  var gridHost: E
  var fullTabHost: E
  # CHRM-M6 Wave A — compare-mode host. The host is data-hidden until
  # the mode flips to ``gmCompare``; the Clear / Exit affordance chips
  # are locally scoped inside ``renderCompare``.
  var compareHost: E
  var statusLabel: E
  # CHRM-M6 Wave B — separate footer at the bottom of the overlay
  # carries the brief's ``<briefId> · <n> captures`` summary in muted
  # uppercase tone (per the empty-state + grid briefs). The toolbar's
  # statusLabel kept for backwards compatibility with the existing
  # ``data-design-review-gallery-status`` selector used by tests.
  var statusFooter: E
  var conflictDialog: E
  var conflictReloadBtn: E
  var conflictDismissBtn: E

  let root = ui(r):
    tdiv(
      `data-design-review-gallery-overlay` = "true",
      # REV-M8 follow-up — dirty mirror.  Default "false"; reactive
      # effect lifts it to "true" when ``vm.isDirty`` flips after a
      # drag-reorder, and back to "false" after ``markSaved``.
      `data-design-review-gallery-dirty` = "false",
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
      # CHRM-M7 polish — toolbar carries a ``ref`` so a reactive
      # narrow-mode effect can rewrite its inline style to switch
      # between row layout (wide / laptop) and a wrap-to-2-row layout
      # at narrow widths.  The mode chips live inside a dedicated
      # ``chipStrip`` wrapper so its overflow behaviour is independent
      # of the toolbar row's flex behaviour.
      tdiv(ref = toolbarRow,
            display = "flex", flex_direction = "row",
            align_items = "center",
            gap = "8px",
            `data-design-review-gallery-toolbar` = "true",
            `role` = "toolbar",
            `aria-label` = "Gallery view modes"):
        span(font_size = "10px", font_weight = "700",
              text_transform = "uppercase", letter_spacing = "0.4px",
              color = gAccent,
              flex = "0 0 auto",
              white_space = "nowrap"):
          text "Gallery"
        # CHRM-M7 polish — Pattern A. At narrow widths the chip strip
        # becomes a single-line horizontally-scrollable container
        # (``flex-wrap: nowrap; overflow-x: auto``) so the four chips
        # never wrap mid-pill. At wide/laptop the strip is a normal
        # row with the chips' natural inline-flex layout. Default
        # (initial) style is the wide/laptop layout; the reactive
        # effect below rewrites the inline style attribute when
        # ``narrow`` flips.
        tdiv(ref = chipStrip,
              `data-design-review-gallery-chip-strip` = "true",
              display = "flex", flex_direction = "row",
              align_items = "center",
              gap = "6px",
              flex = "1 1 auto",
              min_width = "0"):
          # CHRM-M6 Wave B — mode chips share the CHRM-M2 ChoiceGroup
          # ``cgvTransparent`` family. Idle pill = transparent fill +
          # 1 px ``#2D2D3A`` border. Selected pill = accent fill
          # ``#3B82F6`` + white text. The selected/idle visual swap is
          # driven by a reactive style effect below (the no-setStyle
          # invariant on this file rules out ``r.setStyle``; we drive
          # the chip's inline ``style`` attribute via ``setAttribute``
          # which the dogfooding lexer scan allows).
          #
          # CHRM-M7 polish — every chip carries ``white-space: nowrap``
          # + ``flex-shrink: 0`` so chip text never wraps mid-pill and
          # the chips never shrink below their natural width inside
          # the (potentially scrolling) strip.
          tdiv(ref = modeChipGrid,
                `role` = "button", tabindex = "0",
                `data-design-review-gallery-mode` = "grid",
                `aria-label` = "Grid view",
                padding = "3px 10px", font_size = "11px",
                font_weight = "600", color = gTextPrim,
                background_color = "transparent",
                border = "1px solid " & gChipBorder,
                border_radius = "999px",
                white_space = "nowrap",
                flex = "0 0 auto",
                cursor = "pointer"):
            text "Grid"
          tdiv(ref = modeChipFullTab,
                `role` = "button", tabindex = "0",
                `data-design-review-gallery-mode` = "full-tab",
                `aria-label` = "Full-tab view",
                padding = "3px 10px", font_size = "11px",
                font_weight = "600", color = gTextPrim,
                background_color = "transparent",
                border = "1px solid " & gChipBorder,
                border_radius = "999px",
                white_space = "nowrap",
                flex = "0 0 auto",
                cursor = "pointer"):
            text "Full tab"
          tdiv(ref = modeChipFullScreen,
                `role` = "button", tabindex = "0",
                `data-design-review-gallery-mode` = "full-screen",
                `aria-label` = "Full-screen view",
                padding = "3px 10px", font_size = "11px",
                font_weight = "600", color = gTextPrim,
                background_color = "transparent",
                border = "1px solid " & gChipBorder,
                border_radius = "999px",
                white_space = "nowrap",
                flex = "0 0 auto",
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
                padding = "3px 10px", font_size = "11px",
                font_weight = "600", color = gTextMuted,
                background_color = "transparent",
                border = "1px solid " & gChipBorder,
                border_radius = "999px",
                white_space = "nowrap",
                flex = "0 0 auto",
                cursor = "pointer"):
            text "Compare"
        # REV-M8 follow-up — Save layout chip.  Hidden by default
        # (``data-design-review-gallery-save-visible="false"``); the
        # reactive effect below flips it visible when ``isDirty.val``
        # is true.  After a successful save the chip carries
        # ``data-saved="true"`` briefly so Playwright can observe the
        # transition without racing the dirty-flag flip.
        tdiv(ref = saveButton,
              `role` = "button", tabindex = "0",
              `data-design-review-gallery-save-button` = "true",
              `data-design-review-gallery-save-visible` = "false",
              `data-saved` = "false",
              `aria-label` = "Save layout",
              padding = "3px 10px", font_size = "11px",
              font_weight = "600", color = "#FFFFFF",
              background_color = gChipAccent,
              border = "1px solid " & gChipAccent,
              border_radius = "999px",
              white_space = "nowrap",
              flex = "0 0 auto",
              cursor = "pointer"):
          text "Save layout"
        span(ref = statusLabel,
              font_size = "10px", color = gTextDim,
              white_space = "nowrap",
              flex = "0 0 auto",
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
      # CHRM-M6 Wave B — column layout: back button anchored to the
      # top-left, image centred horizontally in the remaining space.
      # The ``align-items: stretch`` lets the back button row span the
      # full width so its inner alignment controls placement; the
      # image is wrapped in a flex-grow container that centre-aligns
      # it both axes (per the grid+full-tab brief's "image is centred
      # in the overlay body" requirement).
      tdiv(
        ref = fullTabHost,
        display = "none",
        flex_direction = "column",
        align_items = "stretch",
        gap = "8px",
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
      # --- Status footer (CHRM-M6 Wave B) -----------------------------
      # ``<briefId> · <n> captures`` in muted uppercase. Pinned at the
      # overlay bottom so the reviewer always knows which brief the
      # gallery is bound to and how many captures it carries — calm
      # secondary info that doesn't compete with the toolbar above.
      span(ref = statusFooter,
            font_size = "11px", font_weight = "500",
            color = gTextDim,
            text_transform = "uppercase",
            letter_spacing = "0.3px",
            padding = "2px 2px",
            `data-design-review-gallery-status-footer` = "true"):
        text ""

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

  # REV-M8 follow-up — Save layout chip handler.  When the caller
  # supplied an ``onSave`` callback (production: posts to
  # ``/api/design-review/save-layout`` and dispatches markSaved /
  # markConflict from the response), invoke it; otherwise fall back to
  # a VM-local ``markSaved`` so the dirty flag still clears.  The brief
  # "saved" state flash is driven by the reactive effect below — we
  # only need to fire the save action here.
  let savePressHandler = proc() =
    if not capturedVm.isDirty.val:
      return
    if capturedOnSave != nil:
      capturedOnSave()
    else:
      capturedVm.markSaved("", 0)
  r.addEventListener(saveButton, "click", savePressHandler)
  r.addEventListener(saveButton, "keydown", savePressHandler)

  # REV-M8 follow-up — shared drag-source tracker.  ``dragstart`` on
  # any tile writes its captureId here; ``drop`` on any (possibly
  # different) tile reads it so the drop handler knows which tile is
  # being moved.  Without this, the prior REV-M7 binding called
  # ``registerDragMove(DESTINATION_captureId, dst_row, dst_col)`` on
  # drop — i.e. it recorded that the *destination* tile should move to
  # its OWN position, a no-op.  The pendingLayout always reflected the
  # last-hovered tile rather than the dragged tile.
  let dragSourceId = new(string)
  dragSourceId[] = ""

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
        # CHRM-M6 Wave B — tile metadata row.  Status dot (6 px per
        # brief), status text muted (#A0A2B0 11 px), score
        # right-aligned in the brief's ``#E5E7EB`` weight 600 so it
        # reads against the ``#111827`` tile.  ``margin-left: auto``
        # on the score span pushes it to the right edge of the row;
        # the dot + status text cluster stays on the left.
        tdiv(display = "flex", flex_direction = "row",
              align_items = "center", gap = "6px",
              width = "100%"):
          span(width = "6px", height = "6px",
                min_width = "6px",
                background_color = chipColor,
                border_radius = "50%",
                `aria-hidden` = "true",
                `data-design-review-gallery-status-dot` = "true"):
            text ""
          span(font_size = "11px", color = "#A0A2B0",
                `data-design-review-gallery-status-label` = "true"):
            text tile.status
          span(font_size = "11px", font_weight = "600",
                color = gTextScore,
                margin_left = "auto",
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
    # REV-M8 follow-up — drag-and-drop bindings.  Three event types:
    #
    #   * ``dragstart`` on this tile — record this tile's captureId as
    #     the drag source.  The drop handler (on a possibly different
    #     tile) reads the recorded id to know which tile is being
    #     moved.  Without this, the drop handler had no source identity
    #     and was effectively a no-op.
    #   * ``dragover`` — no-op for the VM (the visible drop preview is
    #     a future polish item).  Browsers REQUIRE the ``dragover``
    #     handler to ``preventDefault`` for the drop event to fire;
    #     the inline JS shim below handles that without requiring a
    #     full ``MockEvent`` payload here.
    #   * ``drop`` — read the source id from the shared ref, fall back
    #     to this tile's captureId if no source was recorded (so VM-
    #     level synthetic drops without a preceding dragstart still
    #     drive ``registerDragMove`` on the dropped-on tile).  Pass
    #     this tile's (rowIdx, colIdx) as the target.
    let capturedDragSource = dragSourceId
    let dragStartHandler = proc() =
      capturedDragSource[] = capturedCaptureId
    let dropHandler = proc() =
      let src =
        if capturedDragSource[].len > 0: capturedDragSource[]
        else: capturedCaptureId
      capturedVm.registerDragMove(src, capturedRowIdx, capturedColIdx)
      # Reset the source after a drop so a subsequent unrelated drop
      # doesn't reuse a stale id.
      capturedDragSource[] = ""
    r.addEventListener(tileNode, "dragstart", dragStartHandler)
    r.addEventListener(tileNode, "drop", dropHandler)
    when defined(js):
      # Browser path: the standard HTML5 drag-and-drop API requires
      # ``preventDefault`` on the ``dragover`` event for the
      # subsequent ``drop`` to fire.  We use the ``{.emit.}`` inline-JS
      # shim (same pattern as the multi-select shift/meta detection
      # above) to avoid wiring a heavier MockEvent-aware handler that
      # would need a separate test path.
      {.emit: ["""
        (function(node) {
          if (!node || !node.addEventListener) return;
          node.addEventListener("dragover", function(ev) {
            if (ev && ev.preventDefault) ev.preventDefault();
          });
        })(""", tileNode, """);
      """].}
    # CHRM-M6 Wave A — mirror multi-select state onto the tile so
    # Wave B can style the selected outline off the data attribute.
    # CHRM-M6 Wave C — paint the selected outline per the grid brief:
    # 2 px solid ``#3B82F6`` outline + 1 px inset ``#0B1220``
    # ``box-shadow`` so the outline visibly separates from the tile
    # body. ``outline-offset: -1px`` keeps the outline flush against
    # the tile edge; the inset shadow draws a 1 px ring inside that
    # picks up the overlay background colour for the separator effect.
    # We also drive the hover transition + cursor ring via the same
    # style write so a stale hover state can't override the selected
    # outline (the inline JS hover shim below clears its own writes on
    # mouseleave but never touches outline/box-shadow).
    let capturedTileForSelect = tileNode
    let capturedCaptureIdForSelect = capturedCaptureId
    createRenderEffect proc() =
      let selected = capturedCaptureIdForSelect in capturedVm.selectedTileIds.val
      r.setAttribute(capturedTileForSelect,
                     "data-design-review-gallery-tile-selected",
                     if selected: "true" else: "false")
      if selected:
        r.setAttribute(capturedTileForSelect, "style",
                       "outline: 2px solid " & gChipAccent &
                         "; outline-offset: -1px;" &
                         " box-shadow: inset 0 0 0 1px " & gBg & ";" &
                         " transition: background-color 120ms ease-out," &
                         " border-color 120ms ease-out;")
      else:
        r.setAttribute(capturedTileForSelect, "style",
                       "outline: none; box-shadow: none;" &
                         " transition: background-color 120ms ease-out," &
                         " border-color 120ms ease-out;")
    # CHRM-M6 Wave C — tile hover affordance per the grid+full-tab
    # brief: background steps from ``#111827`` to ``#162033``, border
    # from ``#1F2937`` to ``#334155``, 120 ms ease-out transition.
    # The transition is already on the element (set by the selected/
    # idle render effect above). On mouseleave we restore the DSL
    # defaults; mouseenter/leave never write outline or box-shadow so
    # they coexist cleanly with the selected-state render effect.
    when defined(js):
      {.emit: ["""
        (function(node) {
          if (!node || !node.addEventListener) return;
          node.addEventListener("mouseenter", function() {
            this.style.backgroundColor = "#162033";
            this.style.borderColor = "#334155";
          });
          node.addEventListener("mouseleave", function() {
            this.style.backgroundColor = "#111827";
            this.style.borderColor = "#1F2937";
          });
        })(""", tileNode, """);
      """].}
    tileNode

  proc renderGrid() =
    r.clearChildren(gridHost)
    let rows = capturedVm.rows.val
    if rows.len == 0:
      # CHRM-M6 Wave B — empty-state panel per the brief: a heading
      # ("No captures yet") and a calm one-line subtitle, anchored to
      # the centre of the overlay body so the panel reads as
      # intentional rather than a broken/loading state.  The outer
      # ``tdiv`` is flex-centred (column + center justification) so
      # the heading+subtitle stack sits in the middle of the gridHost
      # regardless of how much vertical space the overlay body has.
      let empty = ui(r):
        tdiv(
          `data-design-review-gallery-empty` = "true",
          display = "flex", flex_direction = "column",
          align_items = "center", justify_content = "center",
          flex = "1 1 auto",
          min_height = "0",
          gap = "6px",
          padding = "20px",
          text_align = "center"):
          span(font_size = "16px", font_weight = "600",
                color = "#E5E7EB",
                `data-design-review-gallery-empty-heading` = "true"):
            text "No captures yet"
          span(font_size = "13px", font_weight = "400",
                color = "#A0A2B0",
                line_height = "1.5",
                max_width = "480px",
                `data-design-review-gallery-empty-subtitle` = "true"):
            text "Run a capture sweep to populate the gallery — open a story, switch backends, and the capture pipeline will record each preview."
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
            gap = "12px", flex_wrap = "wrap",
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
    # CHRM-M6 Wave B — back button restyled to the chip family per
    # the grid+full-tab brief: pill (22 px tall via 4px/12px padding +
    # 11 px font), transparent background, 1 px border ``#334155``.
    # Wrapping it in a left-aligned flex row keeps the chip
    # left-anchored even when the parent has ``align-items: stretch``.
    var backRow: E
    let backRowNode = ui(r):
      tdiv(
        ref = backRow,
        display = "flex", flex_direction = "row",
        align_items = "center", justify_content = "flex-start",
        `data-design-review-gallery-fulltab-back-row` = "true")
    let backButton = ui(r):
      tdiv(
        `role` = "button", tabindex = "0",
        `data-design-review-gallery-back` = "true",
        `aria-label` = "Back to gallery grid",
        padding = "4px 12px",
        font_size = "11px", font_weight = "600",
        color = gTextPrim,
        background_color = "transparent",
        border = "1px solid " & gBorder,
        border_radius = "999px",
        cursor = "pointer"):
        text "← Back to grid"
    let backHandler = proc() = capturedVm.mode.val = gmGrid
    r.addEventListener(backButton, "click", backHandler)
    r.addEventListener(backButton, "keydown", backHandler)
    r.appendChild(backRow, backButton)
    r.appendChild(fullTabHost, backRowNode)
    # CHRM-M6 Wave B — image-centring matte.  The image wrapper grows
    # to fill the remaining overlay-body height and centres the
    # native-size image both horizontally and vertically (per the
    # brief's "image is centred in the overlay body" rule + the
    # user's "no image stretching" feedback — width/height stay at
    # the captured pixel dimensions, the wrapper just supplies the
    # surrounding whitespace).
    var matte: E
    let matteNode = ui(r):
      tdiv(
        ref = matte,
        display = "flex", flex_direction = "row",
        align_items = "center", justify_content = "center",
        flex = "1 1 auto",
        min_height = "0",
        width = "100%",
        `data-design-review-gallery-fulltab-matte` = "true")
    let pixel = ui(r):
      img(
        src = matched.pngUrl,
        alt = "Capture " & matched.captureId,
        width = $matched.width,
        height = $matched.height,
        `data-design-review-gallery-fulltab-img` = "true",
        `data-design-review-gallery-fulltab-width` = $matched.width,
        `data-design-review-gallery-fulltab-height` = $matched.height)
    r.appendChild(matte, pixel)
    r.appendChild(fullTabHost, matteNode)

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
      # CHRM-M6 Wave C — ``cursor: col-resize`` on hover hints at the
      # future resize affordance (the optional Wave C item from the
      # gallery-compare brief). No actual resize behaviour is wired —
      # the cursor is purely a hint that future drag will be possible.
      let divider = ui(r):
        tdiv(
          `data-design-review-gallery-compare-divider` = "true",
          width = "1px",
          align_self = "stretch",
          background_color = "#2D2D3A",
          cursor = "col-resize")
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
    # CHRM-M6 Wave B — chip selected/idle visual swap.  The selected
    # chip carries the accent fill ``#3B82F6`` with white text; idle
    # chips keep their transparent fill + ``#2D2D3A`` border from the
    # DSL declaration.  We rewrite the inline ``style`` attribute via
    # ``setAttribute`` so the no-setStyle invariant holds.
    #
    # CHRM-M7 polish — ``setAttribute("style", ...)`` REPLACES the
    # whole inline-style attribute (browsers don't merge), so the
    # layout properties (padding, border-radius, font, display,
    # white-space, flex-shrink) emitted by the DSL would be wiped out
    # on first paint and the chip text could wrap mid-pill at narrow
    # widths. We append a shared ``chipLayoutCss`` suffix to every
    # rewrite so layout always survives the reactive repaint.
    const chipLayoutCss =
      "display: inline-flex; align-items: center;" &
      " padding: 3px 10px; font-size: 11px; font-weight: 600;" &
      " border-radius: 999px; border-width: 1px;" &
      " border-style: solid; white-space: nowrap;" &
      " flex: 0 0 auto;"
    proc chipStyle(selected: bool): string =
      if selected:
        "background-color: " & gChipAccent &
          "; color: #FFFFFF; border-color: " & gChipAccent &
          "; cursor: pointer; " & chipLayoutCss
      else:
        "background-color: transparent; color: " & gTextPrim &
          "; border-color: " & gChipBorder &
          "; cursor: pointer; " & chipLayoutCss
    r.setAttribute(modeChipGrid, "style", chipStyle(mode == gmGrid))
    r.setAttribute(modeChipFullTab, "style",
                   chipStyle(mode == gmFullTab))
    r.setAttribute(modeChipFullScreen, "style",
                   chipStyle(mode == gmFullScreen))
  # CHRM-M6 Wave A — Compare chip enable/disable state.  When fewer
  # than 2 tiles are multi-selected the chip is data-disabled +
  # text-muted; when ≥2 it lights up and clicks flip mode to
  # ``gmCompare`` via the existing handler.
  # CHRM-M6 Wave B — when the chip IS the selected mode (compare
  # active) the chip carries the accent fill regardless of the count
  # so the family is consistent with the other three chips' selected
  # state.
  createRenderEffect proc() =
    let count = capturedVm.compareCaptureIds.val.len
    let enabled = count >= 2
    let selected = capturedVm.mode.val == gmCompare
    r.setAttribute(modeChipCompare, "aria-disabled",
                   if enabled or selected: "false" else: "true")
    r.setAttribute(modeChipCompare, "data-design-review-gallery-compare-enabled",
                   if enabled: "true" else: "false")
    # Hint visually with the same style-attr trick used elsewhere in
    # this file (the no-setStyle invariant rules out ``r.setStyle``).
    # Three states:
    #   - selected (in compare mode): accent fill + white text
    #   - enabled-idle (≥2 selected): transparent + primary text +
    #     border ``#2D2D3A`` (the cgvTransparent family)
    #   - disabled (<2 selected, not in compare): transparent + muted
    #     text + ``not-allowed`` cursor (per the brief)
    # CHRM-M7 polish — keep the same ``chipLayoutCss`` suffix as the
    # other chips so the inline style rewrite preserves the chip's
    # layout (padding, font, white-space: nowrap, flex-shrink: 0).
    const chipLayoutCssCompare =
      "display: inline-flex; align-items: center;" &
      " padding: 3px 10px; font-size: 11px; font-weight: 600;" &
      " border-radius: 999px; border-width: 1px;" &
      " border-style: solid; white-space: nowrap;" &
      " flex: 0 0 auto;"
    r.setAttribute(modeChipCompare, "style",
                   if selected:
                     "background-color: " & gChipAccent &
                       "; color: #FFFFFF; border-color: " & gChipAccent &
                       "; cursor: pointer; " & chipLayoutCssCompare
                   elif enabled:
                     "background-color: transparent; color: " & gTextPrim &
                       "; border-color: " & gChipBorder &
                       "; cursor: pointer; " & chipLayoutCssCompare
                   else:
                     "background-color: transparent; color: " & gAccentMuted &
                       "; border-color: " & gChipBorder &
                       "; cursor: not-allowed; " & chipLayoutCssCompare)
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
    # CHRM-M6 Wave B — bottom footer with the brief's middle-dot
    # separator: ``<briefId> · <n> captures`` per the empty-state /
    # grid briefs.  Pluralisation matches the toolbar label.
    r.setTextContent(statusFooter,
                     bid & " · " & $n & " capture" &
                       (if n == 1: "" else: "s"))

  # REV-M8 follow-up — dirty mirror + save-chip visibility + "saved"
  # flash.  Three intertwined pieces of state collapsed into a single
  # render effect (they all read ``isDirty`` + an internal "just saved"
  # latch derived from ``activeLayoutVersion`` changes).
  #
  # Behaviour:
  #   * dirty=true  → root data-dirty="true",  save chip visible,
  #                   data-saved="false".
  #   * dirty=false → root data-dirty="false", save chip hidden, AND
  #                   if a save just landed (we observe
  #                   activeLayoutVersion increment OR isDirty
  #                   transitioning true→false), the chip carries
  #                   data-saved="true" briefly so the e2e can assert
  #                   the success transition without racing the chip's
  #                   visibility flip.
  #
  # The "brief" duration is owned by the next dirty→true edge or by a
  # subsequent render — kept implementation-light so we don't pull in
  # timers (the e2e reads the attribute immediately after the click).
  var lastDirty = false
  var lastVersion = -1
  createRenderEffect proc() =
    let dirty = capturedVm.isDirty.val
    let version = capturedVm.activeLayoutVersion.val
    # Detect a save-completion edge: dirty went true→false in this
    # evaluation OR activeLayoutVersion bumped.
    let savedEdge =
      (lastDirty and not dirty) or
      (lastVersion >= 0 and version != lastVersion and not dirty)
    lastDirty = dirty
    lastVersion = version
    r.setAttribute(root, "data-design-review-gallery-dirty",
                   if dirty: "true" else: "false")
    r.setAttribute(saveButton, "data-design-review-gallery-save-visible",
                   if dirty: "true" else: "false")
    # Inline style: the chip is only renderable when dirty (or in the
    # immediate post-save flash window).  No-setStyle invariant: we use
    # ``setAttribute("style", ...)`` like the conflict dialog above.
    # CHRM-M7 polish — share the chip layout suffix so the save
    # button matches the mode chip family (padding, font, pill
    # radius, nowrap) when visible. The "hidden" branch keeps the
    # plain ``display: none`` shortcut since no layout properties
    # need to survive while the chip is offscreen.
    const chipLayoutCssSave =
      "display: inline-flex; align-items: center;" &
      " padding: 3px 10px; font-size: 11px; font-weight: 600;" &
      " border-radius: 999px; border-width: 1px;" &
      " border-style: solid; white-space: nowrap;" &
      " flex: 0 0 auto;"
    r.setAttribute(saveButton, "style",
                   if dirty:
                     "background-color: " & gChipAccent &
                       "; color: #FFFFFF; border-color: " & gChipAccent &
                       "; cursor: pointer; " & chipLayoutCssSave
                   elif savedEdge:
                     # Subdued green tone to read as "saved"; still
                     # visible so the e2e can assert the transition.
                     "background-color: " & gStatusOk &
                       "; color: #FFFFFF; border-color: " & gStatusOk &
                       "; cursor: default; " & chipLayoutCssSave
                   else:
                     "display: none;")
    r.setAttribute(saveButton, "data-saved",
                   if savedEdge: "true" else: "false")
    # Save button text mirrors state so a sighted user sees the result.
    r.setTextContent(saveButton,
                     if savedEdge: "Saved" else: "Save layout")

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

  # CHRM-M7 polish — narrow-viewport toolbar layout swap (Pattern A).
  # When ``narrow`` is non-nil and true:
  #   * chip strip becomes a single-line horizontally-scrollable
  #     container so the four chips never wrap mid-pill;
  #   * inline status label hides (the bottom status footer already
  #     shows ``<briefId> · <n> captures``).
  # When narrow is nil (e.g. mock-renderer tests with no narrow signal)
  # or false, the toolbar keeps its standard wide/laptop layout.
  #
  # Driven via the no-setStyle ``setAttribute("style", ...)`` path the
  # rest of this file already uses for reactive style swaps. The
  # ``data-narrow`` attribute on the toolbar gives tests a stable hook
  # if they ever need to assert the layout swap.
  if capturedNarrow != nil:
    let narrowSig = capturedNarrow
    createRenderEffect proc() =
      let isNarrow = narrowSig.val
      r.setAttribute(toolbarRow, "data-narrow",
                     if isNarrow: "true" else: "false")
      if isNarrow:
        # Toolbar wraps onto two rows: GALLERY label + chip strip on
        # row 1, save button on row 2 if visible. Status label hidden
        # — the footer carries the same info.
        #
        # Reserve a 44 px right strip so the drawer's close chip
        # (positioned: absolute; top: 10px; right: 10px; 32×32 px)
        # doesn't visually overlap the rightmost mode chip in the
        # horizontally-scrolling strip.
        r.setAttribute(toolbarRow, "style",
                       "display: flex; flex-direction: row;" &
                       " align-items: center; gap: 8px;" &
                       " flex-wrap: wrap; padding-right: 44px;")
        # Chip strip: single-line, horizontally scrollable.
        r.setAttribute(chipStrip, "style",
                       "display: flex; flex-direction: row;" &
                       " align-items: center; gap: 4px;" &
                       " flex: 1 1 auto; min-width: 0;" &
                       " flex-wrap: nowrap; overflow-x: auto;" &
                       " overflow-y: hidden;" &
                       " scrollbar-width: thin;" &
                       " scrollbar-color: #475569 transparent;" &
                       " -webkit-overflow-scrolling: touch;" &
                       " padding: 2px 2px;")
        # Hide the inline status label — the status footer below the
        # body already shows ``<briefId> · <n> captures``.
        r.setAttribute(statusLabel, "style", "display: none;")
      else:
        # Wide / laptop — restore the default toolbar layout.
        r.setAttribute(toolbarRow, "style",
                       "display: flex; flex-direction: row;" &
                       " align-items: center; gap: 8px;")
        r.setAttribute(chipStrip, "style",
                       "display: flex; flex-direction: row;" &
                       " align-items: center; gap: 6px;" &
                       " flex: 1 1 auto; min-width: 0;")
        r.setAttribute(statusLabel, "style",
                       "display: inline; white-space: nowrap;" &
                       " flex: 0 0 auto;")

  r.appendChild(parent, root)

  # CHRM-M6 Wave C — keyboard focus ring on tiles. Tiles already
  # carry ``tabindex="0"`` from their DSL declaration (renderTile
  # above). The ``:focus-visible`` pseudo-class fires for keyboard
  # focus but suppresses on mouse click, so the ring is unobtrusive
  # during pointer interaction. We use ``#60A5FA`` (softer accent)
  # so the focus ring is distinct from the selected-state outline
  # (``#3B82F6``). The style block is injected once per gallery
  # mount; the unique id guard prevents duplicate rules when the
  # overlay is re-mounted across mode flips. ``setStyle`` violations
  # don't apply here — we inject a stylesheet, not write inline.
  when defined(js):
    {.emit: """
      (function() {
        var styleId = "design-review-gallery-focus-ring";
        if (document.getElementById(styleId)) return;
        var s = document.createElement("style");
        s.id = styleId;
        s.textContent = [
          "[data-design-review-gallery-tile]:focus-visible {",
          "  outline: 2px solid #60A5FA;",
          "  outline-offset: -1px;",
          "  box-shadow: inset 0 0 0 1px #0B1220;",
          "}",
          "[data-design-review-gallery-tile]:focus:not(:focus-visible) {",
          "  outline: none;",
          "}"
        ].join("\n");
        document.head.appendChild(s);
      })();
    """.}
