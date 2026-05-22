## TBAR-M5 — HTTP handlers for write-side brief routes.
##
## Today this file ships one route:
##
##   POST /api/design-review/save-brief
##     Body (JSON): { "briefId": "<id>", "markdown": "<full body>" }
##     Response (JSON, 200):
##       { "briefId": "<id>", "path": "<abs>", "bytesWritten": <n> }
##     Errors:
##       400 missing_field         — when briefId/markdown missing
##       400 invalid_json          — when body is not JSON
##       404 unknown_briefId       — when briefIndex has no entry
##       403 outside_workspace     — when resolved file path escapes
##                                    cfg.workspace.root
##       500 write_failed          — file system error
##
## Resolution:
##   ``briefId → file path`` via an in-process ``BriefIndex`` the
##   daemon loads lazily from ``cfg.workspace.root``. Each
##   ``Brief.sourceFile`` carries the abs path it was parsed from.
##
## Guard:
##   The resolved file path must be inside ``cfg.workspace.root``
##   (canonicalised on both sides via ``absolutePath`` /
##   ``normalizedPath`` so symlinks or ``..`` cannot escape).
##
## The handler writes the file body verbatim — no markdown re-
## formatting, no git commit. The operator owns commits.
##
## After a successful write, the daemon re-parses that single brief
## file and patches its entry in the in-process ``BriefIndex`` so the
## next request sees the new body.

import std/[asyncdispatch, asynchttpserver, json, locks, os, strutils, tables]

import ./api_handlers
import ./brief_format
import ./brief_index

# ---------------------------------------------------------------------------
# In-process daemon-side BriefIndex.
#
# The daemon does not (yet) load a BriefIndex at startup the way the
# editor JS bundle bakes one in. We therefore lazy-load it on the
# first save-brief call. The index covers every ``briefs/`` subtree
# under ``workspace.root`` so an operator with multiple sibling
# projects (e.g. ``isonim-examples/`` and a follow-on project) sees
# them all.
# ---------------------------------------------------------------------------

type
  DaemonBriefStore* = ref object
    workspaceRoot*: string
    index*: BriefIndex
    loaded*: bool
    lock*: Lock

proc newDaemonBriefStore*(workspaceRoot: string): DaemonBriefStore =
  result = DaemonBriefStore(
    workspaceRoot: workspaceRoot,
    index: BriefIndex(
      byBriefId: initOrderedTable[string, Brief](),
      byPreview: initOrderedTable[string, seq[string]](),
      errors: @[]),
    loaded: false,
  )
  initLock(result.lock)

proc findBriefsDirs(root: string): seq[string] =
  ## Walk ``root`` looking for ``briefs/`` subdirectories.  We accept
  ## ``root/briefs`` (single-project layout) and ``root/*/briefs``
  ## (multi-project sibling layout).  We do NOT descend further than
  ## that — the workspace root is typically a multi-repo tree and a
  ## deeper sweep would pick up unrelated trees.
  ##
  ## Test hook: ``ISONIM_REVIEW_EXTRA_BRIEFS_DIRS`` (path-list,
  ## colon-separated on POSIX) appends additional brief directories
  ## to the discovery set.  Used by the save-brief route's
  ## "outside-workspace" guard test so it can place a brief on
  ## disk outside the configured ``workspace.root`` and still see
  ## the handler resolve it (then refuse to write to it).  Production
  ## callers never set this var; the unit test sets it explicitly.
  if root.len > 0 and dirExists(root):
    let direct = root / "briefs"
    if dirExists(direct):
      result.add direct
    for kind, sub in walkDir(root):
      if kind != pcDir: continue
      let candidate = sub / "briefs"
      if dirExists(candidate):
        result.add candidate
  let extra = getEnv("ISONIM_REVIEW_EXTRA_BRIEFS_DIRS")
  if extra.len > 0:
    for part in extra.split(PathSep):
      let p = part.strip()
      if p.len == 0: continue
      if dirExists(p):
        result.add p

