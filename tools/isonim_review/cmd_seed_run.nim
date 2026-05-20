## Follow-up 3 — ``isonim-review seed-run`` subcommand.
##
## Ingests historical PNG screenshots into the design-review pipeline
## without going through the clean-tree gate.  The typical use case is
## reviewing the corpus we captured for M-EVP-14 (and other historical
## milestones) against current briefs / agent backends: those PNGs
## predate the design-review milestone, so there's no manifest pin to
## bind them to.
##
## Usage:
##
## .. code-block:: text
##
##   isonim-review seed-run --brief <briefId>
##     --capture web=path/to/web.png
##     --capture tui=path/to/tui.png
##     ...
##     [--viewport <label>]
##     [--manifest-hash-tag <tag>]
##     [--config <path>] [--workspace <path>] [--project <path>]
##
## Each ``--capture <backend>=<path>`` argument:
##   * Validates the PNG file exists and is a PNG (signature + IHDR).
##   * Stores the PNG bytes into the content-addressed capture store
##     under ``<store>/<sha[:2]>/<sha>.png``.
##   * Inserts a row into ``design_review.captures`` via the
##     ``record_capture`` routine, keyed by the canonical preview-id
##     for the (storyRef, backend) tuple from the brief.
##
## ``manifest_hash`` for the run is set to ``seeded:<tag>`` where
## ``<tag>`` is either the operator-supplied ``--manifest-hash-tag``
## value or, by default, an ISO 8601 UTC timestamp.  The
## ``seeded:`` prefix is the sentinel
## :const:`SeededManifestHashPrefix` that
## :proc:`isonim.editor.design_review.brief_at_revision.briefAtRevision`
## detects to fall back to reading the brief from the working tree.
##
## **Security / reproducibility caveat.**  Seeded runs are NOT
## reproducible from source: there's no manifest pin to bind them to,
## and the brief body at review time is whatever's in the working tree
## then (not what existed when the PNGs were taken).  Prefer
## ``capture`` for runs you want to re-derive from a git revision.

import std/[options, os, strformat, strutils, tables, times]

import db_connector/db_postgres

import isonim/editor/design_review/brief_at_revision
import isonim/editor/design_review/brief_format
import isonim/editor/design_review/brief_index
import isonim/editor/design_review/capture
import isonim/editor/design_review/capture_store
import isonim/editor/design_review/db
import isonim/editor/types

import ./config

type
  SeedRunOptions* = object
    briefId*: string
    captures*: seq[tuple[backend: string; path: string]]
      ## Parsed ``--capture <backend>=<path>`` pairs in input order.
    viewportLabel*: string
      ## Optional override for the viewport label recorded with each
      ## capture.  When empty, the brief's first ``captureViewports``
      ## entry is used.  This lets the operator group seeded captures
      ## under a chosen label even though no viewport sweep happened.
    manifestHashTag*: string
      ## Tag appended after ``seeded:``.  Empty → use a fresh ISO 8601
      ## UTC timestamp.
    workspaceRoot*: string
    projectPath*: string

# --------------------------------------------------------------------------- #
#  PNG validation.
# --------------------------------------------------------------------------- #

type
  SeedRunError* = object of CatchableError

const PngMagic = [byte(137), byte(80), byte(78), byte(71),
                  byte(13), byte(10), byte(26), byte(10)]

proc validatePng(path: string):
    tuple[bytes: seq[byte]; width, height: int] =
  ## Read ``path``, verify the PNG signature and IHDR chunk, return the
  ## raw bytes plus the parsed width/height.  Sufficient for the
  ## record_capture call site — we don't need to decode pixels.
  if not fileExists(path):
    raise newException(SeedRunError,
      "seed-run: PNG not found: " & path)
  let raw = readFile(path)
  if raw.len < 24:
    raise newException(SeedRunError,
      "seed-run: " & path & " is too short to be a valid PNG")
  for i in 0 ..< 8:
    if byte(raw[i]) != PngMagic[i]:
      raise newException(SeedRunError,
        "seed-run: " & path & " is not a valid PNG (bad signature)")
  # IHDR starts at byte 8: 4 bytes length (== 13), 4 bytes type ("IHDR"),
  # then 4 + 4 bytes for width/height (big-endian).
  if raw[12] != 'I' or raw[13] != 'H' or raw[14] != 'D' or raw[15] != 'R':
    raise newException(SeedRunError,
      "seed-run: " & path & " is not a valid PNG (missing IHDR)")
  let widthBE =
    (uint32(byte(raw[16])) shl 24) or
    (uint32(byte(raw[17])) shl 16) or
    (uint32(byte(raw[18])) shl 8) or
    uint32(byte(raw[19]))
  let heightBE =
    (uint32(byte(raw[20])) shl 24) or
    (uint32(byte(raw[21])) shl 16) or
    (uint32(byte(raw[22])) shl 8) or
    uint32(byte(raw[23]))
  var bytes = newSeq[byte](raw.len)
  for i in 0 ..< raw.len: bytes[i] = byte(raw[i])
  result = (bytes: bytes, width: int(widthBE), height: int(heightBE))

# --------------------------------------------------------------------------- #
#  Backend / brief matching.
# --------------------------------------------------------------------------- #

proc backendFromName(name: string): Option[PreviewBackend] =
  let s = name.toLowerAscii()
  case s
  of "web":     some(pbWeb)
  of "tui":     some(pbTui)
  of "gpui":    some(pbGpui)
  of "freya":   some(pbFreya)
  of "cocoa":   some(pbCocoa)
  of "android": some(pbAndroid)
  of "ios":     some(pbIos)
  else: none(PreviewBackend)

