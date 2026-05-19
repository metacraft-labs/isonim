## REV-M5 — ``isonim-review capture`` subcommand.
##
## Wires the orchestration in
## ``isonim/editor/design_review/capture.nim`` to a CLI surface:
##
##   isonim-review capture --brief <briefId> [--viewport <label>]
##                         [--bridge <ws://host:port>]
##                         [--workspace <path>]
##                         [--project <path>] [--config <path>]
##
## The default ``--bridge`` is ``ws://127.0.0.1:8093`` to match what
## the milestone document specifies; the bridge port is the single
## moving piece between dev setups.  ``--workspace`` defaults to the
## review config's ``workspace.root`` (which itself defaults to
## ``~/metacraft``).
##
## On dirty-workspace the command exits 2 with a stderr summary that
## names every offending file path.  This mirrors the structured
## ``DirtyRepoReport`` so reviewers can act without reading the
## stack trace.

import std/[options, os, strformat, strutils, tables]

import db_connector/db_postgres

import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/capture
import isonim/editor/design_review/clean_tree
import isonim/editor/design_review/db

import ./config

const DefaultBridgeUrl* = "ws://127.0.0.1:8093"
  ## Bridge URL handed to ``runCapture`` when ``--bridge`` is supplied
  ## *with an empty value*.  When the user passes ``--bridge <url>``
  ## (any non-empty URL) the capture pipeline goes through that single
  ## fixed bridge for every backend — the original REV-M5 contract.
  ## When ``--bridge`` is *omitted entirely*, the pipeline spawns a
  ## per-backend launcher binary (``isonim-examples-<backend>``) via
  ## ``backend_launcher.launchBackend`` for each (preview, backend)
  ## tuple — the REV-M5 follow-up behaviour this CLI flag wires up.

proc resolveBriefsDir(projectPath: string): string =
  if projectPath.len == 0: return ""
  let direct = projectPath / "briefs"
  if dirExists(direct): return direct
  projectPath

proc reasonLabel(r: DirtyRepoReason): string =
  case r
  of drUncommitted: "uncommitted changes"
  of drUntracked:   "untracked files"
  of drUnpinnedHead: "HEAD not on manifest pin"
  of drManifestUnreadable: "manifest unreadable"

proc formatDirty(report: DirtyRepoReport): string =
  result = report.repoPath & ": " & reasonLabel(report.reason)
  if report.files.len > 0:
    result.add " ("
    result.add report.files.join(", ")
    result.add ")"
  if report.reason == drUnpinnedHead:
    result.add fmt" [HEAD={report.headSha}, expected={report.expectedPin}]"

proc stdoutReporter*(ev: CaptureProgressEvent) {.gcsafe.} =
  case ev.kind
  of cekStartingRun:
    echo fmt"capture: run started ({ev.runId})"
  of cekCapturingPreview:
    echo fmt"capture: [{ev.capturesDone + 1}/{ev.capturesTotal}] {ev.previewId}"
  of cekCaptureRecorded:
    echo fmt"capture: recorded {ev.previewId}"
  of cekFinishingRun:
    echo fmt"capture: finishing ({ev.capturesDone}/{ev.capturesTotal})"

proc parseBackendFilter(spec: string): seq[PreviewBackend] =
  ## Decode the ``--backends web,tui,gpui`` flag.  Empty string → no
  ## filter.  Unknown ids raise — better to fail loudly than silently
  ## drop a backend the user typed.
  result = @[]
  if spec.len == 0: return
  for raw in spec.split(','):
    let s = raw.strip()
    if s.len == 0: continue
    case s
    of "web":     result.add pbWeb
    of "tui":     result.add pbTui
    of "gpui":    result.add pbGpui
    of "freya":   result.add pbFreya
    of "cocoa":   result.add pbCocoa
    of "android": result.add pbAndroid
    of "ios":     result.add pbIos
    else:
      raise newException(ValueError,
        "unknown backend in --backends list: " & s)

proc cmdCapture*(cfg: ReviewConfig;
                 briefId, viewport, bridgeUrl, workspaceRoot,
                 projectPath, backendBinaryDir,
                 backendsFilter: string): int =
  ## Top-level dispatch — returns a process exit code.
  if briefId.len == 0:
    stderr.writeLine("isonim-review capture: --brief <briefId> is required")
    return 2

  let resolvedWorkspace =
    if workspaceRoot.len > 0: workspaceRoot
    else: cfg.workspace.root
  let resolvedProject =
    if projectPath.len > 0: projectPath
    else: resolvedWorkspace

  # When ``--bridge`` is passed (any URL — empty included) we honour
  # the legacy single-fixed-bridge contract.  When ``--bridge`` is
  # *not* passed we route to the per-backend launcher path.  ``cfg``
  # currently has no equivalent of ``bridgeUrl``, so the distinction
  # rests purely on whether the CLI flag was present — main.nim
  # forwards an empty string when absent.
  let useLauncher = (bridgeUrl.len == 0)
  let resolvedBridge =
    if useLauncher: ""
    else: bridgeUrl

  let resolvedBackendDir =
    if backendBinaryDir.len > 0: backendBinaryDir
    else: cfg.backend.binaryDir

  let backendFilter =
    try: parseBackendFilter(backendsFilter)
    except ValueError as e:
      stderr.writeLine("isonim-review capture: " & e.msg)
      return 2

  let briefsDir = resolveBriefsDir(resolvedProject)
  if briefsDir.len == 0 or not dirExists(briefsDir):
    stderr.writeLine(fmt"isonim-review capture: briefs directory not found: '{resolvedProject}'")
    return 2
  let idx = buildBriefIndex(briefsDir)
  let resolver = proc(id: string): Option[Brief] {.gcsafe.} =
    if id in idx.byBriefId: some(idx.byBriefId[id])
    else: none(Brief)

  if briefId notin idx.byBriefId:
    stderr.writeLine(fmt"isonim-review capture: brief '{briefId}' not in {briefsDir}")
    return 2

  let opts = CaptureOptions(
    bridgeUrl: resolvedBridge,
    briefIndex: resolver,
    viewportFilter: viewport,
    backendBinaryDir: resolvedBackendDir,
    backendFilter: backendFilter,
  )

  let connStr = connectionString(cfg, role = "app")
  let conn =
    try: open("", cfg.db.appUser, "", connStr)
    except DbError as e:
      stderr.writeLine("isonim-review capture: cannot connect to " &
                       connStr & ": " & e.msg)
      return 3
  let db = ReviewDb(conn: conn)
  defer: db.close()

  try:
    let runId = runCapture(
      briefId = briefId,
      workspaceRoot = resolvedWorkspace,
      bridgeUrl = resolvedBridge,
      storePath = cfg.store.path,
      db = db,
      reporter = stdoutReporter,
      opts = opts)
    echo fmt"capture: complete (run_id={runId})"
    return 0
  except WorkspaceDirtyError as e:
    stderr.writeLine("isonim-review capture: workspace is not clean:")
    for r in e.dirty:
      stderr.writeLine("  " & formatDirty(r))
    return 3
  except CaptureError as e:
    stderr.writeLine("isonim-review capture: " & e.msg)
    return 4
