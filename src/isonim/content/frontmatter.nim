## isonim/content/frontmatter -- `---`-delimited front matter: splitting it
## off a content file, and reading it as a small, documented YAML subset.
##
## Two layers, both pure (no filesystem access, identical on `nim c` and
## `nim js`):
##
## * `splitFrontMatter` cuts a leading `---` ... `---` block off a file and
##   reports the line the body starts at. It makes no assumption about the
##   block's contents. (Moved here unchanged from isonim-docs'
##   `src/core/content.nim`, which re-exports it.)
## * `parseFrontMatterBlock` reads that block as the YAML subset below and
##   returns every key in source order, known or not, so a consumer can
##   map the keys it understands onto its own typed record and pass the
##   rest through unchanged (a blog layout's `page.extra`, say).
##
## The subset
## ----------
##
## It is a subset of YAML 1.2 (https://yaml.org/spec/1.2.2/), plus the one
## leniency listed last. Anything outside it is a `FrontMatterError` that
## names the line, never a silent misreading.
##
## * A **mapping at the top level**: one `key: value` per line, starting at
##   column 0. Keys are unique (YAML requires it). A key is any text up to
##   the first `:`; it may not start with `-`, `#`, `[`, `{`, a quote or
##   white space.
## * **Scalars**: plain (`title: Hello world`), single-quoted (`'it''s'`,
##   where `''` is a quote) or double-quoted (`"a \"b\"\n"`, with the
##   escapes `\\ \" \/ \n \t \r \0 \b \f \e` and `\uXXXX`). Everything is
##   read as a string; `getBool` and `getInt` interpret one on request
##   (YAML 1.2 core schema booleans `true`/`false`, any case-consistent
##   form; decimal integers). `key:` with nothing after it and nothing
##   indented under it is the empty string.
## * **Lists**: a flow list on the key's line (`tags: [nim, "web, ui"]`),
##   or a block list of `- item` lines indented under the key. Items are
##   scalars.
## * **One-level maps**: a flow map on the key's line
##   (`author: {name: Ada, url: /about/}`), or `subkey: scalar` lines
##   indented under the key (all at the same indentation). Values are
##   scalars. A map inside a map, or a list inside a map, is outside the
##   subset.
## * **Comments**: a line whose first non-blank character is `#`, and a
##   ` #` (space, hash) after a plain scalar or after a closing quote.
## * **Not in the subset** (each an error naming the line): tab
##   indentation, block scalars (`|`, `>`), anchors and aliases (`&`, `*`),
##   tags (`!`), multi-document markers, nesting deeper than one level,
##   and an indented line with no key above it to belong to.
## * **Leniency:** a plain scalar is the rest of its line (less a trailing
##   comment), so `description: Note: read this first` is the string
##   `Note: read this first` instead of the error YAML would report.
##   Front matter is written by hand, and this is the mistake people make.

import std/[strutils, unicode]

type
  FrontMatterError* = object of ValueError
    ## Front matter outside the documented subset, or a typed accessor
    ## asked for a value the field does not hold. `line` is 1-based and
    ## counts lines of the whole content file when the block came from
    ## `readFrontMatter` (or from `parseFrontMatterBlock` given its
    ## `firstLine`); 0 when the error is not tied to a line.
    line*: int

  FrontMatterValueKind* = enum
    fvScalar ## a single string
    fvList   ## a list of scalars
    fvMap    ## a one-level map of scalars

  FrontMatterPair* = object
    ## One `key: value` entry of a one-level map, in source order.
    key*: string
    value*: string

  FrontMatterValue* = object
    ## The value of one front matter key. A flat record rather than a case
    ## object on purpose: the JS backend's deep copy of sequences of
    ## variant objects is the hazard isonim's signal code documents, and
    ## these values are copied into whatever record a consumer builds.
    ## Only the field matching `kind` is meaningful.
    kind*: FrontMatterValueKind
    scalar*: string               ## fvScalar
    items*: seq[string]           ## fvList
    entries*: seq[FrontMatterPair] ## fvMap

  FrontMatterField* = object
    ## One top-level key, with the line it was written on.
    key*: string
    value*: FrontMatterValue
    line*: int

  FrontMatter* = object
    ## Every top-level key of a front matter block, in source order --
    ## unknown keys included, so nothing a consumer does not understand is
    ## lost.
    fields*: seq[FrontMatterField]