proc mergeIndex(dst, src: BriefIndex) =
  ## Merge ``src`` into ``dst``.  Used to combine per-briefs-dir
  ## indexes into the daemon-wide one.  Duplicate briefIds across
  ## directories are recorded as errors (same shape as the in-
  ## directory case) and excluded from ``byBriefId``.
  for id, brief in src.byBriefId.pairs:
    if id in dst.byBriefId:
      let prev = dst.byBriefId[id]
      dst.errors.add(BriefIndexError(
        path: brief.sourceFile,
        message: "duplicate briefId '" & id & "' across briefs/ dirs (" &
          prev.sourceFile & " vs " & brief.sourceFile & ")"))
      # Drop both — same posture as in-directory duplicates.
      dst.byBriefId.del(id)
      continue
    dst.byBriefId[id] = brief
  for previewId, briefIds in src.byPreview.pairs:
    if previewId notin dst.byPreview:
      dst.byPreview[previewId] = @[]
    for id in briefIds:
      var lst = dst.byPreview[previewId]
      if id notin lst:
        lst.add id
        dst.byPreview[previewId] = lst
  for e in src.errors:
    dst.errors.add e

proc loadDaemonBriefIndex*(store: DaemonBriefStore) {.gcsafe.} =
  ## Build the combined index from every ``briefs/`` directory under
  ## ``store.workspaceRoot``.  Safe to call repeatedly; the lock
  ## guards the load.  An empty workspace root produces an empty
  ## (non-nil) index.
  ##
  ## ``buildBriefIndex`` reaches ``parseBrief`` which is flagged
  ## ``GcUnsafe2`` upstream — same reasoning as ``reparseBrief``
  ## below; the daemon is single-threaded for this code path and the
  ## lock serialises any concurrent loads.
  {.cast(gcsafe).}:
    withLock store.lock:
      let dirs = findBriefsDirs(store.workspaceRoot)
      store.index = BriefIndex(
        byBriefId: initOrderedTable[string, Brief](),
        byPreview: initOrderedTable[string, seq[string]](),
        errors: @[])
      for d in dirs:
        let sub = buildBriefIndex(d)
        mergeIndex(store.index, sub)
      store.loaded = true

proc ensureLoaded(store: DaemonBriefStore) {.gcsafe.} =
  if store == nil: return
  if store.loaded: return
  loadDaemonBriefIndex(store)

proc reparseBrief*(store: DaemonBriefStore; filePath: string) {.gcsafe.} =
  ## Re-parse the single brief at ``filePath`` and replace its entry
  ## in the in-memory index.  Called by the save-brief handler after
  ## a successful write so subsequent reads see the new body without
  ## a full sweep.  Failures are recorded in ``index.errors`` but
  ## never raised — the write already succeeded.
  ##
  ## The refresh covers BOTH inverted maps:
  ##
  ## * ``byBriefId[<id>]`` — the row keyed by the parsed brief's id.
  ## * ``byPreview[<previewId>]`` — every ``(storyRef, backend)`` the
  ##   brief lists under ``coversPreviews``.  Without this second
  ##   sweep, a save that adds/removes a story or backend would leave
  ##   ``byPreview`` pointing at the brief's pre-save shape until
  ##   daemon restart, and the editor's history button would resolve
  ##   the wrong briefId for the active story.
  ##
  ## ``parseBrief`` is flagged as ``GcUnsafe2`` upstream (the YAML
  ## subset parser uses a mutually-recursive callgraph that the
  ## stdlib's GC-safety checker can't statically clear).  The
  ## brief-format module is process-local state and the daemon's
  ## scheduler never crosses thread boundaries inside this proc
  ## (the ``withLock`` guard above serialises any potential
  ## concurrent calls), so a ``cast(gcsafe)`` is sound.
  if store == nil: return
  {.cast(gcsafe).}:
    withLock store.lock:
      var parsed: Brief
      var ok = false
      try:
        parsed = parseBrief(filePath)
        ok = true
      except BriefParseError as e:
        store.index.errors.add(BriefIndexError(path: filePath, message: e.msg))
      except IOError as e:
        store.index.errors.add(BriefIndexError(path: filePath, message: e.msg))
      except OSError as e:
        store.index.errors.add(BriefIndexError(path: filePath, message: e.msg))
      if ok:
        # Drop any prior entry that lived at this file path so a kind /
        # briefId change in the body doesn't leave a stale row.
        var idsToDrop: seq[string] = @[]
        for id, b in store.index.byBriefId.pairs:
          if b.sourceFile == filePath and b.briefId != parsed.briefId:
            idsToDrop.add id
        for id in idsToDrop:
          store.index.byBriefId.del id
        store.index.byBriefId[parsed.briefId] = parsed

        # Refresh ``byPreview``.  We don't know which previewIds the
        # brief covered BEFORE this save, so we sweep every key and
        # drop any list entry that references the brief's old or new
        # id (the old-id path matters when a save renames the brief).
        # Then we re-add the entries for the brief's current shape —
        # mirroring the per-brief shape that ``buildBriefIndex`` in
        # ``brief_index.nim`` produces during a full sweep.
        let touchedIds = @[parsed.briefId] & idsToDrop
        var emptiedKeys: seq[string] = @[]
        for previewId, briefIds in store.index.byPreview.mpairs:
          var filtered: seq[string] = @[]
          for bid in briefIds:
            if bid notin touchedIds:
              filtered.add bid
          if filtered.len == 0:
            emptiedKeys.add previewId
          else:
            store.index.byPreview[previewId] = filtered
        for k in emptiedKeys:
          store.index.byPreview.del k
        for cov in parsed.coversPreviews:
          for be in cov.backends:
            let previewId = canonicalPreviewId(cov.storyRef, be)
            if previewId notin store.index.byPreview:
              store.index.byPreview[previewId] = @[]
            var lst = store.index.byPreview[previewId]
            if parsed.briefId notin lst:
              lst.add parsed.briefId
              store.index.byPreview[previewId] = lst

