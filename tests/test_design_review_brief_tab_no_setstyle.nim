## REV-M2: Lexer-based source scan asserting the brief tab view path
## avoids ``setStyle`` outside string literals.
##
## The scan is intentionally tolerant of:
##
## - ``"setStyle"`` appearing inside double-quoted string literals
##   (comments and docstrings reach the lexer with a string-literal
##   shape only when they live in ``"""…"""`` blocks, which we treat as
##   string-literal regions too).
## - The token appearing inside a line comment (``# … setStyle …``).
##
## Any other occurrence is a test failure: the milestone forbids
## ``setStyle`` calls in editor views (the ``ui:`` DSL is the only
## allowed avenue for style application).

import std/[unittest, strutils, os]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  BriefTabPath = RepoRoot / "src/isonim/editor/views/brief_tab.nim"
  PreviewPanePath = RepoRoot / "src/isonim/editor/views/preview_pane.nim"

type
  LexerState = enum
    lsCode
    lsLineComment
    lsBlockComment   ## ``#[ ... ]#`` (nested by counting depth)
    lsString         ## "..." (single-line, with backslash escapes)
    lsTripleString   ## """ ... """
    lsRawString      ## r"..."

proc collectCodeRegions(src: string): string =
  ## Strip every region the brief tab is allowed to use ``setStyle``
  ## inside (string literals + comments).  The remaining bytes are
  ## code positions, where the token MUST NOT appear.
  result = newStringOfCap(src.len)
  var i = 0
  var state = lsCode
  var blockDepth = 0
  while i < src.len:
    let ch = src[i]
    let next = if i + 1 < src.len: src[i+1] else: '\0'
    let next2 = if i + 2 < src.len: src[i+2] else: '\0'
    case state
    of lsCode:
      if ch == '#' and next == '[':
        state = lsBlockComment
        blockDepth = 1
        inc i, 2
      elif ch == '#':
        state = lsLineComment
        inc i
      elif ch == 'r' and next == '"':
        state = lsRawString
        inc i, 2
      elif ch == '"' and next == '"' and next2 == '"':
        state = lsTripleString
        inc i, 3
      elif ch == '"':
        state = lsString
        inc i
      elif ch == '\'':
        # Character literal: skip to closing '.
        result.add ' '   # whitespace stand-in
        inc i
        while i < src.len and src[i] != '\'':
          if src[i] == '\\' and i + 1 < src.len: inc i
          inc i
        if i < src.len: inc i
      else:
        result.add ch
        inc i
    of lsLineComment:
      if ch == '\n':
        result.add '\n'
        state = lsCode
      inc i
    of lsBlockComment:
      if ch == '#' and next == '[':
        inc blockDepth
        inc i, 2
      elif ch == ']' and next == '#':
        dec blockDepth
        inc i, 2
        if blockDepth == 0:
          state = lsCode
      else:
        inc i
    of lsString:
      if ch == '\\' and i + 1 < src.len:
        inc i, 2
      elif ch == '"':
        state = lsCode
        inc i
      elif ch == '\n':
        state = lsCode
        inc i
      else:
        inc i
    of lsTripleString:
      if ch == '"' and next == '"' and next2 == '"':
        state = lsCode
        inc i, 3
      else:
        inc i
    of lsRawString:
      if ch == '"' and next == '"':
        inc i, 2
      elif ch == '"':
        state = lsCode
        inc i
      else:
        inc i

proc scanForToken(path: string; forbidden: string): seq[int] =
  ## Lex the file at ``path``, return every byte offset where
  ## ``forbidden`` appears in a code position. Empty result means the
  ## file is clean.
  let src = readFile(path)
  let codeOnly = collectCodeRegions(src)
  result = @[]
  var offset = 0
  while offset < codeOnly.len:
    let hit = codeOnly.find(forbidden, offset)
    if hit < 0: break
    # Confirm it's a complete identifier (no leading/trailing ident
    # bytes), so something like ``setStylesheet`` doesn't trip the
    # scan.
    let before = if hit > 0: codeOnly[hit - 1] else: '\0'
    let afterIdx = hit + forbidden.len
    let after = if afterIdx < codeOnly.len: codeOnly[afterIdx] else: '\0'
    proc isIdent(c: char): bool =
      c.isAlphaAscii or c.isDigit or c == '_'
    if not isIdent(before) and not isIdent(after):
      result.add hit
    offset = hit + forbidden.len

suite "REV-M2 brief tab view dogfooding":

  test "test_brief_tab_view_uses_ui_dsl_not_setstyle":
    let hits = scanForToken(BriefTabPath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets: ", hits
    check hits.len == 0

  test "brief_tab_scan_recognises_string_literals":
    ## Sanity: the lexer must NOT flag a setStyle reference that lives
    ## inside a regular comment or string literal. Build a tiny
    ## fragment and confirm scanForToken on it returns no hits.
    const fragment = "let x = \"setStyle is fine inside a string\"\n# also fine in a # setStyle comment\n"
    let tmp = getTempDir() / "isonim_revm2_scan_fragment.nim"
    writeFile(tmp, fragment)
    let hits = scanForToken(tmp, "setStyle")
    removeFile(tmp)
    check hits.len == 0

  test "preview_pane_mount_path_does_not_use_setstyle":
    let hits = scanForToken(PreviewPanePath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets in preview_pane: ", hits
    check hits.len == 0
