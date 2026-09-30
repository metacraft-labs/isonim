## Static-vocabulary tests: a renderer-declared vocabulary checked
## at compile time.
##
## Positive: a valid template against the fixture vocabulary compiles and
## builds the expected tree (the hook firing on valid code would break this
## file's own compilation). Negative: `nim check` on each fixture in
## `tests/dsl/vocabulary/compile_fail/` fails with the expected stable
## diagnostic code on the expected line.
##
## C backend only: the negative half shells out to `nim check` (the dev
## shell provides it).
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## `VocabRenderer` (`tests/dsl/vocabulary/fixture_renderer`) declares a
## tiny vocabulary and forwards every backend call to MockRenderer, the
## framework's shipped in-memory `RendererBackend`
## (`isonim/testing/mock_dom`) — the real boundary for asserting the
## built tree shape. The negative half uses no mocks at all: it runs
## the real `nim check` over real fixture files. A production renderer
## with a real vocabulary would test that renderer's schema, not the
## compile-time check mechanism this file pins.
import std/[os, osproc, strutils, unittest]
import isonim/core/[owner, batch]
import isonim/testing/mock_dom
import isonim/dsl/ui
import dsl/vocabulary/fixture_renderer

suite "static vocabulary — positive":
  test "valid fixture-vocabulary template builds":
    createRoot do (dispose: proc()):
      let r = VocabRenderer()
      let root = ui(r):
        mailSection(background_color = "#fff", padding = "24px"):
          mailColumn(width = "50%"):
            p: text "hi"

      check root.tag == "mailSection"
      # The style/attr split is the macro's `styleProperties` membership, not
      # the vocabulary kind: background_color is a style prop, so it arrives
      # in styles (the cascade pass merges both for vocabulary elements).
      check root.styles["background-color"] == "#fff"
      check root.styles["padding"] == "24px"
      check root.children.len == 1

      let col = root.children[0]
      check col.tag == "mailColumn"
      check col.styles["width"] == "50%"
      check col.children.len == 1
      check col.children[0].tag == "p"
      check col.children[0].textContent == "hi"

  test "data-only proc used positionally composes":
    createRoot do (dispose: proc()):
      let r = VocabRenderer()
      let root = ui(r):
        mailSection:
          mailColumn:
            footerBlock(r, "foot")
      let foot = root.children[0].children[0]
      check foot.tag == "p"
      check foot.textContent == "foot"

const testsDir = parentDir(currentSourcePath())
const repoRoot = parentDir(testsDir)

type FixtureExpect = object
  want: string
  wantLine: int

proc readExpect(path: string): FixtureExpect =
  for line in lines(path):
    if line.startsWith("# expect:"):
      result.want = line[len("# expect:") .. ^1].strip()
    elif line.startsWith("# expect-line:"):
      result.wantLine = parseInt(line[len("# expect-line:") .. ^1].strip())
  doAssert result.want.len > 0, path & ": missing '# expect:' header"
  doAssert result.wantLine > 0, path & ": missing '# expect-line:' header"

proc nimCheck(path: string): tuple[output: string, exitCode: int] =
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim not on PATH (run under nix develop)"
  result = execCmdEx(
    nim & " check --hints:off " & quoteShell(path) & " 2>&1",
    workingDir = repoRoot)

suite "static vocabulary — compile failures":
  test "fixtures fail with the documented diagnostics":
    var count = 0
    for path in walkFiles(testsDir / "dsl" / "vocabulary" / "compile_fail" /
        "*.nim"):
      let exp = readExpect(path)
      let (output, exitCode) = nimCheck(path)
      check exitCode != 0
      check exp.want in output
      let cited = extractFilename(path) & "(" & $exp.wantLine & ","
      check cited in output
      inc count
    # The five static-vocabulary checks: unknown tag, unknown attr, forbidden, nesting,
    # proc-as-element.
    check count == 5