# --- Splitting ------------------------------------------------------------

proc splitFrontMatter*(raw: string): tuple[frontRaw: string, bodyRaw: string, bodyLine: int] =
  ## Splits a leading `---\n...\n---\n` front matter block (if present)
  ## from the rest of the content. Pure line splitting -- no assumptions
  ## about the frontmatter's contents, so it tolerates any key set.
  ## Returns the front matter text, the remaining body text, and the
  ## 1-based line the body starts at (1 when there's no front matter).
  let lines = raw.splitLines()
  if lines.len > 0 and lines[0].strip() == "---":
    var closeIdx = -1
    for i in 1 ..< lines.len:
      if lines[i].strip() == "---":
        closeIdx = i
        break
    if closeIdx >= 0:
      let frontLines = lines[1 ..< closeIdx]
      let bodyLines = if closeIdx + 1 < lines.len: lines[closeIdx + 1 .. ^1] else: @[]
      return (frontLines.join("\n"), bodyLines.join("\n"), closeIdx + 2)
  (frontRaw: "", bodyRaw: raw, bodyLine: 1)

# --- Scalars ----------------------------------------------------------------

proc fail(line: int; msg: string) {.noreturn.} =
  var e = newException(FrontMatterError,
    (if line > 0: "front matter line " & $line & ": " else: "front matter: ") & msg)
  e.line = line
  raise e

proc readQuoted(s: string; start: int; line: int): tuple[value: string, next: int] =
  ## Reads the quoted scalar opening at `s[start]` (a `'` or `"`), returning
  ## its decoded value and the index just past the closing quote.
  let q = s[start]
  var i = start + 1
  var v = ""
  while true:
    if i >= s.len:
      fail(line, "unterminated " & (if q == '"': "double" else: "single") &
        "-quoted string")
    let c = s[i]
    if q == '\'':
      if c == '\'':
        if i + 1 < s.len and s[i + 1] == '\'':
          v.add '\''
          i += 2
          continue
        return (v, i + 1)
      v.add c
      inc i
    else:
      if c == '"':
        return (v, i + 1)
      if c != '\\':
        v.add c
        inc i
        continue
      if i + 1 >= s.len:
        fail(line, "unterminated double-quoted string")
      let e = s[i + 1]
      i += 2
      case e
      of '\\': v.add '\\'
      of '"': v.add '"'
      of '/': v.add '/'
      of 'n': v.add '\n'
      of 't': v.add '\t'
      of 'r': v.add '\r'
      of '0': v.add '\0'
      of 'b': v.add '\b'
      of 'f': v.add '\f'
      of 'e': v.add '\e'
      of 'u':
        if i + 4 > s.len:
          fail(line, "\\u needs four hex digits")
        var code = 0
        for k in i ..< i + 4:
          let h = s[k]
          let d = case h
            of '0' .. '9': ord(h) - ord('0')
            of 'a' .. 'f': ord(h) - ord('a') + 10
            of 'A' .. 'F': ord(h) - ord('A') + 10
            else: fail(line, "\\u needs four hex digits, got '" & s[i ..< i + 4] & "'")
          code = code * 16 + d
        if code >= 0xD800 and code <= 0xDFFF:
          fail(line, "\\u" & s[i ..< i + 4] & " is a UTF-16 surrogate; write the character itself")
        v.add $Rune(code)
        i += 4
      else:
        fail(line, "unknown escape \\" & $e & " in a double-quoted string")

proc stripComment(s: string): string =
  ## A plain scalar less a trailing ` #` comment, and trailing blanks.
  var cut = s.len
  for i in 0 ..< s.len:
    if s[i] == '#' and i > 0 and s[i - 1] in {' ', '\t'}:
      cut = i
      break
  s[0 ..< cut].strip(leading = false)

proc checkPlain(s: string; line: int) =
  ## Refuses the YAML constructs the subset leaves out, so they are never
  ## read as literal text by accident.
  if s.len == 0: return
  case s[0]
  of '|', '>':
    fail(line, "block scalars ('" & $s[0] & "') are not in the front matter subset; " &
      "write the text on one line, or as a quoted string with \\n")
  of '&', '*':
    fail(line, "anchors and aliases ('" & $s[0] & "') are not in the front matter subset")
  of '!':
    fail(line, "tags ('!') are not in the front matter subset")
  of '@', '`':
    fail(line, "a plain scalar may not start with '" & $s[0] & "' (YAML reserves it); quote it")
  else: discard

