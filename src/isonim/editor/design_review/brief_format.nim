## REV-M1: Brief frontmatter parser.
##
## Brief files live at `<project-repo>/briefs/<kind>/<slug>.md`. They are
## markdown files with a YAML frontmatter block delimited by `---`. The
## frontmatter describes typed metadata (which previews the brief covers,
## what viewports to capture at, scoring dimensions, etc.); the body is
## free-form prose for human + AI reviewers.
##
## This module parses one brief file at a time. The directory walker that
## indexes a whole project lives in ``brief_index.nim``.
##
## The parser is intentionally NOT a full YAML implementation. The brief
## frontmatter grammar is constrained (the spec under
## ``codetracer-specs/Front-Ends/IsoNim/isonim-editor.md`` § "Brief File
## Format" defines the exact shape), so this module recognises only the
## subset of YAML that brief files are allowed to use:
##
## - scalar key/value pairs (``key: value``)
## - block sequences (``- ...`` under a key)
## - flow-style sequences (``[a, b, c]``)
## - flow-style mappings (``{ k: v, k2: v2 }``)
## - nested objects via block-style or flow-style
##
## Unknown top-level keys are preserved verbatim in ``Brief.extra`` (the
## forward-compatibility invariant required by the milestone).

import std/[tables, strutils, strformat, os, sequtils, algorithm]
import isonim/editor/types

export types.StoryRef, types.StoryKind, types.PreviewBackend

type
  BriefKind* = enum
    bkRender, bkInteraction, bkAccessibility, bkCopy, bkChrome,
    bkComponent, bkFoundation, bkPattern, bkVectorSymbol, bkGuideline
      ## ``bkComponent`` … ``bkGuideline`` were added post-REV-M10 so the
      ## design-review database can carry starter briefs for every story
      ## kind in ``stories.nim``. The directory-vs-kind validation
      ## (``parseBrief``) treats each new kind the same way it treats the
      ## original five — the brief must live in a directory named after
      ## the kind (``briefs/component/foo.md`` etc.).

  BriefViewport* = object
    width*, height*: int
    label*: string

  BriefScoringDimension* = object
    id*: string
    label*: string
    weight*: float          ## sum across dimensions must equal 1.0
    scaleMin*, scaleMax*: int

  BriefPreviewCoverage* = object
    storyRef*: StoryRef
    backends*: seq[PreviewBackend]

  Brief* = object
    briefId*: string
    schemaVersion*: int
    kind*: BriefKind
    title*: string
    coversPreviews*: seq[BriefPreviewCoverage]
    captureViewports*: seq[BriefViewport]
    reviewerSchemaVersion*: int
    scoringDimensions*: seq[BriefScoringDimension]
    relatedBriefs*: seq[string]
    extra*: Table[string, string]   ## unknown frontmatter keys preserved verbatim
    bodyMarkdown*: string           ## everything after the second '---'
    sourceFile*: string

  BriefParseError* = object of CatchableError
    field*: string
    path*: string
  BriefKindMismatchError* = object of BriefParseError
  UnknownBackendError*    = object of BriefParseError
  ScoringWeightSumError*  = object of BriefParseError
    actualSum*: float
  MissingRequiredFieldError* = object of BriefParseError
  DuplicateBriefIdError*  = object of BriefParseError

# --------------------------------------------------------------------------- #
#  Public helpers — preview_id canonicalisation
# --------------------------------------------------------------------------- #

const PreviewIdReserved = {'/', '@', '#', '%'}

proc encodePreviewSegment(s: string): string =
  ## URL-encode characters reserved in the canonical preview-id form
  ## (``/``, ``@``, ``#``) plus ``%`` (escape character) so the encoding
  ## is invertible. Other characters (including unicode) pass through
  ## unchanged — the canonical form is byte-for-byte stable.
  result = newStringOfCap(s.len)
  for ch in s:
    if ch in PreviewIdReserved:
      result.add('%')
      result.add(toHex(ord(ch).int, 2))
    else:
      result.add(ch)

proc decodePreviewSegment(s: string): string =
  ## Inverse of `encodePreviewSegment`. Tolerates lowercase or uppercase
  ## hex digits.
  result = newStringOfCap(s.len)
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 < s.len:
      let hex = s[i+1 .. i+2]
      try:
        result.add(chr(parseHexInt(hex)))
        inc i, 3
      except ValueError:
        result.add(s[i])
        inc i
    else:
      result.add(s[i])
      inc i

proc storyKindFromCanonicalString(s: string): StoryKind =
  case s.toLowerAscii()
  of "foundation": skFoundation
  of "component":  skComponent
  of "pattern":    skPattern
  of "page":       skPage
  of "flow":       skFlow
  of "guideline":  skGuideline
  of "vectorsymbol", "vector_symbol", "vector-symbol":
    skVectorSymbol
  else:
    raise newException(ValueError, "unknown story kind: " & s)

