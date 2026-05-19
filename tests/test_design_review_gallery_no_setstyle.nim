## REV-M7 — lexer source scan asserting the gallery overlay path
## avoids ``setStyle`` outside string literals.
##
## Scans ``gallery_overlay.nim`` and ``preview_chrome.nim``. The
## REV-M2 ``brief_tab`` scan covers a similar invariant for that
## view's path; this is the REV-M7 equivalent.

import std/[unittest, strutils, os]

const
  RepoRoot = currentSourcePath().parentDir().parentDir()
  GalleryPath = RepoRoot / "src/isonim/editor/views/gallery_overlay.nim"
  PreviewChromePath = RepoRoot / "src/isonim/editor/views/preview_chrome.nim"

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
  ## ``createElement`` is allowed in tests (MockRenderer.createElement is
  ## the canonical mock-DOM helper) but NOT in editor views.  Anything
  ## bigger than the basic identifier must be inside the ``ui:`` DSL.
  scanForToken(path, "createElement")

suite "REV-M7 gallery view dogfooding":

  test "test_gallery_view_uses_ui_dsl_not_setstyle":
    let hits = scanForToken(GalleryPath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets in gallery_overlay: ", hits
    check hits.len == 0

  test "preview_chrome_path_does_not_use_setstyle":
    let hits = scanForToken(PreviewChromePath, "setStyle")
    if hits.len > 0:
      echo "setStyle found at byte offsets in preview_chrome: ", hits
    check hits.len == 0

  test "gallery_view_does_not_use_raw_create_element":
    let hits = scanForRawCreateElement(GalleryPath)
    if hits.len > 0:
      echo "raw createElement found in gallery_overlay: ", hits
    check hits.len == 0

  test "preview_chrome_does_not_use_raw_create_element":
    let hits = scanForRawCreateElement(PreviewChromePath)
    if hits.len > 0:
      echo "raw createElement found in preview_chrome: ", hits
    check hits.len == 0
