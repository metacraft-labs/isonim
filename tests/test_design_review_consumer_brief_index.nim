## A consumer project's editor bundle carries the consumer's own briefs.
##
## The editor spec ("Editor Brief Index") has the build-time walker bake the
## PROJECT's briefs into the editor bundle. A project other than this
## repository's examples does that with `brief_index_build --json-out` and
## `-d:isonimBriefIndexJson=<absolute path>`, without regenerating
## `brief_index_static.nim` in the isonim checkout. This test runs the real
## build tool on a fixture `briefs/` tree, compiles a probe with the
## resulting index, and checks the probe's index is exactly the fixture's;
## the same probe compiled without the define (the control) carries the
## checked-in index instead, so the first result cannot come from it.

import std/[algorithm, os, osproc, strutils, tempfiles, unittest]

const
  Root = currentSourcePath().parentDir.parentDir
  Fixture = Root / "tests" / "fixtures" / "design_review" / "briefs_valid"
  Probe = Root / "tests" / "helpers" / "consumer_brief_index_probe.nim"
  Tool = Root / "src" / "isonim" / "editor" / "design_review" / "brief_index_build.nim"

proc run(cmd: string): string =
  let (output, code) = execCmdEx(cmd, workingDir = Root)
  doAssert code == 0, cmd & "\n" & output
  output

proc probeIds(scratch, define: string): seq[string] =
  let exe = scratch / ("probe" & $define.len)
  discard run("nim c --hints:off --path:src " & define &
    " --nimcache:" & quoteShell(scratch / ("cache" & $define.len)) &
    " -o:" & quoteShell(exe) & " " & quoteShell(Probe))
  result = run(quoteShell(exe)).strip.splitLines
  result.sort()

suite "consumer brief index":
  test "a project's --json-out index is the one its bundle carries":
    let scratch = createTempDir("isonim-consumer-briefs-", "")
    defer: removeDir(scratch)
    let json = scratch / "brief-index.json"
    let staticModule = Root / "src" / "isonim" / "editor" / "design_review" / "brief_index_static.nim"
    let before = readFile(staticModule)
    discard run("nim r --hints:off --path:src " & quoteShell(Tool) &
      " --briefs:" & quoteShell(Fixture) & " --json-out:" & quoteShell(json))
    check fileExists(json)
    # The tool must not have touched the checked-in module.
    check readFile(staticModule) == before
    var expected: seq[string]
    for kind, path in walkDir(Fixture):
      if kind == pcDir:
        for f in walkFiles(path / "*.md"):
          for line in readFile(f).splitLines:
            if line.startsWith("briefId: "):
              expected.add line["briefId: ".len .. ^1].strip
    expected.sort()
    check expected.len == 3
    let consumer = probeIds(scratch, "-d:isonimBriefIndexJson=" & quoteShell(json))
    check consumer == expected
    let control = probeIds(scratch, "")
    check control != expected
    check control.len > 0