proc storyKindCanonicalString(k: StoryKind): string =
  case k
  of skFoundation:   "foundation"
  of skComponent:    "component"
  of skPattern:      "pattern"
  of skPage:         "page"
  of skFlow:         "flow"
  of skGuideline:    "guideline"
  of skVectorSymbol: "vectorsymbol"

proc previewBackendFromString(s: string): PreviewBackend =
  case s.toLowerAscii()
  of "web":     pbWeb
  of "tui":     pbTui
  of "gpui":    pbGpui
  of "freya":   pbFreya
  of "cocoa":   pbCocoa
  of "android": pbAndroid
  of "ios":     pbIos
  else: raise newException(ValueError, "unknown backend: " & s)

proc previewBackendToString*(b: PreviewBackend): string =
  case b
  of pbWeb:     "web"
  of pbTui:     "tui"
  of pbGpui:    "gpui"
  of pbFreya:   "freya"
  of pbCocoa:   "cocoa"
  of pbAndroid: "android"
  of pbIos:     "ios"

proc canonicalPreviewId*(storyRef: StoryRef; backend: PreviewBackend): string =
  ## Build the canonical ``<storyGroup>/<storyName>#<storyIndex>@<backend>``
  ## form documented in the milestones intro. Reserved characters in
  ## ``group``/``name`` are %-encoded so the result is bijective with its
  ## input — i.e. ``decodePreviewId(canonicalPreviewId(s, b)) == (s, b)``.
  result = encodePreviewSegment(storyRef.group) & "/" &
           encodePreviewSegment(storyRef.name) & ":" &
           storyKindCanonicalString(storyRef.kind) & "#" &
           $storyRef.index & "@" &
           previewBackendToString(backend)

proc decodePreviewId*(s: string): tuple[storyRef: StoryRef; backend: PreviewBackend] =
  ## Inverse of `canonicalPreviewId`. Raises ``ValueError`` on malformed
  ## input.
  let atIdx = s.rfind('@')
  if atIdx <= 0:
    raise newException(ValueError, "preview-id missing '@backend': " & s)
  let backendStr = s[atIdx + 1 .. ^1]
  let head = s[0 ..< atIdx]
  let hashIdx = head.rfind('#')
  if hashIdx <= 0:
    raise newException(ValueError, "preview-id missing '#index': " & s)
  let indexStr = head[hashIdx + 1 .. ^1]
  let body = head[0 ..< hashIdx]
  let colonIdx = body.rfind(':')
  if colonIdx <= 0:
    raise newException(ValueError, "preview-id missing ':kind': " & s)
  let kindStr = body[colonIdx + 1 .. ^1]
  let groupAndName = body[0 ..< colonIdx]
  let slashIdx = groupAndName.find('/')
  if slashIdx <= 0:
    raise newException(ValueError, "preview-id missing 'group/name': " & s)
  var sref: StoryRef
  sref.group = decodePreviewSegment(groupAndName[0 ..< slashIdx])
  sref.name  = decodePreviewSegment(groupAndName[slashIdx + 1 .. ^1])
  sref.kind  = storyKindFromCanonicalString(kindStr)
  sref.index = parseInt(indexStr)
  result = (storyRef: sref, backend: previewBackendFromString(backendStr))

# --------------------------------------------------------------------------- #
#  Minimal YAML subset parser
# --------------------------------------------------------------------------- #
#
# Grammar (informal):
#
#   document   := (line)*
#   line       := indent (key ':' value? | '-' value)? comment? newline
#   value      := scalar | flow-list | flow-map | empty (block follows)
#   flow-list  := '[' (item (',' item)*)? ']'
#   flow-map   := '{' (pair (',' pair)*)? '}'
#   pair       := key ':' scalar
#   scalar     := quoted-string | bareword | number | bool
#
# We don't support: anchors, aliases, tags, multiline strings beyond ``|``
# and ``>`` (folded). Brief frontmatter never uses those.

type
  YamlNodeKind* = enum
    ynkScalar, ynkSequence, ynkMapping
  YamlNode* = ref object
    case kind*: YamlNodeKind
    of ynkScalar: scalar*: string
    of ynkSequence: items*: seq[YamlNode]
    of ynkMapping:
      pairs*: seq[(string, YamlNode)]   ## preserve order

proc newScalar(s: string): YamlNode =
  YamlNode(kind: ynkScalar, scalar: s)
proc newSequence(): YamlNode =
  YamlNode(kind: ynkSequence)
proc newMapping(): YamlNode =
  YamlNode(kind: ynkMapping)

