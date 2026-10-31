## REV-M5 — workspace clean-tree gate unit tests.
##
## Each test builds a hermetic reprobuild workspace
## (``helpers/repro_workspace_fixture``: a temp workspace root with
## ``.repro/workspace.toml``, project/repo manifests, and git repos
## cloned from local bare "remotes"), then runs ``checkCleanTree``
## against it.  The gate covers one reprobuild project (``isonim`` by
## default, which is the fixture's project); the scope test adds a second
## project to the active set and proves its state cannot block.  The gate reads the workspace through ``repro``, exactly
## as it does in a real workspace.  No global state.

import std/[os, strutils, unittest]

import isonim/editor/design_review/clean_tree

import helpers/repro_workspace_fixture

proc reportsFor(status: CleanTreeStatus;
                reason: DirtyRepoReason): seq[DirtyRepoReport] =
  for r in status.dirty:
    if r.reason == reason: result.add r

suite "REV-M5 clean tree gate":

  test "test_clean_tree_gate_passes_on_clean_workspace":
    let ws = newReproWorkspace("clean", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    let status = checkCleanTree(ws.root)
    check status.ok
    check status.dirty.len == 0
    # The gate hands capture the observation it judged.
    check status.observation.repos.len == 2
    check status.observation.project == ws.project

  test "test_clean_tree_gate_reports_dirty_files":
    let ws = newReproWorkspace("dirty", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / "README.md", "a (edited)\n")
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    check status.dirty.len == 1
    check status.dirty[0].reason == drUncommitted
    check status.dirty[0].files == @["README.md"]
    check status.dirty[0].repoPath.endsWith("repo-a")

  test "test_clean_tree_gate_reports_staged_changes":
    let ws = newReproWorkspace("staged", ["repo-a"])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / "new.txt", "staged\n")
    discard git(["add", "new.txt"], ws.repoDir("repo-a"))
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    let found = status.reportsFor(drUncommitted)
    check found.len == 1
    if found.len == 1:
      check found[0].files == @["new.txt"]

  test "test_clean_tree_gate_reports_untracked_files":
    let ws = newReproWorkspace("untracked", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / "foo.txt", "untracked!\n")
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    let found = status.reportsFor(drUntracked)
    check found.len == 1
    if found.len == 1:
      check found[0].files == @["foo.txt"]
    check status.reportsFor(drUncommitted).len == 0

  test "test_clean_tree_gate_reports_unpublished_head":
    let ws = newReproWorkspace("unpublished", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    # A committed, clean, but never-pushed HEAD: the pin would name a
    # commit only this machine has.
    let local = ws.commit("repo-b", "local only", [("x.txt", "x\n")])
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    let found = status.reportsFor(drUnpublishedHead)
    check found.len == 1
    if found.len == 1:
      check found[0].headSha == local
      check found[0].repoPath.endsWith("repo-b")
    # Publishing it makes the same state acceptable.
    ws.publish("repo-b")
    check checkCleanTree(ws.root).ok

  test "test_clean_tree_gate_counts_only_the_declared_remote_as_published":
    # "Published" means fetchable from the remote the manifest declares.
    # A commit that sits only on some other remote of the checkout (a
    # personal fork, a stray mirror) cannot be fetched by anybody who
    # clones from the manifest, so the pin must not name it.  reprobuild's
    # own ``isPublished`` accepts any remote-tracking ref when the checkout
    # has no remote literally called ``origin``, which is the case here.
    let ws = newReproWorkspace("strayremote", ["repo-a"])
    defer: ws.cleanup()
    let repo = ws.repoDir("repo-a")
    discard git(["remote", "rename", "origin", "upstream"], repo)
    let fork = ws.scratch / "origins" / "repo-a-fork.git"
    discard git(["init", "-q", "--bare", "-b", "main", fork], ws.scratch)
    discard git(["remote", "add", "fork", fork], repo)
    check checkCleanTree(ws.root).ok   # renaming the remote changes nothing
    let local = ws.commit("repo-a", "only on the fork", [("f.txt", "f\n")])
    discard git(["push", "-q", "fork", "HEAD:main"], repo)
    discard git(["fetch", "-q", "fork"], repo)
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    let found = status.reportsFor(drUnpublishedHead)
    check found.len == 1
    if found.len == 1:
      check found[0].headSha == local
    # On the declared remote it is published.
    discard git(["push", "-q", "upstream", "HEAD:main"], repo)
    discard git(["fetch", "-q", "upstream"], repo)
    check checkCleanTree(ws.root).ok

  test "test_remote_url_normalisation_matches_equivalent_spellings":
    let want = normalizeRemoteUrl("https://github.com/metacraft-labs/isonim")
    for same in ["https://github.com/metacraft-labs/isonim.git",
                 "https://github.com/Metacraft-Labs/isonim/",
                 "git@github.com:metacraft-labs/isonim.git",
                 "ssh://git@github.com/metacraft-labs/isonim"]:
      check normalizeRemoteUrl(same) == want
    check normalizeRemoteUrl("https://github.com/someone/isonim") != want
    check normalizeRemoteUrl("file:///C:/tmp/o%20x/r.git") ==
      normalizeRemoteUrl("C:\\tmp\\o x\\r")

  test "test_clean_tree_gate_refuses_a_checkout_without_the_declared_remote":
    # No git remote of the checkout points at the declared URL: nothing
    # in it can be shown to be fetchable from the manifest's remote.
    let ws = newReproWorkspace("noremote", ["repo-a"])
    defer: ws.cleanup()
    let repo = ws.repoDir("repo-a")
    let fork = ws.scratch / "origins" / "repo-a-fork.git"
    discard git(["clone", "-q", "--bare", ws.scratch / "origins" / "repo-a.git",
                 fork], ws.scratch)
    discard git(["remote", "set-url", "origin", fork], repo)
    discard git(["fetch", "-q", "origin"], repo)
    let status = checkCleanTree(ws.root)
    check (not status.ok)
    let found = status.reportsFor(drUnpublishedHead)
    check found.len == 1
    if found.len == 1:
      check "declared remote" in found[0].detail

  test "test_clean_tree_gate_ignores_declared_but_absent_checkouts":
    let ws = newReproWorkspace("absent", ["repo-a", "repo-b"])
    defer: ws.cleanup()
    removeDir(ws.repoDir("repo-b"))
    let status = checkCleanTree(ws.root)
    check status.ok
    var sawAbsent = false
    for r in status.observation.repos:
      if r.path == "repo-b":
        sawAbsent = true
        check (not r.materialized)
    check sawAbsent

  test "test_clean_tree_gate_is_scoped_to_its_project":
    let ws = newReproWorkspace("scope", ["repo-a"],
                               otherProject = "unrelated",
                               otherRepos = ["repo-z"])
    defer: ws.cleanup()
    # Break every rule in the OTHER project's repo: uncommitted,
    # untracked, and an unpublished HEAD.
    discard ws.commit("repo-z", "local only", [("z.txt", "z\n")])
    writeFile(ws.repoDir("repo-z") / "README.md", "dirty\n")
    writeFile(ws.repoDir("repo-z") / "stray.txt", "untracked\n")
    # Not vacuous: gated as its own project, repo-z fails all three.
    let other = checkCleanTree(ws.root, "unrelated")
    check (not other.ok)
    check other.reportsFor(drUncommitted).len == 1
    check other.reportsFor(drUntracked).len == 1
    check other.reportsFor(drUnpublishedHead).len == 1
    # The design-review project does not see it.
    let status = checkCleanTree(ws.root, ws.project)
    check status.ok
    check status.dirty.len == 0
    check status.observation.project == ws.project
    var paths: seq[string]
    for r in status.observation.repos: paths.add r.path
    check paths == @["repo-a"]
    # ...while the same faults in its own repo still block.
    writeFile(ws.repoDir("repo-a") / "README.md", "dirty\n")
    check checkCleanTree(ws.root, ws.project).reportsFor(drUncommitted).len == 1
    discard git(["checkout", "--", "README.md"], ws.repoDir("repo-a"))
    discard ws.commit("repo-a", "local only", [("a.txt", "a\n")])
    check checkCleanTree(ws.root, ws.project).reportsFor(
      drUnpublishedHead).len == 1

  test "test_clean_tree_gate_reports_unknown_project_as_unreadable":
    let ws = newReproWorkspace("noproj", ["repo-a"])
    defer: ws.cleanup()
    let status = checkCleanTree(ws.root, "no-such-project")
    check (not status.ok)
    check status.dirty.len == 1
    check status.dirty[0].reason == drWorkspaceUnreadable

  test "test_clean_tree_gate_reports_unreadable_workspace_without_raising":
    # A directory that is not a reprobuild workspace: the gate must say
    # it could not look, not that everything is clean.
    let dir = getTempDir() / ("isonim_clean_tree_not_ws_" &
                              $getCurrentProcessId())
    createDir(dir)
    defer: removeDir(dir)
    let status = checkCleanTree(dir)
    check (not status.ok)
    check status.dirty.len == 1
    check status.dirty[0].reason == drWorkspaceUnreadable
    check status.dirty[0].detail.len > 0