proc readScalar(text: string; line: int): string =
  ## One scalar: quoted (decoded; only a comment may follow it) or plain
  ## (the rest of the text, less a trailing comment).
  let s = text.strip()
  if s.len == 0: return ""
  if s[0] in {'"', '\''}:
    let (v, next) = readQuoted(s, 0, line)
    let rest = s[next .. ^1].strip()
    if rest.len > 0 and rest[0] != '#':
      fail(line, "unexpected text after a quoted string: '" & rest & "'")
    return v
  checkPlain(s, line)
  stripComment(s)

proc splitFlow(body: string; line: int): seq[string] =
  ## Splits the inside of a `[...]` or `{...}` at top-level commas,
  ## respecting quotes. Nested brackets are outside the subset.
  var cur = ""
  var i = 0
  while i < body.len:
    let c = body[i]
    if c in {'"', '\''}:
      let (_, next) = readQuoted(body, i, line)
      cur.add body[i ..< next]
      i = next
    elif c in {'[', ']', '{', '}'}:
      fail(line, "nested flow collections are not in the front matter subset")
    elif c == ',':
      result.add cur
      cur = ""
      inc i
    else:
      cur.add c
      inc i
  result.add cur

proc flowInner(s: string; open, close: char; line: int): string =
  ## The text between `open` at s[0] and its matching `close`; only a
  ## comment may follow the close.
  var i = 1
  while i < s.len and s[i] != close:
    if s[i] in {'"', '\''}:
      i = readQuoted(s, i, line).next
    else:
      inc i
  if i >= s.len:
    fail(line, "unterminated flow " & (if open == '[': "list" else: "map") &
      " (missing '" & $close & "')")
  let rest = s[i + 1 .. ^1].strip()
  if rest.len > 0 and rest[0] != '#':
    fail(line, "unexpected text after '" & $close & "': '" & rest & "'")
  s[1 ..< i]

proc splitKey(text: string; line: int): tuple[key, rest: string] =
  ## Splits `key: rest` at the first `:` followed by a blank or the end of
  ## the line (YAML's mapping indicator).
  var i = 0
  while i < text.len:
    if text[i] == ':' and (i + 1 == text.len or text[i + 1] in {' ', '\t'}):
      let key = text[0 ..< i].strip()
      if key.len == 0:
        fail(line, "a mapping entry needs a key before ':'")
      if key[0] in {'-', '#', '[', '{', '"', '\'', '&', '*', '!', '|', '>'}:
        fail(line, "a key may not start with '" & $key[0] & "'")
      return (key, text[i + 1 .. ^1])
    inc i
  fail(line, "expected 'key: value', got '" & text.strip() & "'")

proc readFlowList(s: string; line: int): seq[string] =
  let inner = flowInner(s, '[', ']', line)
  if inner.strip().len == 0: return @[]
  for part in splitFlow(inner, line):
    if part.strip().len == 0:
      fail(line, "empty item in a flow list")
    result.add readScalar(part, line)

proc readFlowMap(s: string; line: int): seq[FrontMatterPair] =
  let inner = flowInner(s, '{', '}', line)
  if inner.strip().len == 0: return @[]
  for part in splitFlow(inner, line):
    if part.strip().len == 0:
      fail(line, "empty entry in a flow map")
    let (k, v) = splitKey(part.strip(), line)
    for prev in result:
      if prev.key == k:
        fail(line, "duplicate key '" & k & "' in a flow map")
    result.add FrontMatterPair(key: k, value: readScalar(v, line))

# --- Block parsing ----------------------------------------------------------

proc indentOf(raw: string; line: int): int =
  for c in raw:
    if c == ' ': inc result
    elif c == '\t':
      fail(line, "tab indentation is not allowed in YAML; indent with spaces")
    else: break

proc isSkippable(raw: string): bool =
  let s = raw.strip()
  s.len == 0 or s[0] == '#'