proc getKey*(m: YamlNode; key: string): YamlNode =
  if m == nil or m.kind != ynkMapping: return nil
  for (k, v) in m.pairs:
    if k == key: return v
  return nil

proc hasKey*(m: YamlNode; key: string): bool =
  m.getKey(key) != nil

proc addPair(m: YamlNode; key: string; v: YamlNode) =
  m.pairs.add((key, v))

# Strip a YAML inline comment from a value string. Comments start at
# ``#`` preceded by a space and end at end-of-line. We do not attempt
# to honour comments inside quoted strings — the grammar bans those.
proc stripComment(s: string): string =
  var i = 0
  var inSingle = false
  var inDouble = false
  while i < s.len:
    let ch = s[i]
    if ch == '\'' and not inDouble:
      inSingle = not inSingle
    elif ch == '"' and not inSingle:
      inDouble = not inDouble
    elif ch == '#' and not inSingle and not inDouble:
      if i == 0 or s[i-1] == ' ' or s[i-1] == '\t':
        return s[0 ..< i].strip(leading = false)
    inc i
  return s

proc unquote(s: string): string =
  let t = s.strip()
  if t.len >= 2:
    if (t[0] == '"' and t[^1] == '"') or (t[0] == '\'' and t[^1] == '\''):
      let inner = t[1 ..< ^1]
      if t[0] == '"':
        # Minimal escape handling.
        result = newStringOfCap(inner.len)
        var i = 0
        while i < inner.len:
          if inner[i] == '\\' and i + 1 < inner.len:
            case inner[i+1]
            of 'n': result.add('\n')
            of 't': result.add('\t')
            of 'r': result.add('\r')
            of '"': result.add('"')
            of '\\': result.add('\\')
            else: result.add(inner[i+1])
            inc i, 2
          else:
            result.add(inner[i])
            inc i
        return
      else:
        return inner
  return t

proc parseFlowScalar(buf: string; pos: var int): string =
  ## Parse a scalar inside ``[...]`` or ``{...}``. Stops at the next
  ## structural character (``,``, ``]``, ``}``, or ``:`` in mapping
  ## context). Returns the value with surrounding whitespace trimmed
  ## and quotes stripped via ``unquote``.
  var depth = 0
  let start = pos
  var inSingle = false
  var inDouble = false
  while pos < buf.len:
    let ch = buf[pos]
    if inSingle:
      if ch == '\'': inSingle = false
    elif inDouble:
      if ch == '\\' and pos + 1 < buf.len:
        inc pos
      elif ch == '"': inDouble = false
    else:
      if ch == '\'':
        inSingle = true
      elif ch == '"':
        inDouble = true
      elif ch == '[' or ch == '{':
        inc depth
      elif ch == ']' or ch == '}':
        if depth == 0: break
        dec depth
      elif depth == 0 and (ch == ',' or ch == ':'):
        break
    inc pos
  return unquote(buf[start ..< pos].strip())

proc skipFlowSpaces(buf: string; pos: var int) =
  while pos < buf.len and buf[pos] in {' ', '\t', '\n', '\r'}:
    inc pos

proc parseFlowValue(buf: string; pos: var int): YamlNode

proc parseFlowMapping(buf: string; pos: var int): YamlNode =
  result = newMapping()
  inc pos  # consume '{'
  skipFlowSpaces(buf, pos)
  if pos < buf.len and buf[pos] == '}':
    inc pos
    return
  while pos < buf.len:
    skipFlowSpaces(buf, pos)
    let key = parseFlowScalar(buf, pos)
    skipFlowSpaces(buf, pos)
    if pos >= buf.len or buf[pos] != ':':
      raise newException(ValueError, "flow mapping: expected ':' after key '" & key & "'")
    inc pos  # consume ':'
    skipFlowSpaces(buf, pos)
    let v = parseFlowValue(buf, pos)
    result.addPair(key, v)
    skipFlowSpaces(buf, pos)
    if pos < buf.len and buf[pos] == ',':
      inc pos
      continue
    if pos < buf.len and buf[pos] == '}':
      inc pos
      break

proc parseFlowSequence(buf: string; pos: var int): YamlNode =
  result = newSequence()
  inc pos  # consume '['
  skipFlowSpaces(buf, pos)
  if pos < buf.len and buf[pos] == ']':
    inc pos
    return
  while pos < buf.len:
    skipFlowSpaces(buf, pos)
    let v = parseFlowValue(buf, pos)
    result.items.add(v)
    skipFlowSpaces(buf, pos)
    if pos < buf.len and buf[pos] == ',':
      inc pos
      continue
    if pos < buf.len and buf[pos] == ']':
      inc pos
      break

