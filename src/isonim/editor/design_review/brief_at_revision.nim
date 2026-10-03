## REV-M6 — historical brief resolver.
##
## Resolves the markdown body of a brief at the *pinned* workspace state
## a run was captured against.  Past runs remain reviewable even after
## briefs are renamed, moved, or rewritten — the working tree state is
## irrelevant, only ``git show <revision>:<path>`` against the pin is
## consulted.
##
## *The pin carries its own revisions.*  A run's ``manifest_hash`` is a
## workspace pin (``workspace_pin.nim``): the sha256 of a canonical
## reprobuild workspace lock whose content is stored in
## ``design_review.workspace_pins``.  The caller fetches that record
## (``pin_db.fetchWorkspacePinLock``) and passes it in; this module
## verifies that it hashes to the pin, then looks the brief up at each
## pinned revision.  Nothing about the *current* workspace pinning has to
## match — only the pinned commits have to be present in the local
## checkouts (fetch them if they are not).
##
## *Values that are not workspace pins* (see ``workspace_pin.classifyPin``):
##
##   * ``seeded:<tag>`` — Follow-up 3: the run was ingested via
##     ``isonim-review seed-run`` and has no pin; the brief is read from
##     the working tree (documented limitation: edits between seeding and
##     review flow into the review).
##   * a bare 64-hex value — a run captured under the retired
##     ``repo manifest -r`` hash.  No content was ever stored for it, so it
##     cannot be resolved; we refuse rather than guess.
##   * anything else — refused.
##
## *briefId → path convention.*  The brief index walker (REV-M1)
## enforces ``briefs/<kind>/<slug>.md`` and ``briefId == "<kind>.<slug>"``.
## This module mirrors that convention to turn a ``briefId`` into a
## relative path candidate.

import std/[os, osproc, streams, strutils]

import ./workspace_pin

export SeededManifestHashPrefix, isSeededManifestHash

type
  BriefNotFoundAtRevisionError* = object of CatchableError
  BriefAtRevisionError* = object of CatchableError
    ## Catch-all for non-NotFound failure modes (unresolvable pin, pinned
    ## commit missing locally, git invocation failure, etc.).

# --------------------------------------------------------------------------- #
#  briefId → relative path.
# --------------------------------------------------------------------------- #

proc briefIdToRelativePath(briefId: string): string =
  ## ``briefId == "<kind>.<slug>"`` → ``briefs/<kind>/<slug>.md``.
  let dotIdx = briefId.find('.')
  if dotIdx <= 0 or dotIdx == briefId.high:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: malformed briefId '" & briefId & "' " &
      "(expected <kind>.<slug>)")
  let kind = briefId[0 ..< dotIdx]
  let slug = briefId[dotIdx + 1 .. ^1]
  result = "briefs" / kind / (slug & ".md")

# --------------------------------------------------------------------------- #
#  git wrappers.
# --------------------------------------------------------------------------- #

proc runGit(args: openArray[string]):
    tuple[ok: bool; content: string; stderr: string] =
  let p = startProcess("git", args = args, options = {poUsePath})
  defer: p.close()
  let stdoutRead = p.outputStream.readAll()
  let stderrRead = p.errorStream.readAll()
  let exitCode = p.waitForExit()
  result = (exitCode == 0, stdoutRead, stderrRead)

proc hasCommit(repoPath, revision: string): bool =
  runGit(["-C", repoPath, "cat-file", "-e", revision & "^{commit}"]).ok

# --------------------------------------------------------------------------- #
#  Public API.
# --------------------------------------------------------------------------- #

proc briefFromWorkingTree(workspaceRoot, briefId: string): string =
  ## Return the first matching brief body found *in the working tree* of
  ## a checkout directly under ``workspaceRoot`` (or the root itself).
  ## Used by :proc:`briefAtRevision` for ``seeded:`` runs.
  let relPath = briefIdToRelativePath(briefId)
  for kind, sub in walkDir(workspaceRoot):
    if kind != pcDir: continue
    let candidate = sub / relPath
    if fileExists(candidate):
      return readFile(candidate)
  let direct = workspaceRoot / relPath
  if fileExists(direct):
    return readFile(direct)
  raise newException(BriefNotFoundAtRevisionError,
    "briefAtRevision (seeded): brief '" & briefId & "' (" & relPath &
    ") not found under working tree at " & workspaceRoot)

proc briefAtRevision*(workspaceRoot, manifestHash, briefId: string;
                      pinLockToml = ""): string =
  ## Resolve the brief markdown body at the run's pin.
  ##
  ## ``pinLockToml`` is the stored lock record for a ``wslock-v1:`` pin
  ## (``pin_db.fetchWorkspacePinLock``); it is ignored for ``seeded:``
  ## runs.  For each pinned repo, in the record's canonical order, run
  ## ``git show <revision>:briefs/<kind>/<slug>.md`` in its checkout
  ## under ``workspaceRoot`` and return the first hit.  Raises
  ## ``BriefNotFoundAtRevisionError`` when every pinned revision was
  ## examined and none has the brief, ``BriefAtRevisionError`` for every
  ## other failure (unresolvable pin, pinned commits not present).
  if briefId.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: briefId must be non-empty")
  if manifestHash.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: manifestHash must be non-empty")

  case classifyPin(manifestHash)
  of pkSeeded:
    return briefFromWorkingTree(workspaceRoot, briefId)
  of pkLegacyRepoManifest:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: run is pinned by a retired `repo manifest` hash (" &
      manifestHash & "); its manifest was never stored, so the brief at " &
      "that state cannot be resolved.  Re-capture the run.")
  of pkUnrecognised:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: '" & manifestHash & "' is not a workspace pin " &
      "(expected " & WorkspacePinPrefix & "<sha256>)")
  of pkWorkspaceLock:
    discard

  if pinLockToml.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: no lock record supplied for pin " & manifestHash)
  let lock =
    try:
      resolvePin(manifestHash, pinLockToml)
    except WorkspacePinError as e:
      raise newException(BriefAtRevisionError, "briefAtRevision: " & e.msg)

  let relPath = briefIdToRelativePath(briefId).replace('\\', '/')
  var missing: seq[string]
  var lastStderr = ""
  for repo in lock.repos:
    let absRepo = workspaceRoot / repo.path
    if not (dirExists(absRepo / ".git") or fileExists(absRepo / ".git")):
      missing.add repo.path & " (no checkout)"
      continue
    if not hasCommit(absRepo, repo.revision):
      missing.add repo.path & "@" & repo.revision
      continue
    let r = runGit(["-C", absRepo, "show", repo.revision & ":" & relPath])
    if r.ok:
      return r.content
    lastStderr = r.stderr

  if missing.len > 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: brief '" & briefId & "' not found in the checked " &
      "pinned revisions, and these pinned repos could not be examined " &
      "(clone / `git fetch` them): " & missing.join(", "))
  raise newException(BriefNotFoundAtRevisionError,
    "briefAtRevision: brief '" & briefId & "' (" & relPath & ") not found " &
    "at pin " & manifestHash & " in any repo of " & workspaceRoot &
    (if lastStderr.len > 0: " — last git stderr: " & lastStderr.strip()
     else: ""))