# ---------------------------------------------------------------------------
# Path containment helper.  Both sides are canonicalised so a symlink
# or ``..`` traversal cannot escape ``root``.
# ---------------------------------------------------------------------------

proc canonicalizeParent(lexical: string): string =
  ## Walk ``lexical`` upward until we find a path component that
  ## exists on disk, ``expandFilename`` its canonical form (which
  ## resolves any symlinks in the existing prefix), then re-join the
  ## non-existing tail.  Used by ``canonicalize`` when the target
  ## path doesn't exist yet (e.g. a brand-new brief whose file is
  ## about to be created), so the containment check still rejects
  ## paths whose existing parent resolves outside the workspace.
  ##
  ## If no ancestor exists (only possible for an empty / root path),
  ## fall back to the lexical form unchanged.
  var head = lexical
  var tail = ""
  while head.len > 0:
    if fileExists(head) or dirExists(head):
      try:
        let resolved = expandFilename(head)
        if tail.len == 0: return resolved
        return resolved / tail
      except OSError:
        # ``expandFilename`` only fails when the path no longer
        # exists by the time we resolve it; fall through and walk
        # one more level up.
        discard
    let (parent, name) = splitPath(head)
    if name.len == 0 or parent == head:
      break
    tail = if tail.len == 0: name else: name / tail
    head = parent
  result = lexical

proc canonicalize(path: string): string =
  if path.len == 0: return ""
  # ``absolutePath`` + ``normalizedPath`` produces the lexical
  # (no-symlinks-followed) absolute path.  We then resolve symlinks
  # via ``expandFilename`` so a brief whose path traverses a symlink
  # that escapes the workspace can no longer bypass ``isInsideDir``.
  let lexical = normalizedPath(absolutePath(path))
  try:
    return expandFilename(lexical)
  except OSError:
    # File doesn't exist yet (e.g. a brand-new brief being written
    # for the first time).  Resolve as far up the path as we can —
    # any symlink in the existing prefix still gets followed.
    return canonicalizeParent(lexical)

proc isInsideDir*(child, root: string): bool =
  ## True when ``child`` resolves to a path inside ``root`` (or equal
  ## to it).  Both inputs are canonicalised before the prefix check.
  ## The check uses a path separator after the prefix so
  ## ``/tmp/foo-bar`` is NOT considered inside ``/tmp/foo``.
  if child.len == 0 or root.len == 0:
    return false
  let c = canonicalize(child)
  let r = canonicalize(root)
  if c == r: return true
  let rWithSep = r & DirSep
  c.startsWith(rWithSep)

# ---------------------------------------------------------------------------
# Handler.
# ---------------------------------------------------------------------------

proc parseSaveBody(req: Request): JsonNode =
  if req.body.len == 0:
    return newJNull()
  try:
    result = parseJson(req.body)
  except JsonParsingError:
    result = nil