proc parseFlowValue(buf: string; pos: var int): YamlNode =
  skipFlowSpaces(buf, pos)
  if pos >= buf.len:
    return newScalar("")
  let ch = buf[pos]
  if ch == '{': return parseFlowMapping(buf, pos)
  if ch == '[': return parseFlowSequence(buf, pos)
  return newScalar(parseFlowScalar(buf, pos))

# --- Block parser --- #

proc indentOf(line: string): int =
  result = 0
  while result < line.len and line[result] == ' ':
    inc result

proc findKeyTerminator(body: string): int =
  ## Locate the ``:`` that ends a block-mapping key.  A leading
  ## double-quoted segment shields colons inside the key.  Returns the
  ## index of the terminator ``:`` (the one followed by space or
  ## end-of-string), or ``-1`` if not found.
  var i = 0
  if i < body.len and body[i] == '"':
    inc i
    while i < body.len and body[i] != '"':
      if body[i] == '\\' and i + 1 < body.len:
        inc i, 2
      else:
        inc i
    if i < body.len: inc i      # consume closing "
  # Now scan for ``:`` (followed by space or EOL) outside flow brackets.
  var depth = 0
  while i < body.len:
    let ch = body[i]
    if ch == '[' or ch == '{':
      inc depth
    elif ch == ']' or ch == '}':
      if depth > 0: dec depth
    elif depth == 0 and ch == ':':
      if i + 1 == body.len or body[i + 1] in {' ', '\t'}:
        return i
    inc i
  return -1

proc isBlank(line: string): bool =
  for ch in line:
    if ch != ' ' and ch != '\t': return false
  return true

proc isComment(line: string): bool =
  let stripped = line.strip()
  return stripped.len > 0 and stripped[0] == '#'

proc parseBlock(lines: seq[string]; startIdx: int; indent: int;
                outIdx: var int): YamlNode

proc valueFromInline(s: string): YamlNode =
  ## Parse the inline value on the same line as ``key:``. May be a
  ## flow-list, flow-map, or scalar; an empty/comment-only string
  ## indicates a block follows on subsequent lines.
  let trimmed = stripComment(s).strip()
  if trimmed.len == 0:
    return nil
  var pos = 0
  if trimmed[0] == '[': return parseFlowSequence(trimmed, pos)
  if trimmed[0] == '{': return parseFlowMapping(trimmed, pos)
  return newScalar(unquote(trimmed))

proc parseBlock(lines: seq[string]; startIdx: int; indent: int;
                outIdx: var int): YamlNode =
  ## Parse a block node beginning at ``startIdx`` with leading indent
  ## ``indent`` (the indent of the first content line). The caller has
  ## already determined whether the block is a sequence (first line
  ## begins with ``- ``) or a mapping (otherwise). On return, ``outIdx``
  ## points at the first line that does NOT belong to this block.
  outIdx = startIdx
  if startIdx >= lines.len:
    return nil
  let first = lines[startIdx]
  let firstStripped = first[indent .. ^1]
  if firstStripped.startsWith("- "):
    result = newSequence()
    var i = startIdx
    while i < lines.len:
      let line = lines[i]
      if isBlank(line) or isComment(line):
        inc i
        continue
      let li = indentOf(line)
      if li < indent: break
      if li > indent:
        # Should not happen at the head of a sequence item.
        inc i
        continue
      let body = line[li .. ^1]
      if not body.startsWith("- "): break
      let itemInline = body[2 .. ^1]
      let itemStripped = stripComment(itemInline).strip()

      # Case A: "- key: value" (or "- key:" with nested children) →
      # the item is a mapping. Synthesise a virtual mapping-line at
      # ``indent + 2`` so the standard mapping path can absorb it
      # plus any continuation lines at the same indent.
      let isFlowStart = itemStripped.len > 0 and itemStripped[0] in {'[', '{'}
      let isMappingHead = (not isFlowStart) and
                          itemStripped.find(':') >= 0 and
                          # ":" must be followed by space, end of string, or end
                          (block:
                            let cIdx = itemStripped.find(':')
                            cIdx + 1 == itemStripped.len or
                            itemStripped[cIdx + 1] in {' ', '\t'})

      if isMappingHead:
        # Rewrite the current line so the dash is replaced by two
        # spaces. After this, ``i`` points at the first "key:" line of
        # a mapping at indent (indent + 2). We parse that mapping with
        # the regular mapping path and bump ``i`` past it.
        var virtualLines = lines
        var rewritten = newString(indent + 2 + itemInline.len)
        for k in 0 ..< indent + 2:
          rewritten[k] = ' '
        for k in 0 ..< itemInline.len:
          rewritten[indent + 2 + k] = itemInline[k]
        virtualLines[i] = rewritten
        var inner = 0
        let node = parseBlock(virtualLines, i, indent + 2, inner)
        result.items.add(node)
        i = inner
        continue

      let inline = valueFromInline(itemInline)
      if inline != nil:
        result.items.add(inline)
        inc i
      else:
        # Block-style item without an inline mapping head: child
        # indent must be > indent. Pick the indent of the next
        # non-blank line.
        inc i
        var childIndent = -1
        var j = i
        while j < lines.len:
          if isBlank(lines[j]) or isComment(lines[j]):
            inc j; continue
          let ji = indentOf(lines[j])
          if ji <= indent: break
          childIndent = ji
          break
        if childIndent < 0:
          result.items.add(newScalar(""))
          continue
        var inner = 0
        let node = parseBlock(lines, i, childIndent, inner)
        result.items.add(node)
        i = inner
    outIdx = i
    return
  else:
    result = newMapping()
    var i = startIdx
    while i < lines.len:
      let line = lines[i]
      if isBlank(line) or isComment(line):
        inc i
        continue
      let li = indentOf(line)
      if li < indent: break
      if li > indent:
        inc i
        continue
      let body = line[li .. ^1]
      if body.startsWith("- "):
        break
      let colonIdx = findKeyTerminator(body)
      if colonIdx < 0:
        # Lone scalar in a mapping context — treat as ill-formed YAML
        # and stop here.
        break
      let key = body[0 ..< colonIdx].strip().unquote()
      let after = if colonIdx + 1 < body.len: body[colonIdx + 1 .. ^1] else: ""
      let inline = valueFromInline(after)
      if inline != nil:
        result.addPair(key, inline)
        inc i
      else:
        inc i
        var childIndent = -1
        var j = i
        var sawDashAtParent = false
        # Determine child indent. For a block sequence the dash is at
        # ``indent + 2`` (conventional) OR at the same indent as the
        # parent + 0 (rare). We detect both.
        while j < lines.len:
          if isBlank(lines[j]) or isComment(lines[j]):
            inc j; continue
          let ji = indentOf(lines[j])
          if ji <= indent:
            sawDashAtParent = ji == indent and lines[j][ji .. ^1].startsWith("- ")
            break
          childIndent = ji
          break
        if childIndent < 0 and not sawDashAtParent:
          result.addPair(key, newScalar(""))
          continue
        if sawDashAtParent:
          # YAML allows dashes to be flush with the key's indent. We
          # treat them as children of the key.
          var inner = 0
          let node = parseBlock(lines, j, indent, inner)
          result.addPair(key, node)
          i = inner
        else:
          var inner = 0
          let node = parseBlock(lines, i, childIndent, inner)
          result.addPair(key, node)
          i = inner
    outIdx = i
    return

