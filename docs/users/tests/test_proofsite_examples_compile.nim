## ../isonim/docs/users -- every `nim runnable` fence in the real
## content/ dir compiles (C-target only, shells out to the real `nim`
## compiler).
##
## Moved here from isonim-docs' own
## `tests/docs/test_proofsite_examples_compile.nim` (M1 corrective
## deliverable 4): walks this site's own real `content/` dir through the
## same manifest + content-loader + markdown pipeline, extracts every
## `nim runnable` fence verbatim, and shells out to a real
## `nim c --compileOnly`.
##
## Each example is written below this package's `build/` directory, so Nim
## applies this package's own `config.nims` to it exactly as it does to the
## site itself (Nim runs every `config.nims` in the parent directories of
## the compiled module). That file is the one declaration of the search
## paths; an example sees the same paths a reader's code in this package
## would, and this test keeps no copy of them that could drift.

import std/[unittest, os, osproc, streams, strutils]
import core/content
import core/routes
import core/markdown_vm

const RunnableTag = "nim runnable"

type
  RunnableExample = object
    routePath: string
    contentPath: string
    index: int
    code: string

proc collectRunnableExamples(contentDir: string; manifest: RouteManifest): seq[RunnableExample] =
  for entry in manifest.entries:
    if entry.pageKind == pkRedirect or entry.meta.contentPath.len == 0:
      continue
    try:
      let content = loadContentEntry(contentDir, entry.meta.contentPath)
      let doc = parseMarkdownDoc(content.page.body, entry.meta.contentPath)
      var idx = 0
      for blk in doc.blocks:
        if blk.kind == bkCodeFence and blk.lang == RunnableTag:
          inc idx
          result.add RunnableExample(routePath: entry.canonicalPath,
            contentPath: entry.meta.contentPath, index: idx, code: blk.code)
    except CatchableError:
      discard

proc compileExample(tmpDir: string; ex: RunnableExample): tuple[ok: bool, output: string] =
  ## Compiles one example from `tmpDir`, which must lie inside this package
  ## so that its `config.nims` supplies the search paths. The nimcache goes
  ## inside `tmpDir` too, so removing `tmpDir` leaves nothing behind.
  var safeName = ""
  for c in ex.contentPath:
    if c in IdentChars: safeName.add c
    else: safeName.add '_'
  let filePath = tmpDir / ("ex_" & $ex.index & "_" & safeName & ".nim")
  writeFile(filePath, ex.code)
  let args = @["c", "--compileOnly", "--hints:off",
               "--nimcache:" & (tmpDir / "nimcache"), filePath]
  var p = startProcess("nim", args = args, options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  close(p)
  (exitCode == 0, output)

suite "IsoNim docs site examples -- every `nim runnable` fence in the real content/ dir compiles (Tier 3, C-target)":
  test "extracting and compiling every real content/ dir `nim runnable` fence succeeds":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let contentDir = repoRoot / "content"
    let examples = collectRunnableExamples(contentDir, docsRouteManifest())
    check examples.len >= 4
    # Inside this package (under the git-ignored `build/`), not the system
    # temp directory: see the module comment.
    let tmpDir = repoRoot / "build" / ("runnable-examples-" & $getCurrentProcessId())
    createDir(tmpDir)
    try:
      for ex in examples:
        let (ok, output) = compileExample(tmpDir, ex)
        checkpoint ex.contentPath & " runnable example #" & $ex.index & ":\n" & output
        check ok
    finally:
      removeDir(tmpDir)
