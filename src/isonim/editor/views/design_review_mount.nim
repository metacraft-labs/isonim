## REV-M8 — production mount glue for the design-review gallery.
##
## REV-M7 shipped the components (``preview_chrome.mountHistoryButton``,
## ``gallery_overlay.mountGalleryOverlay``) and their ViewModels.
## REV-M8 wires them into the real editor shell.  The mount logic lives
## in its own module (rather than as more state on ``EditorVM``) so the
## main view-model file stays unchanged for callers who don't care
## about review state.
##
## What lives here:
##
##   * Per-``EditorVM`` cache of ``HistoryButtonVM`` + ``GalleryVM`` +
##     ``briefHasHistory`` signal, keyed by VM ref identity.
##   * ``ensureDesignReviewState`` — lazy constructor.  Called by the
##     chrome-bar and editor-shell mounts.
##   * ``pollBriefHasHistory`` — drives a single poll round against
##     ``$ISONIM_REVIEW_API/api/design-review/brief-has-history?briefId=...``
##     for the active preview.  No-ops gracefully when the daemon URL
##     could not be resolved (the 🕘 button stays hidden).
##   * ``mountHistoryButtonForEditor`` — wraps
##     ``preview_chrome.mountHistoryButton`` and routes the activate
##     handler to the gallery-host show/hide signal.
##   * ``mountGalleryHostForEditor`` — creates a positioned overlay
##     host below the preview pane and conditionally instantiates
##     the gallery overlay on first open.