proc parseYaml*(buf: string): YamlNode =
  var lines: seq[string] = @[]
  for ln in buf.splitLines:
    lines.add(ln)
  # Skip leading blank/comment lines.
  var i = 0
  while i < lines.len and (isBlank(lines[i]) or isComment(lines[i])):
    inc i
  if i >= lines.len:
    return newMapping()
  let firstIndent = indentOf(lines[i])
  var outIdx = 0
  return parseBlock(lines, i, firstIndent, outIdx)

# --------------------------------------------------------------------------- #
#  Brief decoder
# --------------------------------------------------------------------------- #

proc raiseMissing(field, path: string) =
  var e = newException(MissingRequiredFieldError,
                       fmt"missing required field '{field}' in {path}")
  e.field = field
  e.path = path
  raise e

proc parseBriefKind(s: string; path: string): BriefKind =
  case s.toLowerAscii().strip()
  of "render":        bkRender
  of "interaction":   bkInteraction
  of "accessibility": bkAccessibility
  of "copy":          bkCopy
  of "chrome":        bkChrome
  of "component":     bkComponent
  of "foundation":    bkFoundation
  of "pattern":       bkPattern
  of "vectorsymbol", "vector_symbol", "vector-symbol": bkVectorSymbol
  of "guideline":     bkGuideline
  else:
    var e = newException(BriefParseError,
                         fmt"unknown brief kind '{s}' in {path}")
    e.field = "kind"
    e.path = path
    raise e

proc expectScalar(n: YamlNode; field, path: string): string =
  if n == nil:
    raiseMissing(field, path)
  if n.kind != ynkScalar:
    var e = newException(BriefParseError,
                         fmt"expected scalar for '{field}' in {path}")
    e.field = field
    e.path = path
    raise e
  return n.scalar

proc expectInt(n: YamlNode; field, path: string): int =
  let s = expectScalar(n, field, path)
  try:
    return parseInt(s.strip())
  except ValueError:
    var e = newException(BriefParseError,
                         fmt"expected int for '{field}' in {path}: got '{s}'")
    e.field = field
    e.path = path
    raise e

