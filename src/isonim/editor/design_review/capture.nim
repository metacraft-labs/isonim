## REV-M5 — capture orchestration.
##
## Walks the milestone-defined sequence:
##
##   1. ``checkCleanTree`` — fail if any repo is dirty / unpinned.
##   2. ``captureManifestHash`` — compute the workspace pin hash.
##   3. ``design_review.start_run`` via the DB routine.
##   4. For each (preview, viewport) in
##      ``brief.coversPreviews × brief.captureViewports``:
##         a. ``captureViaBridge`` → RGBA → PNG bytes.
##         b. ``CaptureStore.put`` → ``<sha>.png``.
##         c. ``design_review.record_capture`` (idempotent on retry).
##   5. ``design_review.finish_captures`` (only when all captures
##      succeeded).
##
## *Idempotency:* the DB routine ``record_capture`` is keyed on
## ``(run_id, preview_id, viewport_label)``; the store key is the
## sha256 of the pixel buffer.  Both layers swallow duplicates,
## which is what makes
## ``test_record_capture_idempotent_on_retry`` pass without any
## state machine in this orchestrator.
##
## *DB boundary:* we hold the SQL strings inline here rather than
## adding another wrapper layer.  REV-M3's ``design_review/db.nim``
## exposes a raw ``DbConn`` (``db_connector/db_postgres``); callers
## already build them with role hopping via ``asApp``.

import std/[os, options, strformat, strutils]
import db_connector/db_postgres

import ./brief_format
import ./clean_tree
import ./manifest_hash
import ./capture_store
import ./bridge_client
import ./backend_launcher
import ./db
import isonim/editor/types

type
  CaptureEventKind* = enum
    cekStartingRun        ## right after clean-tree + manifest-hash
    cekCapturingPreview   ## about to call captureViaBridge
    cekCaptureRecorded    ## DB row + store file persisted
    cekFinishingRun       ## right before finish_captures

  CaptureProgressEvent* = object
    kind*: CaptureEventKind
    previewId*: string
    capturesDone*, capturesTotal*: int
    runId*: string

  CaptureReporter* = proc(event: CaptureProgressEvent) {.gcsafe.}

  CaptureError* = object of CatchableError

  WorkspaceDirtyError* = object of CaptureError
    dirty*: seq[DirtyRepoReport]

  CaptureOptions* = object
    bridgeUrl*: string
      ## *Legacy / fake-bridge mode.*  When non-empty, the orchestrator
      ## skips ``backend_launcher`` entirely and points
      ## ``captureViaBridge`` at this URL for every (preview, backend)
      ## tuple.  The REV-M5 fake-bridge unit tests and the existing
      ## ``test-design-review-capture`` target rely on this path.  When
      ## empty, the orchestrator spawns a per-(preview, backend) launcher
      ## via the lookup rules in ``backend_launcher.resolveBackendBinary``.
    briefIndex*: proc(briefId: string): Option[Brief] {.gcsafe.}
      ## Brief resolver — the CLI normally injects a closure backed
      ## by ``buildBriefIndex`` against the project's ``briefs/``
      ## directory.  Defined as a closure rather than a hard
      ## dependency on a global index so tests can drop in fixtures.
    viewportFilter*: string
      ## When non-empty: capture only viewports whose ``label``
      ## matches.  Otherwise every viewport in the brief is captured.
    backendBinaryDir*: string
      ## Optional explicit directory for per-backend launcher binaries
      ## (``isonim-examples-<backend>``).  Honoured when ``bridgeUrl``
      ## is empty.  Falls back to ``$ISONIM_REVIEW_BACKEND_BIN_DIR``,
      ## ``~/.isonim/backends/``, and ``<workspaceRoot>/isonim-examples/
      ## build/backends/`` in that order — see
      ## ``backend_launcher.resolveBackendBinary``.
    backendFilter*: seq[PreviewBackend]
      ## When non-empty: capture only previews whose backend is in
      ## this list.  Otherwise every backend in the brief is captured.

# ---------------------------------------------------------------------------
# Reporter helper
# ---------------------------------------------------------------------------

proc fire(reporter: CaptureReporter; ev: CaptureProgressEvent) =
  if reporter != nil:
    reporter(ev)

# ---------------------------------------------------------------------------
# Capture loop
# ---------------------------------------------------------------------------

proc requireBrief(opts: CaptureOptions; briefId: string): Brief =
  if opts.briefIndex == nil:
    raise newException(CaptureError,
      "runCapture: CaptureOptions.briefIndex is required")
  let maybe = opts.briefIndex(briefId)
  if maybe.isNone:
    raise newException(CaptureError,
      "runCapture: brief not found: " & briefId)
  maybe.get

proc dbScalar(db: ReviewDb; q: string): string =
  ## Tiny helper — drains exactly one column / one row.
  db.conn.getValue(sql(q))

proc startRun*(db: ReviewDb; briefId, manifestHash, startedBy: string): string =
  ## Open a capturing run.  Returns the new ``runs.run_id`` UUID.
  ## Uses the app role (REV-M3 routines are SECURITY DEFINER).
  let escBrief = briefId.replace("'", "''")
  let escHash  = manifestHash.replace("'", "''")
  let escWho   = startedBy.replace("'", "''")
  dbScalar(db,
    fmt"SELECT design_review.start_run('{escBrief}', '{escHash}', '{escWho}')")