proc parseFrontMatterBlock*(frontRaw: string; firstLine = 1): FrontMatter =
  ## Reads a front matter block (the text between the `---` lines, as
  ## `splitFrontMatter` returns it) as the documented YAML subset (see
  ## the module documentation). `firstLine` is the file line the block's
  ## first line is on, so errors name file lines: 2 for a block that
  ## follows a `---` on line 1, which is what `readFrontMatter` passes.
  ## Raises `FrontMatterError` for anything outside the subset.
  let lines = frontRaw.splitLines()
  var i = 0
  while i < lines.len:
    let raw = lines[i]
    let lineNo = firstLine + i
    if isSkippable(raw):
      inc i
      continue
    if indentOf(raw, lineNo) > 0:
      fail(lineNo, "indented line with no key above it to belong to")
    let t = raw.strip(leading = false)
    if t == "---" or t == "...":
      fail(lineNo, "multi-document markers are not in the front matter subset")
    let (key, restRaw) = splitKey(t, lineNo)
    for f in result.fields:
      if f.key == key:
        fail(lineNo, "duplicate key '" & key & "' (first on line " & $f.line & ")")
    let rest = restRaw.strip()
    var value: FrontMatterValue
    inc i
    if rest.len > 0 and rest[0] == '[':
      value = FrontMatterValue(kind: fvList, items: readFlowList(rest, lineNo))
    elif rest.len > 0 and rest[0] == '{':
      value = FrontMatterValue(kind: fvMap, entries: readFlowMap(rest, lineNo))
    elif rest.len > 0 and rest[0] != '#':
      value = FrontMatterValue(kind: fvScalar, scalar: readScalar(rest, lineNo))
    else:
      # `key:` alone: an indented block (list or map) may follow; with
      # none, the value is the empty scalar.
      var childIndent = -1
      var sawList = false
      var sawMap = false
      value = FrontMatterValue(kind: fvScalar)
      while i < lines.len:
        let craw = lines[i]
        let cline = firstLine + i
        if isSkippable(craw):
          inc i
          continue
        let ind = indentOf(craw, cline)
        let ct = craw.strip()
        # A YAML block list may sit at the key's own column ("- item"
        # directly under "tags:"); everything else nested must indent.
        let isItem = ct == "-" or ct.startsWith("- ")
        if ind == 0 and not (isItem and not sawMap):
          break
        if childIndent < 0:
          childIndent = ind
        elif ind != childIndent:
          fail(cline, "nesting deeper than one level is not in the front matter subset " &
            "(expected indentation " & $childIndent & ", got " & $ind & ")")
        if isItem:
          if sawMap:
            fail(cline, "a list item inside a map is not in the front matter subset")
          sawList = true
          let itemText = if ct == "-": "" else: ct[2 .. ^1]
          let it = itemText.strip()
          if it.len > 0 and (it[0] == '[' or it[0] == '{' or it == "-" or it.startsWith("- ")):
            fail(cline, "nested collections in a list are not in the front matter subset")
          if value.kind != fvList:
            value = FrontMatterValue(kind: fvList)
          value.items.add readScalar(itemText, cline)
        else:
          if sawList:
            fail(cline, "a map entry inside a list is not in the front matter subset")
          sawMap = true
          let (k, v) = splitKey(ct, cline)
          let vs = v.strip()
          if vs.len == 0 or vs[0] in {'[', '{'}:
            fail(cline, "a map value must be a scalar: nesting deeper than one level " &
              "is not in the front matter subset")
          if value.kind != fvMap:
            value = FrontMatterValue(kind: fvMap)
          for prev in value.entries:
            if prev.key == k:
              fail(cline, "duplicate key '" & k & "' in the map '" & key & "'")
          value.entries.add FrontMatterPair(key: k, value: readScalar(vs, cline))
        inc i
    result.fields.add FrontMatterField(key: key, value: value, line: lineNo)

proc readFrontMatter*(raw: string): tuple[front: FrontMatter, body: string, bodyLine: int] =
  ## `splitFrontMatter` then `parseFrontMatterBlock` over a whole content
  ## file: the parsed front matter (empty when there is none), the body
  ## text, and the 1-based line the body starts at. Error lines are file
  ## lines.
  let (frontRaw, bodyRaw, bodyLine) = splitFrontMatter(raw)
  let front = if bodyLine > 1: parseFrontMatterBlock(frontRaw, firstLine = 2)
              else: FrontMatter()
  (front, bodyRaw, bodyLine)