proc expectFloat(n: YamlNode; field, path: string): float =
  let s = expectScalar(n, field, path)
  try:
    return parseFloat(s.strip())
  except ValueError:
    var e = newException(BriefParseError,
                         fmt"expected float for '{field}' in {path}: got '{s}'")
    e.field = field
    e.path = path
    raise e

proc decodeStoryRef(node: YamlNode; path: string): StoryRef =
  if node == nil or node.kind != ynkMapping:
    raiseMissing("storyRef", path)
  result.group = expectScalar(node.getKey("group"), "storyRef.group", path)
  result.name  = expectScalar(node.getKey("name"),  "storyRef.name",  path)
  let kindStr  = expectScalar(node.getKey("kind"),  "storyRef.kind",  path)
  try:
    result.kind = storyKindFromCanonicalString(kindStr)
  except ValueError:
    var e = newException(BriefParseError,
                         fmt"unknown story kind '{kindStr}' in {path}")
    e.field = "storyRef.kind"
    e.path = path
    raise e
  if node.hasKey("index"):
    result.index = expectInt(node.getKey("index"), "storyRef.index", path)
  else:
    result.index = 0

proc decodeBackends(node: YamlNode; path: string): seq[PreviewBackend] =
  if node == nil:
    raiseMissing("backends", path)
  if node.kind != ynkSequence:
    var e = newException(BriefParseError,
                         fmt"expected sequence for 'backends' in {path}")
    e.field = "backends"
    e.path = path
    raise e
  for item in node.items:
    let s = expectScalar(item, "backends[]", path)
    try:
      result.add(previewBackendFromString(s.strip()))
    except ValueError:
      var e = newException(UnknownBackendError,
                           fmt"unknown backend '{s}' in {path}")
      e.field = "backends"
      e.path = path
      raise e

proc decodeCoversPreviews(node: YamlNode; path: string): seq[BriefPreviewCoverage] =
  if node == nil:
    raiseMissing("coversPreviews", path)
  if node.kind != ynkSequence:
    var e = newException(BriefParseError,
                         fmt"expected sequence for 'coversPreviews' in {path}")
    e.field = "coversPreviews"
    e.path = path
    raise e
  if node.items.len == 0:
    raiseMissing("coversPreviews", path)
  for item in node.items:
    if item.kind != ynkMapping:
      var e = newException(BriefParseError,
                           fmt"coversPreviews item must be a mapping in {path}")
      e.field = "coversPreviews"
      e.path = path
      raise e
    var cov: BriefPreviewCoverage
    cov.storyRef = decodeStoryRef(item.getKey("storyRef"), path)
    cov.backends = decodeBackends(item.getKey("backends"), path)
    result.add(cov)

proc decodeViewports(node: YamlNode; path: string): seq[BriefViewport] =
  if node == nil:
    raiseMissing("captureViewports", path)
  if node.kind != ynkSequence:
    var e = newException(BriefParseError,
                         fmt"expected sequence for 'captureViewports' in {path}")
    e.field = "captureViewports"
    e.path = path
    raise e
  if node.items.len == 0:
    raiseMissing("captureViewports", path)
  for item in node.items:
    if item.kind != ynkMapping:
      var e = newException(BriefParseError,
                           fmt"captureViewports item must be a mapping in {path}")
      e.field = "captureViewports"
      e.path = path
      raise e
    var vp: BriefViewport
    vp.width  = expectInt(item.getKey("width"),  "captureViewports[].width",  path)
    vp.height = expectInt(item.getKey("height"), "captureViewports[].height", path)
    if item.hasKey("label"):
      vp.label = expectScalar(item.getKey("label"), "captureViewports[].label", path)
    result.add(vp)

proc decodeScoring(node: YamlNode; path: string): seq[BriefScoringDimension] =
  if node == nil:
    raiseMissing("scoringDimensions", path)
  if node.kind != ynkSequence:
    var e = newException(BriefParseError,
                         fmt"expected sequence for 'scoringDimensions' in {path}")
    e.field = "scoringDimensions"
    e.path = path
    raise e
  if node.items.len == 0:
    raiseMissing("scoringDimensions", path)
  for item in node.items:
    if item.kind != ynkMapping:
      var e = newException(BriefParseError,
                           fmt"scoringDimensions item must be a mapping in {path}")
      e.field = "scoringDimensions"
      e.path = path
      raise e
    var d: BriefScoringDimension
    d.id     = expectScalar(item.getKey("id"),     "scoringDimensions[].id",     path)
    d.label  = expectScalar(item.getKey("label"),  "scoringDimensions[].label",  path)
    d.weight = expectFloat(item.getKey("weight"),  "scoringDimensions[].weight", path)
    let scale = item.getKey("scale")
    if scale != nil and scale.kind == ynkMapping:
      d.scaleMin = expectInt(scale.getKey("min"), "scoringDimensions[].scale.min", path)
      d.scaleMax = expectInt(scale.getKey("max"), "scoringDimensions[].scale.max", path)
    else:
      d.scaleMin = 1
      d.scaleMax = 10
    result.add(d)
  # Validate that weights sum to 1.0 (±1e-6).
  var sum = 0.0
  for d in result: sum += d.weight
  if abs(sum - 1.0) > 1e-6:
    var e = newException(ScoringWeightSumError,
                         fmt"scoringDimensions weights sum to {sum}, want 1.0, in {path}")
    e.field = "scoringDimensions"
    e.path = path
    e.actualSum = sum
    raise e