proc previewIdForBackend(brief: Brief; backend: PreviewBackend):
    Option[string] =
  ## Walk the brief's ``coversPreviews`` and return the canonical
  ## preview-id of the first coverage that lists ``backend``.  The
  ## seeded flow expects each backend to map to exactly one preview
  ## per brief (the historical M-EVP-14 corpus follows that contract);
  ## briefs that list multiple stories under the same backend pick the
  ## first one — that's documented on ``--capture``.
  for cov in brief.coversPreviews:
    for b in cov.backends:
      if b == backend:
        return some(canonicalPreviewId(cov.storyRef, backend))
  none(string)

proc defaultViewportLabel(brief: Brief): string =
  if brief.captureViewports.len > 0:
    return brief.captureViewports[0].label
  "default"

# --------------------------------------------------------------------------- #
#  Public entry point.
# --------------------------------------------------------------------------- #

proc resolveBriefsDir(projectPath: string): string =
  if projectPath.len == 0: return ""
  let direct = projectPath / "briefs"
  if dirExists(direct): return direct
  projectPath

proc isoTimestamp(): string =
  ## ``2026-05-19T12:30:00Z``-style UTC timestamp.  Used as the default
  ## ``manifest_hash`` tag when the operator omits ``--manifest-hash-tag``.
  let t = now().utc()
  t.format("yyyy-MM-dd'T'HH:mm:ss'Z'")

proc cmdSeedRun*(cfg: ReviewConfig; opts: SeedRunOptions): int =
  if opts.briefId.len == 0:
    stderr.writeLine("isonim-review seed-run: --brief <briefId> is required")
    return 2
  if opts.captures.len == 0:
    stderr.writeLine("isonim-review seed-run: at least one --capture " &
                     "<backend>=<path> is required")
    return 2

  let resolvedWorkspace =
    if opts.workspaceRoot.len > 0: opts.workspaceRoot
    else: cfg.workspace.root
  let resolvedProject =
    if opts.projectPath.len > 0: opts.projectPath
    else: resolvedWorkspace

  let briefsDir = resolveBriefsDir(resolvedProject)
  if briefsDir.len == 0 or not dirExists(briefsDir):
    stderr.writeLine(fmt"isonim-review seed-run: briefs directory not found: '{resolvedProject}'")
    return 2
  let idx = buildBriefIndex(briefsDir)
  if opts.briefId notin idx.byBriefId:
    stderr.writeLine(fmt"isonim-review seed-run: brief '{opts.briefId}' not in {briefsDir}")
    return 2
  let brief = idx.byBriefId[opts.briefId]

  # Parse + validate every capture BEFORE we open a run / store row, so
  # a single bad PNG path doesn't leave an orphaned run in the DB.
  type Resolved = object
    backend: PreviewBackend
    backendStr: string
    path: string
    previewId: string
    bytes: seq[byte]
    width, height: int
  var resolved: seq[Resolved] = @[]
  for cap in opts.captures:
    let beOpt = backendFromName(cap.backend)
    if beOpt.isNone:
      stderr.writeLine(fmt"isonim-review seed-run: unknown backend '{cap.backend}' " &
                       "(expected one of: web, tui, gpui, freya, cocoa, android, ios)")
      return 2
    let backend = beOpt.get
    let previewIdOpt = previewIdForBackend(brief, backend)
    if previewIdOpt.isNone:
      stderr.writeLine(fmt"isonim-review seed-run: brief '{opts.briefId}' has no " &
                       "coversPreviews entry for backend '" & cap.backend & "'")
      return 2
    let png =
      try: validatePng(cap.path)
      except SeedRunError as e:
        stderr.writeLine("isonim-review seed-run: " & e.msg)
        return 3
    resolved.add Resolved(
      backend: backend,
      backendStr: previewBackendToString(backend),
      path: cap.path,
      previewId: previewIdOpt.get,
      bytes: png.bytes,
      width: png.width,
      height: png.height)

  let viewportLabel =
    if opts.viewportLabel.len > 0: opts.viewportLabel
    else: defaultViewportLabel(brief)

  let manifestHash =
    if opts.manifestHashTag.len > 0:
      SeededManifestHashPrefix & opts.manifestHashTag
    else:
      SeededManifestHashPrefix & isoTimestamp()

  let connStr = connectionString(cfg, role = "app")
  let conn =
    try: open("", cfg.db.appUser, "", connStr)
    except DbError as e:
      stderr.writeLine("isonim-review seed-run: cannot connect to " &
                       connStr & ": " & e.msg)
      return 3
  let db = ReviewDb(conn: conn)
  defer: db.close()

  let store = newCaptureStore(cfg.store.path)
  let runId = startRun(db, opts.briefId, manifestHash,
                       getEnv("USER", "anonymous"))
  echo fmt"seed-run: run started ({runId})"

  for r in resolved:
    let stored = store.put(r.bytes)
    discard recordCapture(db, runId, r.previewId, r.backendStr,
                          viewportLabel, stored.sha256, stored.path,
                          r.width, r.height)
    echo fmt"seed-run: recorded {r.previewId} ({r.width}x{r.height}, " &
         fmt"sha={stored.sha256[0..11]}…, src={r.path})"

  finishCaptures(db, runId)
  echo fmt"seed-run: complete (run_id={runId})"
  # Final stdout line — exactly the run id — so shell wrappers can
  # ``RUN_ID=$(isonim-review seed-run ...)`` it.
  echo runId
  return 0
