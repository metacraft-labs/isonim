## REV-M6 — brief_at_revision tests.
##
## Each test materialises a tiny ``repo``-shaped workspace on disk:
##
##   <workspace>/
##     .repo/manifest.xml          (single project, revision = HEAD)
##     repo-a/
##       .git/                    (real git repo, committed history)
##       briefs/render/foo.md
##
## We commit, edit, re-commit, optionally touch the working tree to
## prove git's history is consulted (not the file on disk), and then
## assert ``briefAtRevision`` against the captured manifest hash.

import std/[os, osproc, strutils, times, unittest]

import isonim/editor/design_review/brief_at_revision
import isonim/editor/design_review/manifest_hash

# --------------------------------------------------------------------------- #
#  Tiny test workspace builder.
# --------------------------------------------------------------------------- #

proc runOrFail(cmd: string; cwd: string): string =
  let res = execCmdEx(cmd, workingDir = cwd)
  if res.exitCode != 0:
    raise newException(IOError, cmd & " failed (" & $res.exitCode & "):\n" &
                       res.output)
  res.output

proc gitInit(repoPath: string) =
  createDir(repoPath)
  discard runOrFail("git init -q -b main && " &
                    "git config user.email 'test@test' && " &
                    "git config user.name 'tester' && " &
                    "git config commit.gpgsign false",
                    repoPath)

proc gitCommit(repoPath, message: string): string =
  discard runOrFail("git add -A && git commit -q -m '" & message & "'",
                    repoPath)
  return runOrFail("git rev-parse HEAD", repoPath).strip()

proc writeManifest(workspaceRoot, repoName, sha: string) =
  let repoDir = workspaceRoot / ".repo"
  createDir(repoDir)
  writeFile(repoDir / "manifest.xml",
    "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<manifest>\n" &
    "  <project name=\"" & repoName & "\" path=\"" & repoName &
    "\" revision=\"" & sha & "\"/>\n</manifest>\n")

proc tmpWorkspace(suffix: string): string =
  result = getTempDir() / ("isonim_bav_" & suffix & "_" & $epochTime().int)
  removeDir(result)
  createDir(result)

# --------------------------------------------------------------------------- #
#  Tests.
# --------------------------------------------------------------------------- #

suite "REV-M6 brief_at_revision":

  test "test_brief_at_revision_returns_historical_content":
    let ws = tmpWorkspace("history")
    defer: removeDir(ws)
    let repoA = ws / "repo-a"
    gitInit(repoA)
    createDir(repoA / "briefs" / "render")
    let briefPath = repoA / "briefs" / "render" / "foo.md"
    writeFile(briefPath, "---\nbriefId: render.foo\n---\nbody-v1\n")
    let shaA = gitCommit(repoA, "initial brief")
    writeManifest(ws, "repo-a", shaA)
    let hashA = captureManifestHash(ws)

    # Edit + recommit; new manifest hash.
    writeFile(briefPath, "---\nbriefId: render.foo\n---\nbody-v2\n")
    let shaB = gitCommit(repoA, "update brief")
    writeManifest(ws, "repo-a", shaB)
    let hashB = captureManifestHash(ws)

    # Sanity: hashes differ.
    check hashA != hashB

    # Resolve against hash A.  We need the workspace's current
    # manifest to match A; checkout the manifest XML for A.
    writeManifest(ws, "repo-a", shaA)
    # Touch the working tree — `briefAtRevision` must not see this.
    writeFile(briefPath, "WORKING_TREE_GARBAGE\n")

    let bodyAtA = briefAtRevision(ws, hashA, "render.foo")
    check bodyAtA.contains("body-v1")
    check (not bodyAtA.contains("body-v2"))

    # Resolve against hash B.
    writeManifest(ws, "repo-a", shaB)
    let bodyAtB = briefAtRevision(ws, hashB, "render.foo")
    check bodyAtB.contains("body-v2")

  test "test_brief_at_revision_handles_missing_file":
    let ws = tmpWorkspace("missing")
    defer: removeDir(ws)
    let repoA = ws / "repo-a"
    gitInit(repoA)
    createDir(repoA / "briefs" / "render")
    let briefPath = repoA / "briefs" / "render" / "foo.md"
    writeFile(briefPath, "---\nbriefId: render.foo\n---\nv1\n")
    let shaA = gitCommit(repoA, "initial brief")

    # Rename + commit.  The brief no longer exists at this path under
    # the new revision.
    moveFile(briefPath, repoA / "briefs" / "render" / "renamed.md")
    discard runOrFail("git add -A", repoA)
    let shaB = gitCommit(repoA, "rename brief")

    writeManifest(ws, "repo-a", shaA)
    let hashA = captureManifestHash(ws)
    let bodyA = briefAtRevision(ws, hashA, "render.foo")
    check bodyA.contains("v1")

    writeManifest(ws, "repo-a", shaB)
    let hashB = captureManifestHash(ws)
    expect BriefNotFoundAtRevisionError:
      discard briefAtRevision(ws, hashB, "render.foo")