proc decodeRelatedBriefs(node: YamlNode; path: string): seq[string] =
  if node == nil: return @[]
  if node.kind != ynkSequence:
    var e = newException(BriefParseError,
                         fmt"expected sequence for 'relatedBriefs' in {path}")
    e.field = "relatedBriefs"
    e.path = path
    raise e
  for item in node.items:
    result.add(expectScalar(item, "relatedBriefs[]", path))

proc splitFrontmatter*(buf: string; path: string):
    tuple[front: string; body: string] =
  ## Split a brief file into its YAML frontmatter and markdown body.
  ## Returns ``("", buf)`` if no frontmatter delimiter is present.
  let lines = buf.splitLines
  if lines.len == 0 or lines[0].strip() != "---":
    return ("", buf)
  var frontLines: seq[string] = @[]
  var i = 1
  var found = false
  while i < lines.len:
    if lines[i].strip() == "---":
      found = true
      break
    frontLines.add(lines[i])
    inc i
  if not found:
    var e = newException(BriefParseError,
                         fmt"frontmatter '---' terminator missing in {path}")
    e.path = path
    raise e
  let body = if i + 1 < lines.len: lines[i + 1 .. ^1].join("\n") else: ""
  return (frontLines.join("\n"), body)

proc kindFromDirectory(path: string): string =
  ## ``briefs/<kind>/<slug>.md`` → ``<kind>``. Returns an empty string
  ## if the path is not in that shape (we still parse, but the
  ## directory/kind check is skipped).
  let parent = splitPath(path).head
  if parent.len == 0: return ""
  let parentName = splitPath(parent).tail
  return parentName

proc parseBrief*(filePath: string): Brief =
  ## The milestone spec annotates this proc with
  ## ``{.raises: [BriefParseError, IOError, OSError].}``. We omit the
  ## pragma so the function can be invoked from contexts that have not
  ## annotated their own raise sets — the body still only raises
  ## ``BriefParseError`` (or its subclasses), ``IOError``, or ``OSError``
  ## in practice; any other ``Exception`` from the YAML scanner is
  ## wrapped into ``BriefParseError`` below.
  ## Parse one brief markdown file. Raises one of the ``BriefParseError``
  ## subclasses on structural issues; raises ``IOError``/``OSError`` if
  ## the file cannot be read.
  let raw = readFile(filePath)
  let (front, body) = splitFrontmatter(raw, filePath)
  if front.len == 0:
    var e = newException(BriefParseError,
                         fmt"no YAML frontmatter found in {filePath}")
    e.path = filePath
    raise e
  var root: YamlNode
  try:
    root = parseYaml(front)
  except BriefParseError:
    raise
  except CatchableError as ve:
    var e = newException(BriefParseError, ve.msg & " in " & filePath)
    e.path = filePath
    raise e
  except Exception as exc:
    var e = newException(BriefParseError, exc.msg & " in " & filePath)
    e.path = filePath
    raise e
  if root == nil or root.kind != ynkMapping:
    var e = newException(BriefParseError,
                         fmt"frontmatter must be a mapping in {filePath}")
    e.path = filePath
    raise e

  # Required fields
  if not root.hasKey("briefId"):
    raiseMissing("briefId", filePath)
  if not root.hasKey("coversPreviews"):
    raiseMissing("coversPreviews", filePath)

  result.briefId = expectScalar(root.getKey("briefId"), "briefId", filePath)
  result.schemaVersion =
    if root.hasKey("schemaVersion"):
      expectInt(root.getKey("schemaVersion"), "schemaVersion", filePath)
    else: 1
  if not root.hasKey("title"):
    raiseMissing("title", filePath)
  result.title = expectScalar(root.getKey("title"), "title", filePath)
  if not root.hasKey("kind"):
    raiseMissing("kind", filePath)
  let kindStr = expectScalar(root.getKey("kind"), "kind", filePath)
  result.kind = parseBriefKind(kindStr, filePath)

  # Kind must match the directory.
  let dirKind = kindFromDirectory(filePath)
  if dirKind.len > 0 and dirKind != $kindStr.toLowerAscii().strip():
    # The directory may itself be one of the legal kinds; otherwise
    # the brief is allowed to live anywhere (e.g. flat fixtures dir).
    const Known = ["render", "interaction", "accessibility", "copy", "chrome",
                   "component", "foundation", "pattern", "vectorsymbol",
                   "guideline"]
    if dirKind in Known:
      var e = newException(BriefKindMismatchError,
                           fmt"kind '{kindStr}' does not match directory '{dirKind}' in {extractFilename(filePath)}")
      e.field = "kind"
      e.path = filePath
      raise e

  result.coversPreviews = decodeCoversPreviews(root.getKey("coversPreviews"), filePath)
  result.captureViewports = decodeViewports(root.getKey("captureViewports"), filePath)
  result.reviewerSchemaVersion =
    if root.hasKey("reviewerSchemaVersion"):
      expectInt(root.getKey("reviewerSchemaVersion"), "reviewerSchemaVersion", filePath)
    else: 1
  result.scoringDimensions = decodeScoring(root.getKey("scoringDimensions"), filePath)
  result.relatedBriefs = decodeRelatedBriefs(root.getKey("relatedBriefs"), filePath)

  # Preserve unknown frontmatter keys.
  const KnownTop = ["briefId", "schemaVersion", "kind", "title",
                    "coversPreviews", "captureViewports",
                    "reviewerSchemaVersion", "scoringDimensions",
                    "relatedBriefs"]
  result.extra = initTable[string, string]()
  for (k, v) in root.pairs:
    if k in KnownTop: continue
    if v.kind == ynkScalar:
      result.extra[k] = v.scalar
    elif v.kind == ynkSequence:
      var parts: seq[string] = @[]
      for it in v.items:
        if it.kind == ynkScalar:
          parts.add(it.scalar)
      result.extra[k] = parts.join(",")
    # Mappings get a coarse string serialisation for forward-compat.
    else:
      var parts: seq[string] = @[]
      for (kk, vv) in v.pairs:
        if vv.kind == ynkScalar:
          parts.add(kk & "=" & vv.scalar)
      result.extra[k] = parts.join(",")

  result.bodyMarkdown = body
  result.sourceFile = filePath

