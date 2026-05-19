## REV-M6 — reviewer output schema parser.
##
## A reviewer agent's output is a single markdown file with YAML
## frontmatter on top.  The frontmatter is the typed projection the
## database stores under ``agent_reports.parsed_scores`` (JSONB); the
## markdown body is rendered verbatim for human consumption.
##
## See ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md`` §
## "Reviewer Output Schema" and § "``parsed_scores`` Shape" for the
## contract this parser enforces.
##
## The YAML parser is reused verbatim from ``brief_format.nim`` (REV-M1)
## — same dependency-discipline as the brief parser, no extra YAML deps.
##
## Validation rules:
##
##   * ``reviewerSchemaVersion`` must equal 1 (the only version
##     defined so far).
##   * Every scored preview id must appear in the brief's
##     ``coversPreviews`` (after the canonical-preview-id projection).
##   * Every preview score must list exactly the dimensions declared
##     by the brief's ``scoringDimensions`` and the score must lie
##     within the dimension's ``scaleMin`` .. ``scaleMax``.
##   * Defect severity is normalised to lower-case ``blocker | warn |
##     nit``; any other value raises ``ReviewerOutputError``.

import std/[json, strformat, strutils, tables, times, sets]

import ./brief_format

type
  ReviewerDefect* = object
    id*: string
    summary*: string
    severity*: string   ## 'blocker' | 'warn' | 'nit' (lower-cased on parse)
    evidence*: string

  ReviewerPreviewScore* = object
    previewId*: string
    scores*: Table[string, int]
    status*: string     ## 'pass' | 'warn' | 'fail'
    defects*: seq[ReviewerDefect]

  ReviewerOutput* = object
    reviewerSchemaVersion*: int
    briefId*: string
    runId*: string
    agentName*: string
    agentVersion*: string
    manifestHash*: string
    capturedAt*: DateTime
    overall*: tuple[score: float; status: string]
    previews*: seq[ReviewerPreviewScore]
    notes*: string
    bodyMarkdown*: string

  ReviewerOutputError* = object of CatchableError
  UnknownPreviewError* = object of ReviewerOutputError
  ScoreOutOfRangeError* = object of ReviewerOutputError
  MissingScoreError* = object of ReviewerOutputError

const ValidSeverities = ["blocker", "warn", "nit"]
const ValidStatuses = ["pass", "warn", "fail"]
const ValidOverallStatuses = ["pass", "warn", "fail"]

# --------------------------------------------------------------------------- #
#  YAML primitive helpers (thin wrappers over the brief_format YAML AST).
# --------------------------------------------------------------------------- #

proc requireMapping(n: YamlNode; field, path: string): YamlNode =
  if n == nil or n.kind != ynkMapping:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: expected mapping for '{field}' in {path}")
  return n

proc requireScalar(n: YamlNode; field, path: string): string =
  if n == nil:
    raise newException(MissingScoreError,
      fmt"reviewer output: missing required field '{field}' in {path}")
  if n.kind != ynkScalar:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: expected scalar for '{field}' in {path}")
  return n.scalar.strip()

proc requireInt(n: YamlNode; field, path: string): int =
  let s = requireScalar(n, field, path)
  try:
    return parseInt(s)
  except ValueError:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: expected int for '{field}' in {path}: got '{s}'")

proc requireFloat(n: YamlNode; field, path: string): float =
  let s = requireScalar(n, field, path)
  try:
    return parseFloat(s)
  except ValueError:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: expected float for '{field}' in {path}: got '{s}'")

proc optScalar(n: YamlNode): string =
  if n != nil and n.kind == ynkScalar: n.scalar.strip()
  else: ""

# --------------------------------------------------------------------------- #
#  Brief-driven validation tables.
# --------------------------------------------------------------------------- #

proc canonicalPreviewIdsFor(brief: Brief): HashSet[string] =
  result = initHashSet[string]()
  for cov in brief.coversPreviews:
    for backend in cov.backends:
      result.incl(canonicalPreviewId(cov.storyRef, backend))

proc dimensionsByIdFor(brief: Brief):
    Table[string, BriefScoringDimension] =
  result = initTable[string, BriefScoringDimension]()
  for d in brief.scoringDimensions:
    result[d.id] = d

# --------------------------------------------------------------------------- #
#  Frontmatter → ReviewerOutput.
# --------------------------------------------------------------------------- #

