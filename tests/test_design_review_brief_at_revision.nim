## REV-M6 — brief_at_revision tests.
##
## Each test materialises a hermetic reprobuild workspace
## (``helpers/repro_workspace_fixture``) whose ``repo-a`` carries
## ``briefs/render/foo.md``.  We commit + publish, pin the workspace
## (``captureWorkspacePin``, exactly what capture stores), edit and
## re-pin, optionally touch the working tree to prove git history is
## consulted (not the file on disk), and assert ``briefAtRevision``
## against each pin and its stored lock record.

import std/[os, strutils, unittest]

import isonim/editor/design_review/brief_at_revision
import isonim/editor/design_review/workspace_pin

import helpers/repro_workspace_fixture

const BriefRel = "briefs/render/foo.md"

suite "REV-M6 brief_at_revision":

  test "test_brief_at_revision_returns_historical_content":
    let ws = newReproWorkspace("bav_history", ["repo-a", "repo-b"],
      files = [("repo-a", BriefRel, "---\nbriefId: render.foo\n---\nbody-v1\n")])
    defer: ws.cleanup()
    let pinA = captureWorkspacePin(ws.root)

    discard ws.commitAndPublish("repo-a", "update brief",
      [(BriefRel, "---\nbriefId: render.foo\n---\nbody-v2\n")])
    let pinB = captureWorkspacePin(ws.root)
    check pinA.pin != pinB.pin

    # Touch the working tree — ``briefAtRevision`` must not see this, and
    # the workspace no longer sits at pin A at all.
    writeFile(ws.repoDir("repo-a") / BriefRel, "WORKING_TREE_GARBAGE\n")

    let bodyAtA = briefAtRevision(ws.root, pinA.pin, "render.foo", pinA.lockToml)
    check bodyAtA.contains("body-v1")
    check (not bodyAtA.contains("body-v2"))
    let bodyAtB = briefAtRevision(ws.root, pinB.pin, "render.foo", pinB.lockToml)
    check bodyAtB.contains("body-v2")

  test "test_brief_at_revision_handles_missing_file":
    let ws = newReproWorkspace("bav_missing", ["repo-a"],
      files = [("repo-a", BriefRel, "---\nbriefId: render.foo\n---\nv1\n")])
    defer: ws.cleanup()
    let pinA = captureWorkspacePin(ws.root)
    # Rename + commit.  The brief no longer exists at this path under
    # the new revision.
    moveFile(ws.repoDir("repo-a") / BriefRel,
             ws.repoDir("repo-a") / "briefs" / "render" / "renamed.md")
    discard ws.commitAndPublish("repo-a", "rename brief")
    let pinB = captureWorkspacePin(ws.root)

    check briefAtRevision(ws.root, pinA.pin, "render.foo",
                          pinA.lockToml).contains("v1")
    expect BriefNotFoundAtRevisionError:
      discard briefAtRevision(ws.root, pinB.pin, "render.foo", pinB.lockToml)

  test "test_brief_at_revision_refuses_unresolvable_pins":
    let ws = newReproWorkspace("bav_refuse", ["repo-a"],
      files = [("repo-a", BriefRel, "---\nbriefId: render.foo\n---\nv1\n")])
    defer: ws.cleanup()
    let pin = captureWorkspacePin(ws.root)
    # A run captured under the retired ``repo manifest`` hash: there is
    # no stored content to resolve it from.
    expect BriefAtRevisionError:
      discard briefAtRevision(ws.root, sha256Hex("<manifest/>"), "render.foo")
    # Unrecognised values ("local", test strings) are not pins.
    expect BriefAtRevisionError:
      discard briefAtRevision(ws.root, "local", "render.foo")
    # A workspace pin without its record, or with somebody else's.
    expect BriefAtRevisionError:
      discard briefAtRevision(ws.root, pin.pin, "render.foo")
    var other = parseCanonicalLock(pin.lockToml)
    other.project = "someone-else"
    expect BriefAtRevisionError:
      discard briefAtRevision(ws.root, pin.pin, "render.foo",
                              renderCanonicalLock(other))

  test "test_brief_at_revision_names_pinned_commits_missing_locally":
    let ws = newReproWorkspace("bav_fetch", ["repo-a"],
      files = [("repo-a", BriefRel, "---\nbriefId: render.foo\n---\nv1\n")])
    defer: ws.cleanup()
    var lock = parseCanonicalLock(captureWorkspacePin(ws.root).lockToml)
    lock.repos[0].revision = "0123456789012345678901234567890123456789"
    let toml = renderCanonicalLock(lock)
    try:
      discard briefAtRevision(ws.root, pinOf(toml), "render.foo", toml)
      check false
    except BriefNotFoundAtRevisionError:
      check false  # "could not look" must not be reported as "not there"
    except BriefAtRevisionError as e:
      check "repo-a@0123456789012345678901234567890123456789" in e.msg

  test "test_brief_at_revision_seeded_runs_read_the_working_tree":
    let ws = newReproWorkspace("bav_seeded", ["repo-a"],
      files = [("repo-a", BriefRel, "---\nbriefId: render.foo\n---\nv1\n")])
    defer: ws.cleanup()
    writeFile(ws.repoDir("repo-a") / BriefRel, "WORKING_TREE\n")
    check briefAtRevision(ws.root, SeededManifestHashPrefix & "t",
                          "render.foo") == "WORKING_TREE\n"