# --- Access -----------------------------------------------------------------

proc find(fm: FrontMatter; key: string): int =
  for i, f in fm.fields:
    if f.key == key: return i
  -1

proc contains*(fm: FrontMatter; key: string): bool =
  ## Whether `key` was written in the block.
  fm.find(key) >= 0

proc len*(fm: FrontMatter): int = fm.fields.len

proc keys*(fm: FrontMatter): seq[string] =
  ## Every key, in source order.
  for f in fm.fields: result.add f.key

proc field*(fm: FrontMatter; key: string): FrontMatterField =
  ## The field for `key`; raises `KeyError` when it is absent.
  let i = fm.find(key)
  if i < 0:
    raise newException(KeyError, "front matter has no key '" & key & "'")
  fm.fields[i]

proc `[]`*(fm: FrontMatter; key: string): FrontMatterValue =
  ## The value for `key`; raises `KeyError` when it is absent.
  fm.field(key).value

proc kindError(f: FrontMatterField; want: string) {.noreturn.} =
  fail(f.line, "'" & f.key & "' must be " & want & ", but it is " &
    (case f.value.kind
     of fvScalar: "a scalar"
     of fvList: "a list"
     of fvMap: "a map"))

proc getStr*(fm: FrontMatter; key: string; default = ""): string =
  ## The scalar for `key`, or `default` when the key is absent. Raises
  ## `FrontMatterError` when the key holds a list or a map.
  let i = fm.find(key)
  if i < 0: return default
  let f = fm.fields[i]
  if f.value.kind != fvScalar: kindError(f, "a scalar")
  f.value.scalar

proc getList*(fm: FrontMatter; key: string): seq[string] =
  ## The list for `key` (empty when the key is absent or written empty).
  ## A scalar is NOT split into a list: `tags: a, b` is a FrontMatterError
  ## here, because YAML reads it as the one string "a, b". Write
  ## `tags: [a, b]`.
  let i = fm.find(key)
  if i < 0: return @[]
  let f = fm.fields[i]
  if f.value.kind == fvScalar and f.value.scalar.len == 0: return @[]
  if f.value.kind != fvList: kindError(f, "a list")
  f.value.items

proc getMap*(fm: FrontMatter; key: string): seq[FrontMatterPair] =
  ## The one-level map for `key`, in source order (empty when absent or
  ## written empty).
  let i = fm.find(key)
  if i < 0: return @[]
  let f = fm.fields[i]
  if f.value.kind == fvScalar and f.value.scalar.len == 0: return @[]
  if f.value.kind != fvMap: kindError(f, "a map")
  f.value.entries

proc getBool*(fm: FrontMatter; key: string; default = false): bool =
  ## A YAML 1.2 core-schema boolean (`true`, `True`, `TRUE`, and the same
  ## forms of `false`), or `default` when the key is absent. Any other
  ## value is a `FrontMatterError` naming the line.
  let i = fm.find(key)
  if i < 0: return default
  let f = fm.fields[i]
  if f.value.kind != fvScalar: kindError(f, "a boolean")
  case f.value.scalar
  of "true", "True", "TRUE": true
  of "false", "False", "FALSE": false
  else: fail(f.line, "'" & key & "' must be true or false, got '" & f.value.scalar & "'")

proc getInt*(fm: FrontMatter; key: string; default = 0): int =
  ## A decimal integer (optionally signed), or `default` when the key is
  ## absent. Any other value is a `FrontMatterError` naming the line.
  let i = fm.find(key)
  if i < 0: return default
  let f = fm.fields[i]
  if f.value.kind != fvScalar: kindError(f, "an integer")
  try:
    parseInt(f.value.scalar)
  except ValueError:
    fail(f.line, "'" & key & "' must be an integer, got '" & f.value.scalar & "'")

proc without*(fm: FrontMatter; known: openArray[string]): FrontMatter =
  ## The fields whose keys are not in `known`, in source order: what a
  ## consumer passes through as "everything else" after reading its own
  ## keys.
  for f in fm.fields:
    if f.key notin known:
      result.fields.add f
