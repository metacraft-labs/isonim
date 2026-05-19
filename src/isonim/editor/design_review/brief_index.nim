## REV-M1: Brief index — deterministic walker over a project's
## ``briefs/`` directory.
##
## The walker:
##
## - Enumerates ``briefs/**/*.md`` files in a stable order (full path,
##   sorted lexicographically).
## - Parses each one with ``brief_format.parseBrief``.
## - Builds two inverted maps:
##   - ``byBriefId``: ``briefId → Brief``
##   - ``byPreview``: canonical preview-id → list of brief-ids covering it
##     (sorted alphabetically by briefId for stable ordering)
## - Records every parse error in ``errors`` instead of raising, so a
##   single broken file does not block the rest of the index.
## - Duplicate ``briefId`` excludes BOTH offending briefs from
##   ``byBriefId`` and records a ``BriefIndexError`` naming both
##   source paths.
##
## REV-M2: the filesystem walker is guarded behind ``when not defined(js)``
## so the type definitions remain importable from the JS bundle. The
## bundle uses ``brief_index_static.builtInBriefIndex()`` instead of
## running the walker at startup.

import std/tables
when not defined(js):
  import std/[os, algorithm, sequtils, strutils]
import isonim/editor/design_review/brief_format

type
  BriefIndexError* = object
    path*: string
    message*: string

  BriefIndex* = ref object
    byBriefId*: OrderedTable[string, Brief]
    byPreview*: OrderedTable[string, seq[string]]   ## previewId -> briefIds
    errors*: seq[BriefIndexError]

proc empty*(idx: BriefIndex): bool =
  ## True if the index has no successfully parsed briefs.
  idx == nil or idx.byBriefId.len == 0

when not defined(js):
  proc collectBriefFiles(briefsDir: string): seq[string] =
    if not dirExists(briefsDir):
      return @[]
    for path in walkDirRec(briefsDir, relative = false):
      if path.endsWith(".md"):
        result.add(path)
    result.sort(cmp = system.cmp)

  proc buildBriefIndex*(briefsDir: string): BriefIndex =
    ## Build a deterministic index of every brief under ``briefsDir``.
    ## Returns an empty (but non-nil) index if the directory does not
    ## exist. Never raises — parse errors land in ``result.errors``.
    result = BriefIndex(
      byBriefId: initOrderedTable[string, Brief](),
      byPreview: initOrderedTable[string, seq[string]]()
    )
    let files = collectBriefFiles(briefsDir)

    # First pass: parse every file, collect briefs + errors.
    type ParsedBrief = object
      file: string
      brief: Brief
      ok: bool
    var parsed: seq[ParsedBrief] = @[]
    for f in files:
      var pb = ParsedBrief(file: f, ok: false)
      try:
        pb.brief = parseBrief(f)
        pb.ok = true
      except BriefParseError as bpe:
        result.errors.add(BriefIndexError(path: f, message: bpe.msg))
        continue
      except IOError as ioe:
        result.errors.add(BriefIndexError(path: f, message: ioe.msg))
        continue
      except OSError as ose:
        result.errors.add(BriefIndexError(path: f, message: ose.msg))
        continue
      parsed.add(pb)

    # Detect duplicate briefIds. Group by briefId so an N-way duplicate
    # excludes all N entries.
    var byId = initOrderedTable[string, seq[ParsedBrief]]()
    for pb in parsed:
      if pb.brief.briefId notin byId:
        byId[pb.brief.briefId] = @[]
      byId[pb.brief.briefId].add(pb)

    # Determine the final accepted brief set (no duplicates).
    var accepted: seq[ParsedBrief] = @[]
    for id, group in byId.pairs:
      if group.len == 1:
        accepted.add(group[0])
      else:
        let paths = group.mapIt(it.file)
        let msg = "duplicate briefId '" & id & "' in files: " &
                  paths.join(", ")
        for pb in group:
          result.errors.add(BriefIndexError(path: pb.file, message: msg))

    # Sort accepted briefs alphabetically by briefId for deterministic
    # iteration order.
    accepted.sort do (a, b: ParsedBrief) -> int:
      cmp(a.brief.briefId, b.brief.briefId)

    for pb in accepted:
      result.byBriefId[pb.brief.briefId] = pb.brief

    # Build inverse map. Each (preview, backend) pair becomes a separate
    # canonical preview-id entry — a brief naming N backends for one
    # storyRef contributes N entries.
    type Cover = object
      previewId: string
      briefId: string
    var covers: seq[Cover] = @[]
    for pb in accepted:
      for cov in pb.brief.coversPreviews:
        for be in cov.backends:
          covers.add(Cover(
            previewId: canonicalPreviewId(cov.storyRef, be),
            briefId: pb.brief.briefId
          ))
    # Stable alphabetical ordering by (previewId, briefId).
    covers.sort do (a, b: Cover) -> int:
      let c = cmp(a.previewId, b.previewId)
      if c != 0: c else: cmp(a.briefId, b.briefId)

    for cov in covers:
      if cov.previewId notin result.byPreview:
        result.byPreview[cov.previewId] = @[]
      var lst = result.byPreview[cov.previewId]
      if cov.briefId notin lst:
        lst.add(cov.briefId)
        result.byPreview[cov.previewId] = lst
