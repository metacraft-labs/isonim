## ../isonim/docs/users -- every `nim runnable` fence in the real
## content/ dir compiles (C-target only, shells out to the real `nim`
## compiler).
##
## Moved here from isonim-docs' own
## `tests/docs/test_proofsite_examples_compile.nim` (M1 corrective
## deliverable 4): walks this site's own real `content/` dir through the
## same manifest + content-loader + markdown pipeline, extracts every
## `nim runnable` fence verbatim, and shells out to a real
## `nim c --compileOnly` against this repo's own sibling-package search
## paths (mirroring `config.nims`).

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

proc repoSiblingSwitches(siblingRoot: string): seq[string] =
  ## Mirrors this package's own `config.nims`.
  @[
    "--path:" & (siblingRoot / "isonim-docs" / "src"),
    "--path:" & (siblingRoot / "isonim" / "src"),
    "--path:" & (siblingRoot / "isonim-render-serve" / "src"),
    "--path:" & (siblingRoot / "nim-everywhere" / "src"),
    "--path:" & (siblingRoot / "nim-faststreams"),
    "--path:" & (siblingRoot / "nim-stew"),
    "--path:" & (siblingRoot / "isonim" / "vendor" / "chronicles"),
    "--path:" & (siblingRoot / "isonim" / "vendor" / "serialization"),
    "--path:" & (siblingRoot / "isonim" / "vendor" / "json_serialization"),
    "--define:chronicles_sinks=textlines[stderr]",
  ]

proc compileExample(tmpDir, siblingRoot: string; ex: RunnableExample): tuple[ok: bool, output: string] =
  var safeName = ""
  for c in ex.contentPath:
    if c in IdentChars: safeName.add c
    else: safeName.add '_'
  let filePath = tmpDir / ("ex_" & $ex.index & "_" & safeName & ".nim")
  writeFile(filePath, ex.code)
  let args = @["c", "--compileOnly", "--hints:off"] & repoSiblingSwitches(siblingRoot) & @[filePath]
  var p = startProcess("nim", args = args, options = {poUsePath, poStdErrToStdOut})
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  close(p)
  (exitCode == 0, output)

suite "IsoNim docs site examples -- every `nim runnable` fence in the real content/ dir compiles (Tier 3, C-target)":
  test "extracting and compiling every real content/ dir `nim runnable` fence succeeds":
    let repoRoot = currentSourcePath().parentDir().parentDir()
    let siblingRoot = repoRoot.parentDir().parentDir().parentDir() # .../codetracer-ci-refactor/
    let contentDir = repoRoot / "content"
    let examples = collectRunnableExamples(contentDir, docsRouteManifest())
    check examples.len >= 4
    let tmpDir = getTempDir() / "isonim_docs_users_proofsite_examples_" & $getCurrentProcessId()
    createDir(tmpDir)
    try:
      for ex in examples:
        let (ok, output) = compileExample(tmpDir, siblingRoot, ex)
        checkpoint ex.contentPath & " runnable example #" & $ex.index & ":\n" & output
        check ok
    finally:
      removeDir(tmpDir)
