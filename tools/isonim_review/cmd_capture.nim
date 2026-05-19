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

proc cmdCapture*(cfg: ReviewConfig;
                 briefId, viewport, bridgeUrl, workspaceRoot,
                 projectPath: string): int =
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
  let resolvedBridge =
    if bridgeUrl.len > 0: bridgeUrl else: DefaultBridgeUrl

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
