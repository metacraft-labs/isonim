## Static-vocabulary tests: a renderer-declared vocabulary checked
## at compile time.
##
## Positive: a valid template against the fixture vocabulary compiles and
## builds the expected tree (the hook firing on valid code would break this
## file's own compilation). That includes procs whose `ui(r)` block returns
## an element that requires a parent: the parent of a block's top-level
## elements is unknown, so the nesting rule is skipped for them.
## Negative: `nim check` on each fixture in
## `tests/dsl/vocabulary/compile_fail/` fails with the expected stable
## diagnostic, and the report is shaped for the template author: the first
## output line is the fixture's own `file(line, col)`, there is no VM
## `stack trace:`, the first `Error:` line is attributed to the fixture at
## the offending element's line, and the vocabulary module is never named.
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
import isonim/core/[owner, batch, computation]
import isonim/testing/mock_dom
import isonim/dsl/[ui, vocabulary]
import dsl/vocabulary/fixture_renderer

proc sectionBlock(r: VocabRenderer; label: string): MockNode =
  ## Data-only component whose block's top-level element (`mailSection`)
  ## requires a parent (`mailDocument`) that only the caller provides.
  ui(r):
    mailSection(padding = "8px"):
      mailColumn:
        p: text label

proc columnBlock(r: VocabRenderer; label: string): MockNode =
  ## Same, one level down: `mailColumn` requires a `mailSection` parent.
  ui(r):
    mailColumn:
      p: text label

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

  test "a proc's top-level element needing a parent composes":
    createRoot do (dispose: proc()):
      let r = VocabRenderer()
      let root = ui(r):
        mailDocument:
          sectionBlock(r, "first")
          mailSection:
            columnBlock(r, "second")
      check root.tag == "mailDocument"
      check root.children.len == 2
      let s1 = root.children[0]
      check s1.tag == "mailSection"
      check s1.styles["padding"] == "8px"
      check s1.children[0].tag == "mailColumn"
      check s1.children[0].children[0].textContent == "first"
      let s2 = root.children[1]
      check s2.tag == "mailSection"
      check s2.children[0].tag == "mailColumn"
      check s2.children[0].children[0].textContent == "second"

suite "static vocabulary — checkElement":
  # `staticVocabulary` is compile-time only, so the messages are computed
  # into constants and asserted at run time.
  const topUnknown = checkElement(staticVocabulary(VocabRenderer),
    "mailColumn", [], ["width"], "", parentKnown = false)
  const topKnown = checkElement(staticVocabulary(VocabRenderer),
    "mailColumn", [], ["width"], "")
  const docTopUnknown = checkElement(staticVocabulary(VocabRenderer),
    "mailDocument", [], [], "", parentKnown = false)
  const docTopKnown = checkElement(staticVocabulary(VocabRenderer),
    "mailDocument", [], [], "")
  const docNested = checkElement(staticVocabulary(VocabRenderer),
    "mailDocument", [], [], "mailSection")
  const forbiddenDefault = checkElement(staticVocabulary(VocabRenderer),
    "script", [], [], "mailColumn")
  const forbiddenOwnCode = checkElement(staticVocabulary(VocabRenderer),
    "section", [], [], "mailColumn")
  const nestingAlt = checkElement(staticVocabulary(VocabRenderer),
    "table", [], [], "mailSection")
  const nestingNoAlt = checkElement(staticVocabulary(VocabRenderer),
    "p", [], [], "mailSection")

  test "an unknown parent skips the nesting rule; a known root keeps it":
    check topUnknown == ""
    check topKnown.startsWith("E-STRUCT-NESTING: 'mailColumn' must not " &
      "appear at the top level")
    check docTopUnknown == ""
    check docTopKnown == ""
    check docNested.startsWith("E-STRUCT-NESTING: 'mailDocument' must be " &
      "the top-level element of its ui block")

  test "forbidden entries report their own code or the default":
    check ForbiddenTag(tag: "x", reason: "y").code == "E-VOCAB-FORBIDDEN-TAG"
    check forbiddenDefault.startsWith("E-VOCAB-FORBIDDEN-TAG: 'script'")
    check forbiddenOwnCode.startsWith("E-A11Y-SECTIONING: 'section' is " &
      "forbidden")
    check "Use 'mailSection' instead." in forbiddenOwnCode

  test "nesting violations name the tag's alternative when it has one":
    check nestingAlt.startsWith("E-STRUCT-NESTING: 'table' must not be a " &
      "child of 'mailSection'")
    check nestingAlt.endsWith(" Use 'mailTable' instead.")
    check nestingNoAlt.startsWith("E-STRUCT-NESTING: 'p'")
    check "instead" notin nestingNoAlt

const testsDir = parentDir(currentSourcePath())
const repoRoot = parentDir(testsDir)

type FixtureExpect = object
  wants: seq[string]
    ## Every `# expect:` line; all must appear in the first error.
  wantLine: int

proc readExpect(path: string): FixtureExpect =
  for line in lines(path):
    if line.startsWith("# expect:"):
      result.wants.add line[len("# expect:") .. ^1].strip()
    elif line.startsWith("# expect-line:"):
      result.wantLine = parseInt(line[len("# expect-line:") .. ^1].strip())
  doAssert result.wants.len > 0, path & ": missing '# expect:' header"
  doAssert result.wantLine > 0, path & ": missing '# expect-line:' header"

proc nimCheck(path: string): tuple[output: string, exitCode: int] =
  let nim = findExe("nim")
  doAssert nim.len > 0, "nim not on PATH (run under nix develop)"
  result = execCmdEx(
    nim & " check --hints:off " & quoteShell(path) & " 2>&1",
    workingDir = repoRoot)

proc firstErrorLine(lines: seq[string]): string =
  for line in lines:
    if " Error: " in line:
      return line
  return ""

suite "static vocabulary — compile failures":
  test "fixtures fail with the documented diagnostics at the template":
    var count = 0
    for path in walkFiles(testsDir / "dsl" / "vocabulary" / "compile_fail" /
        "*.nim"):
      checkpoint extractFilename(path)
      let exp = readExpect(path)
      let (output, exitCode) = nimCheck(path)
      checkpoint output
      var lines: seq[string] = @[]
      for line in output.splitLines:
        if line.strip.len > 0:
          lines.add line
      check exitCode != 0
      check lines.len > 0
      # The very first line cites the template file itself: no VM
      # `stack trace:` header and no framework module ahead of it.
      if lines.len > 0:
        check lines[0].startsWith(path & "(")
      check "stack trace" notin output
      check "vocabulary.nim" notin output
      # The first error is attributed to the template, at the element.
      let err = firstErrorLine(lines)
      check err.startsWith(path & "(" & $exp.wantLine & ", ")
      for want in exp.wants:
        check want in err
      inc count
    # The static-vocabulary checks: unknown tag, unknown attr, forbidden
    # (default code and own code), nesting (plain, with an alternative, and
    # a nested document root), proc-as-element.
    check count == 8
