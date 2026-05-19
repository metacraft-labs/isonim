## REV-M5 — workspace clean-tree gate unit tests.
##
## Each test builds an ephemeral tmpdir mini-workspace containing
## two synthetic git repos and a minimal ``.repo/manifest.xml``,
## then runs ``checkCleanTree`` against it.  No global state.

import std/[os, osproc, streams, strutils, times, unittest]

import isonim/editor/design_review/clean_tree

# ---------------------------------------------------------------------------
# Tmp workspace builder
# ---------------------------------------------------------------------------

proc runOrFail(cmd: string; cwd: string) =
  let p = startProcess("sh", args = @["-c", cmd], workingDir = cwd,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let code = p.waitForExit()
  if code != 0:
    let stdOut = p.outputStream.readAll()
    raise newException(IOError, cmd & " failed (" & $code & "):\n" & stdOut)

proc initRepo(repoPath: string;
              initialFiles: seq[(string, string)] = @[]): string =
  ## Initialise a git repo with a synthetic identity, an initial
  ## commit, and return the HEAD SHA.
  createDir(repoPath)
  runOrFail("git init -q -b main", repoPath)
  runOrFail("git config user.email 'test@test'", repoPath)
  runOrFail("git config user.name 'tester'", repoPath)
  runOrFail("git config commit.gpgsign false", repoPath)
  for (name, body) in initialFiles:
    writeFile(repoPath / name, body)
  runOrFail("git add -A && git commit -q -m initial " &
            "--allow-empty", repoPath)
  let res = execCmdEx("git -C " & quoteShell(repoPath) & " rev-parse HEAD")
  result = res.output.strip()

proc writeManifest(workspaceRoot: string;
                   entries: openArray[tuple[name, path, revision: string]]) =
  let repoDir = workspaceRoot / ".repo"
  createDir(repoDir)
  var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest>\n"
  for e in entries:
    xml.add "  <project name=\"" & e.name & "\" path=\"" & e.path &
            "\" revision=\"" & e.revision & "\"/>\n"
  xml.add "</manifest>\n"
  writeFile(repoDir / "manifest.xml", xml)

proc makeWorkspace(suffix: string): string =
  let base = getTempDir() / ("isonim_clean_tree_" & suffix &
                              "_" & $epochTime().int)
  removeDir(base)
  createDir(base)
  base

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

suite "REV-M5 clean tree gate":

  test "test_clean_tree_gate_passes_on_clean_workspace":
    let ws = makeWorkspace("clean")
    defer: removeDir(ws)
    let aSha = initRepo(ws / "repo-a", @[("README.md", "a\n")])
    let bSha = initRepo(ws / "repo-b", @[("README.md", "b\n")])
    writeManifest(ws, [
      (name: "repo-a", path: "repo-a", revision: aSha),
      (name: "repo-b", path: "repo-b", revision: bSha),
    ])
    let status = checkCleanTree(ws)
    check status.ok
    check status.dirty.len == 0

  test "test_clean_tree_gate_reports_dirty_files":
    let ws = makeWorkspace("dirty")
    defer: removeDir(ws)
    let aSha = initRepo(ws / "repo-a", @[("README.md", "a\n")])
    let bSha = initRepo(ws / "repo-b", @[("README.md", "b\n")])
    # Modify repo-a's README so the working tree is dirty.
    writeFile(ws / "repo-a" / "README.md", "a (edited)\n")
    writeManifest(ws, [
      (name: "repo-a", path: "repo-a", revision: aSha),
      (name: "repo-b", path: "repo-b", revision: bSha),
    ])
    let status = checkCleanTree(ws)
    check (not status.ok)
    check status.dirty.len == 1
    check status.dirty[0].reason == drUncommitted
    check status.dirty[0].files == @["README.md"]

  test "test_clean_tree_gate_reports_unpinned_head":
    let ws = makeWorkspace("unpinned")
    defer: removeDir(ws)
    let aSha = initRepo(ws / "repo-a", @[("README.md", "a\n")])
    let _ = initRepo(ws / "repo-b", @[("README.md", "b\n")])
    # Manifest pins repo-b to repo-a's SHA — guaranteed mismatch.
    writeManifest(ws, [
      (name: "repo-a", path: "repo-a", revision: aSha),
      (name: "repo-b", path: "repo-b", revision: aSha),
    ])
    let status = checkCleanTree(ws)
    check (not status.ok)
    var found = false
    for report in status.dirty:
      if report.reason == drUnpinnedHead:
        found = true
        check report.headSha.len == 40
        check report.expectedPin.len == 40
        check report.headSha != report.expectedPin
    check found

  test "test_clean_tree_gate_reports_untracked_files":
    let ws = makeWorkspace("untracked")
    defer: removeDir(ws)
    let aSha = initRepo(ws / "repo-a", @[("README.md", "a\n")])
    let bSha = initRepo(ws / "repo-b", @[("README.md", "b\n")])
    # Add an untracked file in repo-a.
    writeFile(ws / "repo-a" / "foo.txt", "untracked!\n")
    writeManifest(ws, [
      (name: "repo-a", path: "repo-a", revision: aSha),
      (name: "repo-b", path: "repo-b", revision: bSha),
    ])
    let status = checkCleanTree(ws)
    check (not status.ok)
    var matched = false
    for report in status.dirty:
      if report.reason == drUntracked:
        matched = true
        check report.files == @["foo.txt"]
    check matched