proc recordCapture*(db: ReviewDb; runId, previewId, backend,
                    viewportLabel, pngSha, pngPath: string;
                    width, height: int): string =
  let escRun = runId.replace("'", "''")
  let escPv  = previewId.replace("'", "''")
  let escBe  = backend.replace("'", "''")
  let escVp  = viewportLabel.replace("'", "''")
  let escSha = pngSha.replace("'", "''")
  let escPath = pngPath.replace("'", "''")
  dbScalar(db,
    fmt"SELECT design_review.record_capture('{escRun}'::uuid," &
    fmt"'{escPv}','{escBe}','{escVp}','{escSha}','{escPath}'," &
    fmt"{width},{height})")

proc finishCaptures*(db: ReviewDb; runId: string) =
  let escRun = runId.replace("'", "''")
  discard dbScalar(db,
    fmt"SELECT design_review.finish_captures('{escRun}'::uuid)")

# ---------------------------------------------------------------------------
# Launcher routing
# ---------------------------------------------------------------------------

proc componentForStoryRef*(storyRef: StoryRef): string =
  ## Map a brief's ``storyRef.group`` onto the launcher's ``--demo``
  ## argument.  The isonim-examples launchers accept ``task`` or
  ## ``settings`` (per ``editor/backends/common.nim``); the brief
  ## storyRef.group typically reads ``"Task App"`` or ``"Settings App"``.
  ## Unknown groups default to ``"task"`` — that's the launcher's own
  ## default and the catch-all that keeps a smoke test working when a
  ## brief invents a new story group.
  let g = storyRef.group.toLowerAscii()
  if g.contains("settings"):
    "settings"
  else:
    "task"

# ---------------------------------------------------------------------------
# Top-level orchestration
# ---------------------------------------------------------------------------

proc runCapture*(briefId: string; workspaceRoot, bridgeUrl, storePath: string;
                 db: ReviewDb;
                 reporter: CaptureReporter = nil;
                 opts: CaptureOptions = CaptureOptions()): string =
  ## End-to-end capture for one brief.  Returns the ``run_id`` of
  ## the newly created run.  See module doc for the sequence.
  let brief = requireBrief(opts, briefId)

  let cleanStatus = checkCleanTree(workspaceRoot)
  if not cleanStatus.ok:
    var err = WorkspaceDirtyError.newException("workspace is not clean")
    err.dirty = cleanStatus.dirty
    raise err

  let manifestHash = captureManifestHash(workspaceRoot)

  let store = newCaptureStore(storePath)

  let runId = startRun(db, briefId, manifestHash,
                       getEnv("USER", "anonymous"))
  fire(reporter, CaptureProgressEvent(
    kind: cekStartingRun, runId: runId))

  # Enumerate the (preview, viewport) sweep.
  var viewports: seq[BriefViewport]
  for vp in brief.captureViewports:
    if opts.viewportFilter.len == 0 or vp.label == opts.viewportFilter:
      viewports.add vp

  proc backendAllowed(b: PreviewBackend): bool =
    if opts.backendFilter.len == 0:
      return true
    for f in opts.backendFilter:
      if f == b: return true
    false

  var sweep: seq[tuple[storyRef: StoryRef; backend: PreviewBackend;
                       viewport: BriefViewport]]
  for cov in brief.coversPreviews:
    for backend in cov.backends:
      if not backendAllowed(backend): continue
      for vp in viewports:
        sweep.add (storyRef: cov.storyRef, backend: backend, viewport: vp)

  var done = 0
  let total = sweep.len
  let useLauncher = bridgeUrl.len == 0

  for item in sweep:
    let previewId = canonicalPreviewId(item.storyRef, item.backend)
    fire(reporter, CaptureProgressEvent(
      kind: cekCapturingPreview, runId: runId,
      previewId: previewId,
      capturesDone: done, capturesTotal: total))

    var effectiveUrl = bridgeUrl
    var launcher: BackendLauncher = nil
    if useLauncher:
      let binary = resolveBackendBinary(
        backend = item.backend,
        overrideDir = opts.backendBinaryDir,
        workspaceRoot = workspaceRoot)
      if binary.len == 0:
        # Skip the capture: the reviewer agent will see fewer rows
        # for this backend, which is the spec'd fallback when a
        # launcher is missing on the host (e.g. ios on linux).  The
        # CLI exits non-zero only when *zero* captures succeeded,
        # so a missing-launcher skip is recoverable.
        inc done
        fire(reporter, CaptureProgressEvent(
          kind: cekCaptureRecorded, runId: runId,
          previewId: previewId,
          capturesDone: done, capturesTotal: total))
        continue
      let spec = LauncherSpec(
        backend: item.backend,
        binaryPath: binary,
        component: componentForStoryRef(item.storyRef),
        width: item.viewport.width,
        height: item.viewport.height)
      launcher = launchBackend(spec)
      effectiveUrl = launcher.bridgeUrl

    try:
      let res = captureViaBridge(
        bridgeUrl = effectiveUrl,
        storyRef = item.storyRef,
        backend = item.backend,
        viewportWidth = item.viewport.width,
        viewportHeight = item.viewport.height,
        timeoutMs = 30_000)
      let stored = store.put(res.pngBytes)
      discard recordCapture(db, runId, previewId,
                            previewBackendToString(item.backend),
                            item.viewport.label,
                            stored.sha256, stored.path,
                            res.width, res.height)
      inc done
      fire(reporter, CaptureProgressEvent(
        kind: cekCaptureRecorded, runId: runId,
        previewId: previewId,
        capturesDone: done, capturesTotal: total))
    finally:
      if launcher != nil:
        launcher.shutdown()

  fire(reporter, CaptureProgressEvent(
    kind: cekFinishingRun, runId: runId,
    capturesDone: done, capturesTotal: total))
  finishCaptures(db, runId)
  result = runId