import std/[options, strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui

import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/brief_index_static
import isonim/editor/design_review/daemon_discovery
import isonim/editor/design_review/editor_http_client
import isonim/editor/views/preview_chrome
import isonim/editor/views/gallery_overlay

type
  GalleryHostState* = enum
    ghsClosed, ghsOpen

  DesignReviewState* = ref object
    historyVm*: HistoryButtonVM
    galleryVm*: GalleryVM
    briefId*: Signal[string]
    briefHasHistory*: Signal[bool]
    galleryHostState*: Signal[GalleryHostState]
    httpClient*: EditorHttpClient
    discovery*: DaemonDiscovery

var states {.threadvar.}: seq[(EditorVM, DesignReviewState)]

proc previewIdFor*(story: StoryRef; backend: PreviewBackend): string =
  ## Project ``StoryRef`` + backend onto the canonical preview-id form.
  if story.name.len == 0:
    return ""
  result = canonicalPreviewId(story, backend)

proc resolveBriefId*(story: StoryRef; backend: PreviewBackend): string =
  ## Resolve the canonical briefId for the gallery / history-button
  ## flow against the active (story, backend) pair.
  ##
  ## Earlier revisions hand-rolled a briefId from
  ## ``story.group + "/" + story.name``, which produced values like
  ## ``"task-app-/-pages/inbox"`` for a story whose actual briefId
  ## (declared in the brief's YAML frontmatter and used as the FK in
  ## ``design_review.runs``) is ``"render.task-app"``.  The result was a
  ## history button that mounted, hit the daemon, but always saw an
  ## empty array — the URL's briefId didn't match anything in the DB.
  ##
  ## TBAR-M1 fixes that by routing the lookup through the same
  ## ``BriefIndex.byPreview`` map the brief-tab uses
  ## (``availableBriefsFor``).  The brief baked into the JS bundle by
  ## ``brief_index_static.builtInBriefIndex`` knows the real briefId
  ## from each brief's YAML frontmatter.
  ##
  ## When more than one brief covers ``(story, backend)``, prefer
  ## briefs of kind ``bkRender`` (the gallery is a visual-review
  ## artefact, and only render briefs trigger captures via the
  ## ``isonim-review capture`` CLI).  Fall back to the first listed
  ## briefId otherwise.
  if story.name.len == 0: return ""
  let idx = builtInBriefIndex()
  if idx == nil or idx.empty():
    return ""
  let previewId = canonicalPreviewId(story, backend)
  if previewId notin idx.byPreview:
    return ""
  let candidates = idx.byPreview[previewId]
  # First pass: prefer a render-kind brief.
  for id in candidates:
    if id in idx.byBriefId:
      if idx.byBriefId[id].kind == bkRender:
        return id
  # Fallback: first brief that resolves.
  for id in candidates:
    if id in idx.byBriefId:
      return id
  ""

proc ensureDesignReviewState*(vm: EditorVM): DesignReviewState =
  for (k, v) in states:
    if k == vm: return v
  let discovery = discoverDaemonBaseUrl()
  let client =
    if discovery.baseUrl.len > 0:
      newEditorHttpClient(discovery.baseUrl)
    else:
      nil
  let historyVm = createHistoryButtonVM()
  let briefIdSig = createSignal("")
  let hasHistorySig = createSignal(false)
  let galleryVm = createGalleryVM("")
  let st = DesignReviewState(
    historyVm: historyVm,
    galleryVm: galleryVm,
    briefId: briefIdSig,
    briefHasHistory: hasHistorySig,
    galleryHostState: createSignal(ghsClosed),
    httpClient: client,
    discovery: discovery)
  states.add((vm, st))
  # Drive ``briefId`` reactively off the EditorVM's selected story + platform.
  let capturedVm = vm
  let capturedState = st
  createRenderEffect proc() =
    let story = capturedVm.selectedStory.val
    let backend = capturedVm.platform.val
    let bid = resolveBriefId(story, backend)
    capturedState.briefId.val = bid
    capturedState.galleryVm.briefId.val = bid
    discard previewIdFor(story, backend)
  # Mirror briefHasHistory onto the history-button VM.
  createRenderEffect proc() =
    capturedState.historyVm.briefHasHistory.val =
      capturedState.briefHasHistory.val
  st

# ---------------------------------------------------------------------------
# Poll briefHasHistory.  Called from a reactive effect whenever
# ``briefId`` changes; the daemon URL might be unreachable in which
# case we just record ``false`` (the button stays hidden).
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Minimal helpers for extracting fields out of the daemon's JSON
# responses without pulling ``std/json`` into the JS bundle.  The
# shapes are well-defined (REV-M3's SQL routines) and small enough
# that a hand-rolled scan is plenty.  Failure paths return the empty
# string / 0; callers treat that as "skip this row".
# ---------------------------------------------------------------------------

proc jsonStringField(json: string; key: string; startAt = 0): string =
  ## Return the string value of ``"<key>": "..."``; "" if missing.
  let needle = "\"" & key & "\""
  let kIdx = json.find(needle, startAt)
  if kIdx < 0: return ""
  let colon = json.find(':', kIdx + needle.len)
  if colon < 0: return ""
  var i = colon + 1
  while i < json.len and json[i] in {' ', '\t', '\n', '\r'}: inc i
  if i >= json.len or json[i] != '"': return ""
  inc i
  var s = newStringOfCap(40)
  while i < json.len and json[i] != '"':
    if json[i] == '\\' and i + 1 < json.len:
      inc i
    s.add(json[i])
    inc i
  s

proc jsonIntField(json: string; key: string; startAt = 0): int =
  let needle = "\"" & key & "\""
  let kIdx = json.find(needle, startAt)
  if kIdx < 0: return 0
  let colon = json.find(':', kIdx + needle.len)
  if colon < 0: return 0
  var i = colon + 1
  while i < json.len and json[i] in {' ', '\t', '\n', '\r'}: inc i
  var s = ""
  while i < json.len and json[i] in {'0'..'9', '-'}:
    s.add(json[i])
    inc i
  if s.len == 0: return 0
  try: parseInt(s) except ValueError: 0

iterator jsonRunIdsFromListHistory(body: string): string =
  ## Yields each ``run_id`` from a ``list-history`` array response.
  ## The response shape is ``[{"run_id":"<uuid>", ...}, ...]`` —
  ## walking key-by-key is sufficient (the run_id is the FIRST key in
  ## each row per REV-M3's jsonb_build_object order).
  var i = 0
  var done = false
  while i < body.len and not done:
    let k = body.find("\"run_id\"", i)
    if k < 0:
      done = true
    else:
      let id = jsonStringField(body, "run_id", i)
      if id.len == 0:
        done = true
      else:
        yield id
        i = k + 10  # past "\"run_id\""

iterator jsonCaptureBlobsFromRun(runBody: string): string =
  ## Walks the ``captures`` array inside a ``fetch-run`` body.  Each
  ## yielded string is the JSON for a single capture object — we keep
  ## it as a slice so callers can pull individual fields via
  ## ``jsonStringField`` / ``jsonIntField`` without a real parser.
  let capsKey = "\"captures\""
  let kIdx = runBody.find(capsKey)
  let bracket = if kIdx >= 0: runBody.find('[', kIdx) else: -1
  if kIdx >= 0 and bracket >= 0:
    var i = bracket + 1
    var depth = 0
    var start = -1
    var done = false
    while i < runBody.len and not done:
      let ch = runBody[i]
      if depth == 0 and ch == ']':
        done = true
      else:
        if ch == '{':
          if depth == 0: start = i
          inc depth
        elif ch == '}':
          dec depth
          if depth == 0 and start >= 0:
            yield runBody[start .. i]
            start = -1
        inc i

proc galleryTilesFromRun(runBody: string): seq[GalleryTile] =
  result = @[]
  let runId = jsonStringField(runBody, "run_id")
  let status = jsonStringField(runBody, "status")
  for cap in jsonCaptureBlobsFromRun(runBody):
    let captureId = jsonStringField(cap, "capture_id")
    if captureId.len == 0: continue
    let previewId = jsonStringField(cap, "preview_id")
    let width = jsonIntField(cap, "width")
    let height = jsonIntField(cap, "height")
    result.add GalleryTile(
      captureId: captureId,
      runId: runId,
      previewId: previewId,
      status: status,
      pngUrl: "/api/design-review/get-capture-png?id=" & captureId,
      width: width,
      height: height,
      score: none[float](),
    )

# ---------------------------------------------------------------------------
# Fetch-on-open: when the gallery host first toggles to ``ghsOpen``, run
# ``list-history`` → ``fetch-run`` per run → assemble ``GalleryTile`` rows
# and write them into ``st.galleryVm.tiles``.  Subsequent opens are no-ops
# (the tile cache lives on the VM until the brief id changes).
# ---------------------------------------------------------------------------

proc fetchGalleryTiles*(st: DesignReviewState) =
  ## Drive the two-step fetch.  No-ops gracefully when the daemon URL
  ## was not resolved (the gallery stays empty + the "No captures yet"
  ## placeholder is shown).
  let bid = st.briefId.val
  if bid.len == 0 or st.httpClient == nil:
    return
  let capturedState = st
  let capturedBriefId = bid
  proc onHistory(res: HttpCallbackResult) =
    if res.kind != hcOk: return
    # Snapshot the briefId we started with; if the user switched
    # stories before fetch-run completes, abandon the in-flight work.
    if capturedState.briefId.val != capturedBriefId: return
    var runIds: seq[string] = @[]
    for runId in jsonRunIdsFromListHistory(res.body):
      runIds.add(runId)
    if runIds.len == 0:
      capturedState.galleryVm.tiles.val = @[]
      return
    # Bound the chase so a long history doesn't fan out into 100+
    # parallel requests.  20 most-recent runs is plenty for the
    # initial render; the gallery can paginate later.
    let toFetch = min(runIds.len, 20)
    var pending = toFetch
    var collected: seq[GalleryTile] = @[]
    # Per-callback closure: append + decrement, commit when last lands.
    proc finish() =
      if pending != 0: return
      if capturedState.briefId.val != capturedBriefId: return
      capturedState.galleryVm.tiles.val = collected
    for i in 0 ..< toFetch:
      let rid = runIds[i]
      proc onRun(rr: HttpCallbackResult) =
        if rr.kind == hcOk:
          for tile in galleryTilesFromRun(rr.body):
            collected.add(tile)
        dec pending
        finish()
      fetchRun(capturedState.httpClient, rid, onRun)
  fetchListHistory(st.httpClient, bid, 50, 0, onHistory)

proc startGalleryFetchOnOpen*(st: DesignReviewState) =
  ## Reactive effect: whenever ``galleryHostState`` flips to ``ghsOpen``
  ## with an empty ``tiles`` cache, kick off the two-step fetch.
  let capturedState = st
  createRenderEffect proc() =
    let open = capturedState.galleryHostState.val == ghsOpen
    if not open: return
    if capturedState.galleryVm.tiles.val.len > 0: return
    if capturedState.briefId.val.len == 0: return
    fetchGalleryTiles(capturedState)

  # When the briefId changes while the host is closed, drop any
  # stale tiles so the next open re-fetches against the new brief.
  createRenderEffect proc() =
    let bid = capturedState.briefId.val
    discard bid
    if capturedState.galleryHostState.val == ghsClosed:
      capturedState.galleryVm.tiles.val = @[]

proc pollBriefHasHistory*(st: DesignReviewState) =
  let bid = st.briefId.val
  if bid.len == 0 or st.httpClient == nil:
    st.briefHasHistory.val = false
    return
  let capturedState = st
  proc cb(res: HttpCallbackResult) =
    if res.kind != hcOk:
      capturedState.briefHasHistory.val = false
      return
    # Minimal "hasHistory" parser — we don't pull in std/json here so
    # the JS bundle stays compact.  The body shape is
    # ``{"hasHistory":bool,"runCount":int}``.
    if res.body.contains("\"hasHistory\":true"):
      capturedState.briefHasHistory.val = true
    else:
      capturedState.briefHasHistory.val = false
  fetchBriefHasHistory(st.httpClient, bid, cb)

proc startBriefHasHistoryPolling*(st: DesignReviewState) =
  ## Reactively re-poll whenever the active brief id changes.
  let capturedState = st
  createRenderEffect proc() =
    let bid = capturedState.briefId.val
    discard bid
    pollBriefHasHistory(capturedState)

# ---------------------------------------------------------------------------
# Mount helpers.
# ---------------------------------------------------------------------------

proc mountHistoryButtonForEditor*[R, E](r: R; parent: E; vm: EditorVM) =
  ## Append the 🕘 button onto ``parent`` (a chrome-bar host).  When the
  ## daemon is unreachable the button never becomes visible (its
  ## ``data-history-visible`` attr stays "false") so a fresh / offline
  ## editor doesn't sprout a useless control.
  let st = ensureDesignReviewState(vm)
  startBriefHasHistoryPolling(st)
  let capturedState = st
  proc onActivate() =
    capturedState.galleryHostState.val =
      if capturedState.galleryHostState.val == ghsClosed: ghsOpen
      else: ghsClosed
  mountHistoryButton[R, E](r, parent, st.historyVm, onActivate)

proc mountGalleryHostForEditor*[R, E](r: R; parent: E; vm: EditorVM): E =
  ## Build the gallery overlay host: a positioned ``div`` that holds
  ## the ``mountGalleryOverlay`` output and toggles its
  ## ``data-gallery-host-visible`` attribute reactively. Returns the
  ## host node so callers can position it in their layout.
  ##
  ## CHRM-M5 Fix D: the host's visibility is now driven by
  ## ``galleryHostState == ghsOpen`` alone — the previous
  ## ``open and briefHasHistory`` AND gate hid the overlay entirely
  ## when no captures existed for the active brief, so the user
  ## perceived the 🕘 button as broken (the click toggled
  ## ``data-gallery-host-open`` but the host stayed
  ## ``display: none``). The gallery overlay already renders an
  ## empty-state "No captures yet" panel
  ## (``gallery_overlay.nim:636``), so we just surface that panel
  ## when the user clicks the button regardless of whether any
  ## captures exist for the current brief. ``briefHasHistory`` is
  ## still polled (it gates the 🕘 button's own visual
  ## ``data-history-visible`` attribute) but no longer acts as a
  ## second on-screen kill switch on the overlay.
  let st = ensureDesignReviewState(vm)
  startGalleryFetchOnOpen(st)
  let capturedState = st
  let host = ui(r):
    tdiv(
      `data-design-review-gallery-host` = "true",
      `data-gallery-host-visible` = "false",
      display = "none",
      flex_direction = "column",
      flex = "1 1 auto",
      min_height = "0",
      overflow = "hidden",
      width = "100%",
      `aria-live` = "polite")
  # Mount the gallery overlay once into the host; toggle visibility via
  # the data-attribute path that gallery_overlay.nim already uses.
  mountGalleryOverlay[R, E](r, host, st.galleryVm)
  createRenderEffect proc() =
    let open = capturedState.galleryHostState.val == ghsOpen
    let visible = open
    r.setAttribute(host, "data-gallery-host-visible",
                   if visible: "true" else: "false")
    r.setAttribute(host, "data-gallery-host-open",
                   if open: "true" else: "false")
    r.setAttribute(host, "aria-hidden",
                   if visible: "false" else: "true")
    # CHRM-M5 Fix D: drive the inline display style too so the
    # overlay actually renders on-screen when the user opens it.
    # Previously only the data-attribute flipped; ``display:none``
    # from the initial inline style stuck, making the overlay a
    # zero-size element under the chrome bar.
    r.setStyle(host, "display", if visible: "flex" else: "none")
  r.appendChild(parent, host)
  host
