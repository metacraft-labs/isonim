## Historical REV-M2 entrypoint, now guarding current Spec pane style discipline.
## Reads the actual production view and uses real temporary source files for
## lexer/scope controls. No renderer, filesystem or compiler APIs are mocked.
## The ui DSL constructs the view; imperative styles belong only to reactive
## effects. The removed Brief/Preview views and custom Markdown renderer remain
## superseded by Spec/TipTap rather than being restored.

import std/[unittest, strutils, os, tempfiles]

const RepoRoot = currentSourcePath().parentDir().parentDir()
const SpecPanePath = RepoRoot / "src/isonim/editor/views/spec_pane.nim"

type
  LexerState = enum
    lsCode
    lsLineComment
    lsBlockComment   ## ``#[ ... ]#`` (nested by counting depth)
    lsString         ## "..." (single-line, with backslash escapes)
    lsTripleString   ## """ ... """
    lsRawString      ## r"..."

proc collectCodeRegions(src: string): string =
  ## Mask comments/literals with whitespace, preserving offsets, newlines and
  ## indentation. Tokens on opposite sides must never concatenate.
  result = newString(src.len)
  for i, ch in src:
    result[i] = if ch == '\n': '\n' else: ' '
  var i = 0
  var state = lsCode
  var blockDepth = 0
  while i < src.len:
    let ch = src[i]
    let next = if i + 1 < src.len: src[i + 1] else: '\0'
    let next2 = if i + 2 < src.len: src[i + 2] else: '\0'
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
        inc i
        while i < src.len and src[i] != '\'':
          if src[i] == '\\' and i + 1 < src.len: inc i
          inc i
        if i < src.len: inc i
      else:
        result[i] = ch
        inc i
    of lsLineComment:
      if ch == '\n': state = lsCode
      inc i
    of lsBlockComment:
      if ch == '#' and next == '[':
        inc blockDepth
        inc i, 2
      elif ch == ']' and next == '#':
        dec blockDepth
        inc i, 2
        if blockDepth == 0: state = lsCode
      else: inc i
    of lsString:
      if ch == '\\' and i + 1 < src.len: inc i, 2
      elif ch == '"' or ch == '\n':
        state = lsCode
        inc i
      else: inc i
    of lsTripleString:
      if ch == '"' and next == '"' and next2 == '"':
        state = lsCode
        inc i, 3
      else: inc i
    of lsRawString:
      if ch == '"' and next == '"': inc i, 2
      elif ch == '"':
        state = lsCode
        inc i
      else: inc i

proc scanForToken(path: string; forbidden: string): seq[int] =
  ## Lex the actual source, returning every byte offset where
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

proc outsideEffectStyles(path: string): seq[int] =
  let lines = collectCodeRegions(readFile(path)).splitLines()
  var effectIndent = -1
  for i, line in lines:
    let code = line.strip()
    if code.len == 0: continue
    let indent = line.len - line.strip(leading = true, trailing = false).len
    if effectIndent >= 0 and indent <= effectIndent:
      effectIndent = -1
    if code.startsWith("createRenderEffect proc() ="):
      effectIndent = indent
    if effectIndent < 0 and "setStyle" in code:
      # Keep the identifier boundary semantics of the original lexer.
      var pos = code.find("setStyle")
      while pos >= 0:
        let before = if pos > 0: code[pos - 1] else: '\0'
        let after = if pos + 8 < code.len: code[pos + 8] else: '\0'
        if not (before.isAlphaNumeric or before == '_') and
            not (after.isAlphaNumeric or after == '_'):
          result.add i + 1
        pos = code.find("setStyle", pos + 8)

proc withFragment(body: string; verify: proc(path: string)) =
  let (file, path) = createTempFile("isonim-spec-style-", ".nim")
  file.close()
  try:
    writeFile(path, body)
    verify(path)
  finally:
    removeFile(path)

suite "REV-M2 current Spec pane style discipline":
  test "test_brief_tab_view_uses_ui_dsl_not_setstyle":
    let hits = outsideEffectStyles(SpecPanePath)
    if hits.len > 0: echo "Non-reactive setStyle at lines: ", hits
    check hits.len == 0
    check scanForToken(SpecPanePath, "ui").len > 0
    check scanForToken(SpecPanePath, "createElement").len == 0
    check scanForToken(SpecPanePath, "setStyle").len == 2

  test "brief_tab_scan_recognises_string_literals":
    withFragment("let x = \"setStyle is fine in strings\"\n# setStyle\n#[ outer #[ setStyle ]# ]#\n", proc(path: string) =
      check scanForToken(path, "setStyle").len == 0
      check outsideEffectStyles(path).len == 0)
    withFragment("let a = \"\"\"multiline\nsetStyle\n\"\"\"\nlet b = r\"setStyle\"\nlet c = setStylesheet\n", proc(path: string) =
      check scanForToken(path, "setStyle").len == 0
      check outsideEffectStyles(path).len == 0)

  test "preview_pane_mount_path_does_not_use_setstyle":
    withFragment("proc mount() =\n  let root = ui(r):\n    tdiv(display = \"flex\")\n  createRenderEffect proc() =\n    if visible.val:\n      r.setStyle(root, \"display\", \"flex\")\n", proc(path: string) =
      check scanForToken(path, "setStyle").len == 1
      check outsideEffectStyles(path).len == 0)
    withFragment("proc mount() =\n  r.setStyle(root, \"display\", \"flex\")\n", proc(path: string) =
      check outsideEffectStyles(path) == @[2])
    withFragment("proc mount() =\n  createRenderEffect proc() =\n    r.setStyle(root, \"display\", \"flex\")\n  r.setStyle(root, \"color\", \"red\")\n", proc(path: string) =
      check outsideEffectStyles(path) == @[4])

  test "reactive scope closes at unrelated dedent and masking preserves lines":
    withFragment("proc mount() =\n  createRenderEffect proc() =\n    r.setStyle(root, \"display\", \"flex\")\n  discard ready\n  r.setStyle(root, \"color\", \"red\")\n", proc(path: string) =
      check outsideEffectStyles(path) == @[5])
    withFragment("#[ comment\n   setStyle\n]#\nlet x = \"\"\"text\nsetStyle\n\"\"\"\nproc mount() =\n  createRenderEffect proc() =\n    r.setStyle(root, \"display\", \"flex\")\n  discard ready\n  r.setStyle(root, \"color\", \"red\")\n", proc(path: string) =
      check scanForToken(path, "setStyle").len == 2
      check outsideEffectStyles(path) == @[11])
    withFragment("discard prefix#[ comment ]#setStyle\n", proc(path: string) =
      check scanForToken(path, "setStyle").len == 1
      check outsideEffectStyles(path) == @[1])
