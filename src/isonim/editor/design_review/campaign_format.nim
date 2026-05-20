## CMP-M2 — campaign-document parser.
##
## Reads ``<project>/campaigns/<slug>.md`` files written from the template
## at ``isonim/prompts/campaign-document.template.md``.  The grammar is
## the same shape as the brief format from REV-M1 — YAML frontmatter
## delimited by ``---`` followed by free-form markdown — so we re-use
## :proc:`parseYaml` and :proc:`splitFrontmatter` from ``brief_format``.
##
## Validation here is intentionally narrow: the orchestrator and the
## daemon do the heavy lifting (does the briefId exist? does the doc sha
## match the row?).  This module extracts the fields needed to:
##
##   * decide which briefs the campaign references (``briefRefs``);
##   * propagate the numeric guards (``targetScore``, ``maxIterations``)
##     into the ``design_review.campaigns`` row;
##   * derive a deterministic ``doc_sha`` for the idempotency key;
##   * surface the markdown body verbatim so the daemon can splice it
##     into the orchestrator's first prompt.

import std/[strutils]

import ./brief_format

type
  CampaignDoc* = object
    campaignId*:        string
    schemaVersion*:     int
    briefRefs*:         seq[string]
    targetScore*:       float
    hasTargetScore*:    bool
    maxIterations*:     int
    status*:            string
    notesToOrchestrator*: string
    bodyMarkdown*:      string
    sourceFile*:        string
    title*:             string

  CampaignDocParseError* = object of CatchableError
    field*: string
    path*: string

proc raiseMissingField(field, path: string) =
  var e = newException(CampaignDocParseError,
    "campaign doc: missing required field '" & field & "' in " & path)
  e.field = field
  e.path = path
  raise e

proc raiseBadField(field, path, msg: string) =
  var e = newException(CampaignDocParseError,
    "campaign doc: bad field '" & field & "' in " & path & ": " & msg)
  e.field = field
  e.path = path
  raise e

proc scalarOr(node: YamlNode; fallback: string): string =
  if node == nil: return fallback
  if node.kind != ynkScalar: return fallback
  return node.scalar.strip()

proc parseStringSeq(node: YamlNode): seq[string] =
  if node == nil: return @[]
  if node.kind != ynkSequence: return @[]
  for it in node.items:
    if it.kind == ynkScalar and it.scalar.len > 0:
      result.add it.scalar.strip()

proc parseCampaignDoc*(filePath, raw: string): CampaignDoc =
  ## Parse the campaign doc from ``raw`` (its full file contents) and
  ## return the typed view.  ``filePath`` is kept for diagnostics + the
  ## ``sourceFile`` field.  Raises :type:`CampaignDocParseError` on
  ## structural issues.
  let (front, body) = splitFrontmatter(raw, filePath)
  if front.len == 0:
    raiseMissingField("frontmatter", filePath)
  var root: YamlNode
  try:
    root = parseYaml(front)
  except CatchableError as e:
    raiseBadField("yaml", filePath, e.msg)
  if root == nil or root.kind != ynkMapping:
    raiseBadField("frontmatter", filePath, "expected YAML mapping")

  let campaignIdNode = root.getKey("campaignId")
  let campaignId = scalarOr(campaignIdNode, "")
  if campaignId.len == 0:
    raiseMissingField("campaignId", filePath)
  result.campaignId = campaignId

  let svNode = root.getKey("schemaVersion")
  if svNode == nil:
    result.schemaVersion = 1
  elif svNode.kind == ynkScalar:
    try: result.schemaVersion = parseInt(svNode.scalar.strip())
    except ValueError:
      raiseBadField("schemaVersion", filePath,
                    "expected integer, got '" & svNode.scalar & "'")
  else:
    raiseBadField("schemaVersion", filePath, "expected scalar")

  let briefRefsNode = root.getKey("briefRefs")
  if briefRefsNode == nil:
    raiseMissingField("briefRefs", filePath)
  let refs = parseStringSeq(briefRefsNode)
  if refs.len == 0:
    raiseBadField("briefRefs", filePath,
                  "expected non-empty sequence of brief ids")
  result.briefRefs = refs

  let tsNode = root.getKey("targetScore")
  if tsNode != nil and tsNode.kind == ynkScalar and tsNode.scalar.len > 0:
    try:
      result.targetScore = parseFloat(tsNode.scalar.strip())
      result.hasTargetScore = true
    except ValueError:
      raiseBadField("targetScore", filePath,
                    "expected float, got '" & tsNode.scalar & "'")

  let miNode = root.getKey("maxIterations")
  if miNode == nil:
    result.maxIterations = 30
  elif miNode.kind == ynkScalar:
    try: result.maxIterations = parseInt(miNode.scalar.strip())
    except ValueError:
      raiseBadField("maxIterations", filePath,
                    "expected integer, got '" & miNode.scalar & "'")
    if result.maxIterations <= 0:
      raiseBadField("maxIterations", filePath,
                    "must be a positive integer (got " &
                    $result.maxIterations & ")")
  else:
    raiseBadField("maxIterations", filePath, "expected scalar integer")

  result.status = scalarOr(root.getKey("status"), "pending")

  let notesNode = root.getKey("notesToOrchestrator")
  if notesNode != nil and notesNode.kind == ynkScalar:
    result.notesToOrchestrator = notesNode.scalar

  # Title — the first ``# Title`` heading in the body, if present.
  result.title = ""
  for line in body.splitLines:
    let l = line.strip()
    if l.startsWith("# "):
      result.title = l[2 .. ^1].strip()
      break

  result.bodyMarkdown = body
  result.sourceFile = filePath

proc parseCampaignDocFile*(filePath: string): CampaignDoc =
  ## Convenience wrapper that reads ``filePath`` from disk and feeds
  ## :proc:`parseCampaignDoc`.
  let raw = readFile(filePath)
  parseCampaignDoc(filePath, raw)