proc decodeOverall(node: YamlNode; path: string):
    tuple[score: float; status: string] =
  let m = requireMapping(node, "overall", path)
  if not m.hasKey("score"):
    raise newException(MissingScoreError,
      fmt"reviewer output: missing required field 'overall.score' in {path}")
  result.score = requireFloat(m.getKey("score"), "overall.score", path)
  let st = requireScalar(m.getKey("status"), "overall.status", path).toLowerAscii
  if st notin ValidOverallStatuses:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: 'overall.status' must be one of pass|warn|fail; got '{st}' in {path}")
  result.status = st

proc decodeDefect(node: YamlNode; path: string): ReviewerDefect =
  let m = requireMapping(node, "previews[].defects[]", path)
  result.id      = requireScalar(m.getKey("id"), "defects[].id", path)
  result.summary = requireScalar(m.getKey("summary"), "defects[].summary", path)
  let rawSeverity = requireScalar(m.getKey("severity"), "defects[].severity", path)
  let sev = rawSeverity.toLowerAscii
  if sev notin ValidSeverities:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: defect severity must be one of blocker|warn|nit; got '{rawSeverity}' in {path}")
  result.severity = sev
  result.evidence = optScalar(m.getKey("evidence"))

proc decodeScoresMapping(node: YamlNode; previewId, path: string;
                         dimsById: Table[string, BriefScoringDimension]):
    Table[string, int] =
  result = initTable[string, int]()
  let m = requireMapping(node, "previews." & previewId & ".scores", path)
  for (k, v) in m.pairs:
    if k notin dimsById:
      raise newException(ReviewerOutputError,
        fmt"reviewer output: unknown scoring dimension '{k}' for preview '{previewId}' in {path}")
    let dim = dimsById[k]
    let s = requireInt(v, "scores." & k, path)
    if s < dim.scaleMin or s > dim.scaleMax:
      var e = newException(ScoreOutOfRangeError,
        fmt"reviewer output: scores.{k}={s} for preview '{previewId}' " &
        fmt"is outside the brief's scale [{dim.scaleMin}..{dim.scaleMax}] " &
        fmt"(actualValue={s}) in {path}")
      raise e
    result[k] = s

  # Required-dimension check: every dimension in the brief must be scored.
  for dimId in dimsById.keys:
    if dimId notin result:
      raise newException(MissingScoreError,
        fmt"reviewer output: missing required score '{dimId}' for preview '{previewId}' in {path}")

proc decodePreviews(node: YamlNode; path: string; brief: Brief):
    seq[ReviewerPreviewScore] =
  result = @[]
  let m = requireMapping(node, "previews", path)
  let allowedIds = canonicalPreviewIdsFor(brief)
  let dimsById = dimensionsByIdFor(brief)
  for (previewId, v) in m.pairs:
    if previewId notin allowedIds:
      raise newException(UnknownPreviewError,
        fmt"reviewer output: preview '{previewId}' is not in brief.coversPreviews in {path}")
    let pm = requireMapping(v, "previews." & previewId, path)
    var p: ReviewerPreviewScore
    p.previewId = previewId
    p.scores = decodeScoresMapping(pm.getKey("scores"), previewId, path, dimsById)
    let st = requireScalar(pm.getKey("status"), "previews." & previewId & ".status", path).toLowerAscii
    if st notin ValidStatuses:
      raise newException(ReviewerOutputError,
        fmt"reviewer output: previews.{previewId}.status must be one of pass|warn|fail; got '{st}' in {path}")
    p.status = st
    let defectsNode = pm.getKey("defects")
    if defectsNode != nil:
      if defectsNode.kind != ynkSequence:
        raise newException(ReviewerOutputError,
          fmt"reviewer output: previews.{previewId}.defects must be a sequence in {path}")
      for d in defectsNode.items:
        p.defects.add(decodeDefect(d, path))
    result.add(p)

proc parseCapturedAt(raw: string; path: string): DateTime =
  ## Accepts ISO 8601 with trailing ``Z`` (UTC) or ``+00:00``.  Bombs
  ## loudly otherwise — reviewer outputs are machine-generated.
  let s = raw.strip()
  if s.len == 0:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: 'capturedAt' must be a non-empty ISO 8601 timestamp in {path}")
  try:
    return parse(s, "yyyy-MM-dd'T'HH:mm:ss'Z'", utc())
  except TimeParseError:
    discard
  try:
    return parse(s, "yyyy-MM-dd'T'HH:mm:sszzz")
  except TimeParseError:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: 'capturedAt' not an ISO 8601 timestamp ('{s}') in {path}")

