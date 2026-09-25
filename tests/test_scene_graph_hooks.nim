## SGR-M1: the scene-graph seam.
##
## Two properties, and the first one is the reason the feature is allowed to
## exist at all: a production build must pay NOTHING. Not a branch, not a
## string, not an attribute stripped later. The second is that an editor build
## records the hierarchy the `ui` DSL actually nests.
##
## No mocks. The zero-cost arm compiles a real fixture through the real DSL
## with the real backend and reads the generated JavaScript; asserting on
## anything less would not be evidence about what ships.

import std/[unittest, os, osproc, strutils, strformat]

const
  repoRoot = currentSourcePath().parentDir.parentDir
  srcPath = repoRoot / "src"

proc buildFixture(defines, outFile, cacheDir: string): tuple[ok: bool, js: string] =
  ## Compile the fixture to JS and return its text.
  let fixture = repoRoot / "tests" / "fixtures" / "scene_graph_fixture.nim"
  removeDir(cacheDir)
  let cmd = &"nim js --hints:off --verbosity:0 --path:{srcPath} {defines} " &
            &"--nimcache:{cacheDir} -o:{outFile} {fixture}"
  let (_, code) = execCmdEx(cmd)
  if code != 0 or not fileExists(outFile):
    return (false, "")
  (true, readFile(outFile))

suite "SGR-M1 scene-graph seam":

  test "a production build carries no trace of the scene graph":
    let outFile = getTempDir() / "sgr_prod.js"
    let (ok, js) = buildFixture("", outFile, getTempDir() / "sgr_prod_cache")
    check ok

    # The recorder must not be reachable.
    check not js.contains("recordElement")

    # No source path may leak. This is a privacy property as much as a size
    # one: `lineInfo` names the author's filesystem, and a public bundle must
    # not carry it.
    check not js.contains("scene_graph_fixture.nim:")

    # NOTE ON WHICH ASSERTION IS LOAD-BEARING. The source-path check above is
    # the one with teeth, and that was established rather than assumed: with
    # the production template deliberately changed to USE its parameters
    # (`sink = loc & tag & id & parentId`), this test fails on exactly that
    # line. An earlier version of this test also looked for a sentinel string
    # passed through an ignored argument; it passed under the same sabotage,
    # because Nim elides `discard <literal>` regardless, so it was proving
    # nothing and has been removed. A test that cannot fail is worse than no
    # test: it reports a property nobody is checking.

  test "an editor build records the hierarchy the DSL nests":
    let outFile = getTempDir() / "sgr_ed.js"
    let (ok, js) = buildFixture("-d:isonimEditor", outFile,
                                getTempDir() / "sgr_ed_cache")
    check ok
    check js.contains("recordElement")

  test "parent linkage matches the source nesting":
    # Run the fixture natively so it can print what it recorded; the shape of
    # the tree is the claim, not the fact that a symbol appears in a bundle.
    let exe = getTempDir() / "sgr_native"
    let fixture = repoRoot / "tests" / "fixtures" / "scene_graph_fixture.nim"
    let (output, code) = execCmdEx(
      &"nim c -r --hints:off --verbosity:0 --path:{srcPath} -d:isonimEditor " &
      &"-o:{exe} {fixture}")
    check code == 0
    # root div -> (span, row div); row div -> cell div. Four elements, and
    # every non-root names a real parent.
    check output.contains("nodes=4")
    check output.contains("root=1")     ## exactly one element with no parent
    check output.contains("orphans=0")  ## every parent id resolves