proc fieldStr(node: JsonNode; key: string): string =
  if node == nil or node.kind != JObject: return ""
  if not node.hasKey(key): return ""
  let v = node[key]
  case v.kind
  of JString: v.getStr
  of JNull:   ""
  else:       ""

proc saveBriefHandler*(store: DaemonBriefStore; workspaceRoot: string;
                       req: Request) {.async, gcsafe.} =
  ## TBAR-M5 — ``POST /api/design-review/save-brief``.  Writes the
  ## supplied markdown to the brief's source file, refusing to write
  ## outside ``workspaceRoot``.
  if req.reqMethod != HttpPost:
    await respondError(req, Http405, "method_not_allowed")
    return
  let body = parseSaveBody(req)
  if body == nil:
    await respondError(req, Http400, "invalid_json")
    return
  if body.kind != JObject:
    await respondError(req, Http400, "invalid_json")
    return

  let briefId = fieldStr(body, "briefId")
  if briefId.len == 0:
    await respondError(req, Http400, "missing_field")
    return
  # ``markdown`` is allowed to be an empty string (clearing a brief
  # body), but the key must be present and string-typed.  Treat
  # missing key / non-string value as ``missing_field`` so the
  # editor sees the same error shape it does for ``briefId``.
  if not body.hasKey("markdown") or body["markdown"].kind != JString:
    await respondError(req, Http400, "missing_field")
    return
  let markdown = body["markdown"].getStr

  ensureLoaded(store)

  var brief: Brief
  var found = false
  withLock store.lock:
    if briefId in store.index.byBriefId:
      brief = store.index.byBriefId[briefId]
      found = true
  if not found:
    await respondError(req, Http404, "unknown_briefId")
    return

  let resolvedPath = brief.sourceFile
  if not isInsideDir(resolvedPath, workspaceRoot):
    await respondError(req, Http403, "outside_workspace")
    return

  let canonical = canonicalize(resolvedPath)
  try:
    writeFile(canonical, markdown)
  except IOError as e:
    stderr.writeLine("api_handlers_briefs.saveBrief: write failed: " & e.msg)
    await respondError(req, Http500, "write_failed")
    return
  except OSError as e:
    stderr.writeLine("api_handlers_briefs.saveBrief: write failed: " & e.msg)
    await respondError(req, Http500, "write_failed")
    return

  reparseBrief(store, canonical)

  let resp = %* {
    "briefId": briefId,
    "path": canonical,
    "bytesWritten": markdown.len,
  }
  await respondJson(req, Http200, resp)

proc makeSaveBrief*(store: DaemonBriefStore;
                    workspaceRoot: string): HandlerProcRaw =
  let capturedStore = store
  let capturedRoot = workspaceRoot
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await saveBriefHandler(capturedStore, capturedRoot, req)

# ---------------------------------------------------------------------------
# Test-only diagnostic route — exposes a JSON dump of the in-process
# BriefIndex (``byBriefId`` ids + ``byPreview``).  Used by the
# save-brief route's tests to verify that the ``byPreview`` inverted
# map is refreshed in sync with ``byBriefId`` after a save.
#
# Gated behind ``ISONIM_REVIEW_ENABLE_DIAG_ROUTES`` so production
# daemons never expose it.  No write surface — strictly read-only.
# ---------------------------------------------------------------------------

proc briefIndexDiagHandler*(store: DaemonBriefStore;
                            req: Request) {.async, gcsafe.} =
  if getEnv("ISONIM_REVIEW_ENABLE_DIAG_ROUTES").len == 0:
    await respondError(req, Http404, "not_found")
    return
  ensureLoaded(store)
  var briefIds = newJArray()
  var byPreview = newJObject()
  {.cast(gcsafe).}:
    withLock store.lock:
      for id in store.index.byBriefId.keys:
        briefIds.add %id
      for previewId, ids in store.index.byPreview.pairs:
        var arr = newJArray()
        for id in ids: arr.add %id
        byPreview[previewId] = arr
  let resp = %* {
    "byBriefId": briefIds,
    "byPreview": byPreview,
  }
  await respondJson(req, Http200, resp)

proc makeBriefIndexDiag*(store: DaemonBriefStore): HandlerProcRaw =
  let capturedStore = store
  result = proc (req: Request): Future[void] {.async, gcsafe.} =
    await briefIndexDiagHandler(capturedStore, req)