proc parseReviewerOutput*(filePath: string; brief: Brief): ReviewerOutput =
  ## Parse a reviewer-output markdown file against the supplied brief.
  ## Raises one of the ``ReviewerOutputError`` subclasses on contract
  ## violations.
  let raw = readFile(filePath)
  let (front, body) = splitFrontmatter(raw, filePath)
  if front.len == 0:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: no YAML frontmatter found in {filePath}")
  var root: YamlNode
  try:
    root = parseYaml(front)
  except CatchableError as ce:
    raise newException(ReviewerOutputError,
      "reviewer output: malformed YAML in " & filePath & ": " & ce.msg)
  if root == nil or root.kind != ynkMapping:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: frontmatter must be a mapping in {filePath}")

  result.bodyMarkdown = body

  # Schema version (default 1; reject any other value loudly).
  result.reviewerSchemaVersion =
    if root.hasKey("reviewerSchemaVersion"):
      requireInt(root.getKey("reviewerSchemaVersion"),
                 "reviewerSchemaVersion", filePath)
    else: 1
  if result.reviewerSchemaVersion != 1:
    raise newException(ReviewerOutputError,
      fmt"reviewer output: unsupported reviewerSchemaVersion " &
      fmt"{result.reviewerSchemaVersion} (only 1 is defined) in {filePath}")

  result.briefId      = requireScalar(root.getKey("briefId"), "briefId", filePath)
  result.runId        = requireScalar(root.getKey("runId"), "runId", filePath)
  result.agentName    = requireScalar(root.getKey("agentName"), "agentName", filePath)
  result.agentVersion = requireScalar(root.getKey("agentVersion"), "agentVersion", filePath)
  result.manifestHash = requireScalar(root.getKey("manifestHash"), "manifestHash", filePath)

  let capturedAtRaw = requireScalar(root.getKey("capturedAt"), "capturedAt", filePath)
  result.capturedAt  = parseCapturedAt(capturedAtRaw, filePath)

  if not root.hasKey("overall"):
    raise newException(MissingScoreError,
      fmt"reviewer output: missing required field 'overall' in {filePath}")
  result.overall = decodeOverall(root.getKey("overall"), filePath)

  if not root.hasKey("previews"):
    raise newException(MissingScoreError,
      fmt"reviewer output: missing required field 'previews' in {filePath}")
  result.previews = decodePreviews(root.getKey("previews"), filePath, brief)

  let notesNode = root.getKey("notes")
  if notesNode != nil:
    result.notes = optScalar(notesNode)

# --------------------------------------------------------------------------- #
#  JSONB projection.
# --------------------------------------------------------------------------- #

proc toParsedScoresJsonb*(output: ReviewerOutput): JsonNode =
  ## Project a parsed ``ReviewerOutput`` into the JSONB shape stored under
  ## ``design_review.agent_reports.parsed_scores``.  Mirrors the spec's
  ## documented contract byte-for-byte (modulo JSON object key order,
  ## which JSONB itself does not guarantee).
  result = newJObject()
  result["schemaVersion"] = newJInt(output.reviewerSchemaVersion)

  let overall = newJObject()
  overall["score"]  = newJFloat(output.overall.score)
  overall["status"] = newJString(output.overall.status)
  result["overall"] = overall

  let previews = newJObject()
  for p in output.previews:
    let entry = newJObject()
    let scores = newJObject()
    # Emit scores in the brief-declared order would require the brief; we
    # use the insertion order from parse (which mirrors the source file).
    for k, v in p.scores.pairs:
      scores[k] = newJInt(v)
    entry["scores"] = scores
    entry["status"] = newJString(p.status)
    let defects = newJArray()
    for d in p.defects:
      let dn = newJObject()
      dn["id"]       = newJString(d.id)
      dn["summary"]  = newJString(d.summary)
      dn["severity"] = newJString(d.severity)
      if d.evidence.len > 0:
        dn["evidence"] = newJString(d.evidence)
      defects.add(dn)
    entry["defects"] = defects
    previews[p.previewId] = entry
  result["previews"] = previews

  result["notes"] = newJString(output.notes)