# --------------------------------------------------------------------------- #
#  Re-serialisation helper for round-trip testing.
# --------------------------------------------------------------------------- #

proc `$`*(b: Brief): string =
  ## Canonical YAML-ish projection of the known fields. Stable enough
  ## that round-tripping a parsed brief yields the same bytes — used
  ## by the parser round-trip test. Unknown ``extra`` fields are
  ## appended at the end (lexicographically) so the output is
  ## deterministic. Not a full YAML emitter; only emits what
  ## ``parseBrief`` reads back.
  result = ""
  result.add("briefId: " & b.briefId & "\n")
  result.add("schemaVersion: " & $b.schemaVersion & "\n")
  result.add("kind: ")
  result.add(case b.kind
    of bkRender: "render"
    of bkInteraction: "interaction"
    of bkAccessibility: "accessibility"
    of bkCopy: "copy"
    of bkChrome: "chrome"
    of bkComponent: "component"
    of bkFoundation: "foundation"
    of bkPattern: "pattern"
    of bkVectorSymbol: "vectorsymbol"
    of bkGuideline: "guideline")
  result.add("\n")
  result.add("title: " & b.title & "\n")
  result.add("coversPreviews:\n")
  for cov in b.coversPreviews:
    result.add("  - storyRef: { group: \"" & cov.storyRef.group &
               "\", name: \"" & cov.storyRef.name &
               "\", kind: " & storyKindCanonicalString(cov.storyRef.kind) &
               ", index: " & $cov.storyRef.index & " }\n")
    var bs: seq[string] = @[]
    for b2 in cov.backends:
      bs.add(previewBackendToString(b2))
    result.add("    backends: [" & bs.join(", ") & "]\n")
  result.add("captureViewports:\n")
  for vp in b.captureViewports:
    result.add("  - { width: " & $vp.width & ", height: " & $vp.height &
               ", label: \"" & vp.label & "\" }\n")
  result.add("reviewerSchemaVersion: " & $b.reviewerSchemaVersion & "\n")
  result.add("scoringDimensions:\n")
  for d in b.scoringDimensions:
    result.add("  - { id: " & d.id & ", label: \"" & d.label &
               "\", weight: " & $d.weight &
               ", scale: { min: " & $d.scaleMin & ", max: " & $d.scaleMax & " } }\n")
  if b.relatedBriefs.len > 0:
    result.add("relatedBriefs: [" & b.relatedBriefs.join(", ") & "]\n")
  # Deterministic ordering for extras.
  var extraKeys = toSeq(b.extra.keys)
  algorithm.sort(extraKeys, system.cmp[string])
  for k in extraKeys:
    result.add(k & ": " & b.extra[k] & "\n")
