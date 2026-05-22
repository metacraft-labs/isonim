## TBAR-M2 — lexer source scan asserting the choice-group widget path
## avoids ``setStyle`` and raw ``createElement`` outside the ``ui:``
## DSL. Mirrors the REV-M7 scan
## ``test_design_review_gallery_no_setstyle.nim``.
##
## Scans:
##   * ``src/isonim/editor/views/widgets/choice_group.nim`` — the
##     widget itself.
##   * ``src/isonim/editor/views/widgets.nim`` — the façade
##     re-exporter.
##
## The scan walks the file with a small hand-written lexer that
## strips comments + string literals so a string like ``"setStyle"``
## inside a doc comment doesn't fool the check.

import std/[unittest, strutils, os]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  WidgetPath =
    RepoRoot / "src/isonim/editor/views/widgets/choice_group.nim"
  FacadePath = RepoRoot / "src/isonim/editor/views/widgets.nim"

type
  LexerState = enum
    lsCode
    lsLineComment
    lsBlockComment
    lsString
    lsTripleString
    lsRawString

proc collectCodeRegions(src: string): string =
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
        result.add ' '
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
  let src = readFile(path)
  let codeOnly = collectCodeRegions(src)
  result = @[]
  var offset = 0
  while offset < codeOnly.len:
    let hit = codeOnly.find(forbidden, offset)
    if hit < 0: break
    let before = if hit > 0: codeOnly[hit - 1] else: '\0'
    let afterIdx = hit + forbidden.len
    let after = if afterIdx < codeOnly.len: codeOnly[afterIdx] else: '\0'
    proc isIdent(c: char): bool =
      c.isAlphaAscii or c.isDigit or c == '_'
    if not isIdent(before) and not isIdent(after):
      result.add hit
    offset = hit + forbidden.len

proc scanForRawCreateElement(path: string): seq[int] =
  ## ``createElement`` is allowed in tests + the renderer adapter (the
  ## DOM/Mock helpers define it) but NOT in editor view files. Every
  ## element constructed in a widget must come from the ``ui:`` DSL.
  scanForToken(path, "createElement")

suite "TBAR-M2 choice-group view dogfooding":

  test "test_choice_group_widget_uses_ui_dsl_not_setstyle":
    let hits = scanForToken(WidgetPath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets in choice_group: ", hits
    check hits.len == 0

  test "test_choice_group_widget_does_not_use_raw_create_element":
    let hits = scanForRawCreateElement(WidgetPath)
    if hits.len > 0:
      echo "raw createElement found in choice_group: ", hits
    check hits.len == 0

  test "test_widgets_facade_uses_ui_dsl_not_setstyle":
    let hits = scanForToken(FacadePath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets in widgets facade: ", hits
    check hits.len == 0

  test "test_widgets_facade_does_not_use_raw_create_element":
    let hits = scanForRawCreateElement(FacadePath)
    if hits.len > 0:
      echo "raw createElement found in widgets facade: ", hits
    check hits.len == 0

  test "test_choice_group_widget_does_not_depend_on_isonim_examples":
    ## The widget lives in ``isonim`` and is framework-level — any
    ## ``isonim_examples`` import here would be a layering violation.
    ## The scan strips doc-comments + string literals so a passing
    ## mention of the sibling repo's name in a doc comment is fine —
    ## only code-level references count as a dependency.
    let widgetCode = collectCodeRegions(readFile(WidgetPath))
    check widgetCode.find("isonim_examples") < 0
    check widgetCode.find("isonim-examples") < 0
    check widgetCode.find("isonim/examples") < 0
    let facadeCode = collectCodeRegions(readFile(FacadePath))
    check facadeCode.find("isonim_examples") < 0
    check facadeCode.find("isonim-examples") < 0
    check facadeCode.find("isonim/examples") < 0
