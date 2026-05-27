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
    # CHRM-M7 — narrow-viewport breakpoint signal.  Driven by a JS
    # ``window.innerWidth`` probe + resize listener installed by
    # ``mountGalleryHostForEditor``. ``true`` when the viewport width
    # is ≤768 px (the threshold the editor's CSS uses to collapse the
    # centre column to sidebar-only). Drives the gallery host's
    # mount-mode swap from "inline overlay in the centre column" to
    # "fixed full-viewport drawer" so the gallery stays reachable on
    # touch / phone widths.
    narrow*: Signal[bool]

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
    discovery: discovery,
    # CHRM-M7 — initialise the narrow signal optimistically to false;
    # ``mountGalleryHostForEditor`` installs the JS resize probe that
    # flips it reactively based on ``window.innerWidth``.
    narrow: createSignal(false))
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

proc galleryTilesFromRun(runBody: string; baseUrl: string = ""): seq[GalleryTile] =
  ## CHRM-M6 Wave A — ``baseUrl`` is the daemon-discovered base URL
  ## (e.g. ``http://127.0.0.1:8113``).  Prepending it keeps the
  ## ``<img src>`` tags pointing at the daemon when the editor is
  ## served from a different origin (the typical local-dev setup:
  ## editor on :8090, daemon on :8113).  An empty ``baseUrl`` falls
  ## back to the legacy relative path for backwards-compat with the
  ## existing native unit tests.
  result = @[]
  let runId = jsonStringField(runBody, "run_id")
  let status = jsonStringField(runBody, "status")
  for cap in jsonCaptureBlobsFromRun(runBody):
    let captureId = jsonStringField(cap, "capture_id")
    if captureId.len == 0: continue
    let previewId = jsonStringField(cap, "preview_id")
    let width = jsonIntField(cap, "width")
    let height = jsonIntField(cap, "height")
    let urlPath = "/api/design-review/get-capture-png?id=" & captureId
    let absUrl =
      if baseUrl.len > 0:
        # Defensive: trim trailing slash from baseUrl so we don't
        # double up the slash when joining with the leading-slash
        # path.  Matches ``editor_http_client.joinUrl``'s behaviour.
        if baseUrl[^1] == '/':
          baseUrl[0 ..< baseUrl.len - 1] & urlPath
        else:
          baseUrl & urlPath
      else:
        urlPath
    result.add GalleryTile(
      captureId: captureId,
      runId: runId,
      previewId: previewId,
      status: status,
      pngUrl: absUrl,
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
    let capturedBaseUrl =
      if capturedState.httpClient != nil:
        capturedState.httpClient.baseUrl
      else:
        ""
    for i in 0 ..< toFetch:
      let rid = runIds[i]
      proc onRun(rr: HttpCallbackResult) =
        if rr.kind == hcOk:
          for tile in galleryTilesFromRun(rr.body, capturedBaseUrl):
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

proc mountSidebarHistoryButtonForEditor*[R, E](r: R; parent: E; vm: EditorVM) =
  ## CHRM-M7 — narrow-mode sidebar mirror of the chrome-bar 🕘 button.
  ##
  ## At narrow viewports (≤768 px) the centre column collapses to
  ## ``display: none`` via the ``@media (max-width: 768px)`` rule in
  ## ``browser.nim``, which makes the chrome-bar history button
  ## unreachable. This mount provides a duplicate affordance in the
  ## sidebar header that drives the same ``galleryHostState`` signal.
  ##
  ## The button intentionally does NOT carry the canonical
  ## ``data-design-review-history-button="true"`` attribute — only the
  ## chrome-bar button does, so existing tests / tooling that search
  ## for that selector continue to resolve to a single (visible at
  ## wide / laptop) element. The sidebar mirror is found via the
  ## scoped ``.editor-sidebar-history-narrow [role="button"]`` query
  ## or the dedicated ``data-design-review-history-button-sidebar``
  ## attribute the CHRM-M7 e2e test asserts against.
  let st = ensureDesignReviewState(vm)
  startBriefHasHistoryPolling(st)
  let capturedState = st
  let capturedVm = st.historyVm
  # CHRM-M7 polish — 44 × 44 px minimum hit area per iOS HIG / Android
  # Material guidance. The button only renders at narrow widths (the
  # ``editor-sidebar-history-narrow`` slot is ``display: none`` at
  # wide/laptop via ``browser.nim``'s media query) so the larger
  # touch target doesn't disturb the chrome-bar history button used
  # by mouse on wide. The button's visual centre stays the 🕘 glyph;
  # the extra dimension translates to a more generous tap area
  # without changing the chip shape.
  let button = ui(r):
    tdiv(
      `role` = "button",
      tabindex = "0",
      `aria-label` = "Open design-review gallery",
      `data-design-review-history-button-sidebar` = "true",
      `data-history-visible` = "false",
      display = "inline-flex",
      align_items = "center",
      justify_content = "center",
      width = "44px",
      height = "44px",
      min_width = "44px",
      min_height = "44px",
      padding = "0",
      font_size = "18px",
      color = "#F1F5F9",
      background_color = "#0F172A",
      border = "1px solid #334155",
      border_radius = "6px",
      cursor = "pointer",
      user_select = "none"):
      text "\u{1F558}"
  proc onActivate() =
    capturedState.galleryHostState.val =
      if capturedState.galleryHostState.val == ghsClosed: ghsOpen
      else: ghsClosed
    capturedVm.galleryOpen.val = not capturedVm.galleryOpen.val
  r.addEventListener(button, "click", onActivate)
  r.addEventListener(button, "keydown", onActivate)
  # Mirror the chrome-bar button's ``data-history-visible`` /
  # ``data-gallery-open`` attributes so the sidebar mirror reflects
  # the same state to css / tooling.
  createRenderEffect proc() =
    let hasHistory = capturedVm.briefHasHistory.val
    let isOpen = capturedState.galleryHostState.val == ghsOpen
    r.setAttribute(button, "data-history-visible",
                   if hasHistory: "true" else: "false")
    r.setAttribute(button, "aria-pressed",
                   if isOpen: "true" else: "false")
    r.setAttribute(button, "data-gallery-open",
                   if isOpen: "true" else: "false")
  r.appendChild(parent, button)

proc startNarrowViewportProbe*(st: DesignReviewState) =
  ## CHRM-M7 — install a JS-side ``window.innerWidth`` probe that
  ## drives ``st.narrow`` reactively. The 768 px threshold matches
  ## ``browser.nim``'s ``@media (max-width: 768px)`` rule that
  ## collapses the centre column to sidebar-only. A single resize
  ## listener is installed per state; the listener is intentionally
  ## not removed because the editor mounts once per page load.
  ##
  ## On non-JS targets (native unit tests via the MockRenderer) the
  ## probe is a no-op — tests can drive ``st.narrow.val`` directly.
  let capturedState = st
  when defined(js):
    proc setNarrow(value: bool) =
      capturedState.narrow.val = value
    let cb = setNarrow
    {.emit: ["""
      (function() {
        var fn = """, cb, """;
        var apply = function() {
          try {
            var w = (typeof window !== 'undefined' && window.innerWidth) || 0;
            fn(w > 0 && w <= 768);
          } catch (e) { /* ignore */ }
        };
        apply();
        if (typeof window !== 'undefined' && window.addEventListener) {
          window.addEventListener('resize', apply);
        }
      })();
    """].}

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
  startNarrowViewportProbe(st)
  let capturedState = st
  let host = ui(r):
    tdiv(
      `data-design-review-gallery-host` = "true",
      `data-gallery-host-visible` = "false",
      `data-gallery-mount-mode` = "inline",
      display = "none",
      flex_direction = "column",
      flex = "1 1 auto",
      min_height = "0",
      overflow = "hidden",
      width = "100%",
      `aria-live` = "polite")
  # CHRM-M7 — close affordance that surfaces only in drawer (narrow)
  # mode. The chip is appended to the host BEFORE the overlay body
  # so it floats above the gallery toolbar at the top-right corner.
  # Wide / laptop modes hide it via the same data-attribute path
  # used elsewhere in the file. The chip drives the gallery host
  # state back to ``ghsClosed`` so the drawer dismisses cleanly.
  let closeChip = ui(r):
    tdiv(
      `role` = "button", tabindex = "0",
      `aria-label` = "Close gallery",
      `data-design-review-gallery-close` = "true",
      display = "none",
      position = "absolute",
      top = "10px", right = "10px",
      width = "32px", height = "32px",
      align_items = "center", justify_content = "center",
      font_size = "16px", font_weight = "600",
      color = "#F1F5F9",
      background_color = "#1E293B",
      border = "1px solid #334155",
      border_radius = "16px",
      cursor = "pointer",
      z_index = "10",
      user_select = "none"):
      text "\xC3\x97"  # × MULTIPLICATION SIGN
  let onClose = proc() =
    capturedState.galleryHostState.val = ghsClosed
  r.addEventListener(closeChip, "click", onClose)
  r.addEventListener(closeChip, "keydown", onClose)
  r.appendChild(host, closeChip)
  # Mount the gallery overlay once into the host; toggle visibility via
  # the data-attribute path that gallery_overlay.nim already uses.
  # CHRM-M7 polish — thread the narrow-viewport signal through so the
  # gallery toolbar can swap to a single-line horizontally-scrollable
  # chip strip at ≤768 px (Pattern A in the polish wave brief).
  mountGalleryOverlay[R, E](r, host, st.galleryVm, narrow = st.narrow)
  # CHRM-M7 — re-parenting bookkeeping. When the viewport flips to
  # narrow AND the gallery is open, detach the host from its inline
  # parent (the centre column) and attach it to ``document.body`` so
  # ``position: fixed`` can paint over the sidebar. When the viewport
  # flips back to wide/laptop (or the user closes the gallery while
  # narrow) we re-parent back to the original ``parent`` so the
  # inline layout returns to the centre column.
  var parentedToBody = false
  let originalParent = parent
  createRenderEffect proc() =
    let open = capturedState.galleryHostState.val == ghsOpen
    let isNarrow = capturedState.narrow.val
    let visible = open
    let drawerMode = isNarrow and open
    r.setAttribute(host, "data-gallery-host-visible",
                   if visible: "true" else: "false")
    r.setAttribute(host, "data-gallery-host-open",
                   if open: "true" else: "false")
    r.setAttribute(host, "data-gallery-mount-mode",
                   if drawerMode: "drawer" else: "inline")
    r.setAttribute(host, "aria-hidden",
                   if visible: "false" else: "true")
    # Show the close chip only in drawer mode (narrow + open). Wide
    # users have ESC + the chrome-bar history button toggle.
    r.setAttribute(closeChip, "data-design-review-gallery-close-visible",
                   if drawerMode: "true" else: "false")
    # CHRM-M5 Fix D + CHRM-M6 Wave B: drive the inline display style
    # too so the overlay actually renders on-screen when the user
    # opens it. Previously only the data-attribute flipped;
    # ``display:none`` from the initial inline style stuck, making
    # the overlay a zero-size element under the chrome bar.
    #
    # The Wave-A no-setStyle invariant
    # (``test_design_review_gallery_no_setstyle``) bans ``r.setStyle``
    # from this file. We use the same ``{.emit.}`` JS shim pattern
    # that ``gallery_overlay.nim`` uses for its grid/full-tab/compare
    # host-display toggle: write only ``style.display`` so the other
    # layout properties (flex, flex-direction, etc.) emitted by the
    # DSL stay intact, and avoid ``setAttribute("style", ...)`` which
    # would replace the whole inline style and drop those properties.
    #
    # CHRM-M7 extends the shim: in drawer mode we also drive the
    # ``position``, ``inset``, ``z-index``, and ``border-radius``
    # properties so the host overlays the whole viewport (minus a
    # small top inset that leaves the editor's collapsed chrome
    # visible). In inline mode we clear those fixed-positioning
    # properties so wide / laptop reviewers see the legacy inline
    # overlay behaviour unchanged.
    when defined(js):
      let hostDisp: cstring =
        if visible: "flex" else: "none"
      let drawerPosition: cstring =
        if drawerMode: "fixed" else: ""
      let drawerInset: cstring =
        # 56 px top inset leaves room for the narrow-mode chrome bar
        # (sidebar header + history button row) so the user retains
        # a sense of location.
        if drawerMode: "56px 0 0 0" else: ""
      let drawerZIndex: cstring =
        if drawerMode: "9000" else: ""
      let drawerRadius: cstring =
        if drawerMode: "0" else: ""
      let drawerHeight: cstring =
        if drawerMode: "auto" else: ""
      let closeDisp: cstring =
        if drawerMode: "inline-flex" else: "none"
      {.emit: ["""
        try {
          if (""", host, """ && """, host, """.style) {
            """, host, """.style.display = """, hostDisp, """;
            """, host, """.style.position = """, drawerPosition, """;
            """, host, """.style.inset = """, drawerInset, """;
            """, host, """.style.zIndex = """, drawerZIndex, """;
            """, host, """.style.borderRadius = """, drawerRadius, """;
            """, host, """.style.height = """, drawerHeight, """;
          }
          if (""", closeChip, """ && """, closeChip, """.style) {
            """, closeChip, """.style.display = """, closeDisp, """;
          }
        } catch (e) { /* ignore */ }
      """].}
    # CHRM-M7 — host re-parenting. When the gallery flips into drawer
    # mode we detach the host from its inline parent (the centre
    # column, which is ``display: none`` at narrow widths via CSS) and
    # attach it to ``document.body`` so the fixed-positioned host
    # paints above the sidebar. When the gallery closes OR the user
    # widens the viewport back past 768 px, the host returns to its
    # original inline parent and the close-chip hides.
    when defined(js):
      let wantBody = drawerMode
      if wantBody and not parentedToBody:
        {.emit: ["""
          try {
            if (""", host, """ && """, host, """.parentNode) {
              """, host, """.parentNode.removeChild(""", host, """);
            }
            if (typeof document !== 'undefined' && document.body) {
              document.body.appendChild(""", host, """);
            }
          } catch (e) { /* ignore */ }
        """].}
        parentedToBody = true
      elif not wantBody and parentedToBody:
        {.emit: ["""
          try {
            if (""", host, """ && """, host, """.parentNode) {
              """, host, """.parentNode.removeChild(""", host, """);
            }
            if (""", originalParent, """ && """, originalParent, """.appendChild) {
              """, originalParent, """.appendChild(""", host, """);
            }
          } catch (e) { /* ignore */ }
        """].}
        parentedToBody = false
  r.appendChild(parent, host)
  host
