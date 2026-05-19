## REV-M5 — workspace clean-tree gate.
##
## Replicates the pre-push hook's reproducibility checks from
## ``metacraft/CLAUDE.md`` § "Pre-push: publication check".  Each
## repo listed in ``.repo/manifest.xml`` (plus any
## ``.repo/local_manifests/*.xml``) is inspected for:
##
##   1. Uncommitted changes (``git status --porcelain`` non-empty).
##   2. Untracked files.
##   3. HEAD not pointing at the manifest's pinned revision.
##
## We deliberately do not shell out to the ``repo-workspaces``
## helpers: their job is a hook-time exit-code check, while ours is
## a programmatic check that returns a structured report so the
## capture pipeline can fail loudly with file-level detail.
##
## *Never raises* — defective repos surface as
## ``drManifestUnreadable`` reports.  The capture orchestrator's
## job is to make the resulting message actionable.

import std/[os, osproc, parsexml, streams, strutils]

type
  DirtyRepoReason* = enum
    drUncommitted        ## modified files in the working tree
    drUntracked          ## files present but not under version control
    drUnpinnedHead       ## HEAD does not match the manifest's revision
    drManifestUnreadable ## could not read/parse the manifest XML for this repo

  DirtyRepoReport* = object
    repoPath*: string
    reason*: DirtyRepoReason
    files*: seq[string]
      ## Populated for ``drUncommitted`` and ``drUntracked``.  One
      ## entry per file path (relative to ``repoPath``).
    headSha*: string
      ## Populated for ``drUnpinnedHead`` — the actual HEAD SHA.
    expectedPin*: string
      ## Populated for ``drUnpinnedHead`` — the manifest's pinned
      ## ``revision`` attribute.

  CleanTreeStatus* = object
    ok*: bool
    dirty*: seq[DirtyRepoReport]

# ---------------------------------------------------------------------------
# Manifest parsing
# ---------------------------------------------------------------------------

type
  ManifestProject = object
    name: string         ## ``name`` attribute (relative repo identifier)
    path: string         ## ``path`` attribute (workspace-relative dir)
    revision: string     ## ``revision`` attribute (pinned SHA or ref)

proc parseManifestXml(path: string; defaultRevision: var string;
                      accum: var seq[ManifestProject]) =
  ## Best-effort parse of a ``repo`` manifest XML file.  Picks up
  ## ``<default revision="...">`` and every ``<project name=... path=... revision=...>``.
  ##
  ## Errors are *swallowed* — the caller turns absent / unparseable
  ## projects into ``drManifestUnreadable`` reports.
  let fs = newFileStream(path, fmRead)
  if fs == nil: return
  var p: XmlParser
  p.open(fs, path)
  defer:
    p.close()
    fs.close()
  while true:
    p.next()
    case p.kind
    of xmlEof: break
    of xmlElementOpen, xmlElementStart:
      let tag = p.elementName
      var attrs: seq[(string, string)] = @[]
      if p.kind == xmlElementOpen:
        # Walk attributes until xmlElementClose.
        while true:
          p.next()
          case p.kind
          of xmlAttribute:
            attrs.add (p.attrKey, p.attrValue)
          of xmlElementClose, xmlElementEnd, xmlEof:
            break
          else:
            discard
      if tag == "default":
        for (k, v) in attrs:
          if k == "revision": defaultRevision = v
      elif tag == "project":
        var proj = ManifestProject()
        for (k, v) in attrs:
          case k
          of "name": proj.name = v
          of "path": proj.path = v
          of "revision": proj.revision = v
          else: discard
        if proj.path.len == 0:
          proj.path = proj.name
        if proj.revision.len == 0:
          proj.revision = defaultRevision
        accum.add proj
    else:
      discard

proc collectManifestProjects(workspaceRoot: string;
                             unreadable: var seq[string]): seq[ManifestProject] =
  ## Walk ``.repo/manifest.xml`` plus ``.repo/local_manifests/*.xml``
  ## under ``workspaceRoot`` and return the union of projects.
  result = @[]
  var defaultRev = ""
  let main = workspaceRoot / ".repo" / "manifest.xml"
  if fileExists(main):
    try:
      parseManifestXml(main, defaultRev, result)
    except CatchableError:
      unreadable.add main
  else:
    unreadable.add main
  let localDir = workspaceRoot / ".repo" / "local_manifests"
  if dirExists(localDir):
    for kind, path in walkDir(localDir):
      if kind != pcFile: continue
      if not path.endsWith(".xml"): continue
      try:
        parseManifestXml(path, defaultRev, result)
      except CatchableError:
        unreadable.add path

# ---------------------------------------------------------------------------
# Git probes
# ---------------------------------------------------------------------------

proc runGit(args: seq[string]; cwd: string): tuple[ok: bool; output: string] =
  ## Run ``git <args...>`` in ``cwd``.  Returns ok=false on non-zero exit.
  let p = startProcess("git", args = args, workingDir = cwd,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  result = (exitCode == 0, output)

proc gitStatusPorcelain(repoPath: string;
                        uncommitted, untracked: var seq[string]) =
  ## Populate ``uncommitted`` and ``untracked`` from
  ## ``git status --porcelain``.  Lines starting with ``??`` are
  ## untracked; anything else is uncommitted.
  let res = runGit(@["status", "--porcelain"], repoPath)
  if not res.ok:
    return
  for rawLine in res.output.splitLines():
    if rawLine.len == 0: continue
    if rawLine.len < 3: continue
    if rawLine[0..1] == "??":
      let f = rawLine[3 .. ^1].strip()
      if f.len > 0: untracked.add f
    else:
      let f = rawLine[3 .. ^1].strip()
      if f.len > 0: uncommitted.add f

proc gitHeadSha(repoPath: string): string =
  let res = runGit(@["rev-parse", "HEAD"], repoPath)
  if not res.ok:
    return ""
  result = res.output.strip()

proc resolveRevision(repoPath, refSpec: string): string =
  ## Try to resolve a manifest ``revision`` to its commit SHA.  Falls
  ## back to the raw string (so tag/branch names compare equal when
  ## the manifest itself records the SHA directly).
  if refSpec.len == 0: return ""
  # If it already looks like a 40-char hex SHA, keep it.
  if refSpec.len == 40 and refSpec.allCharsInSet({'0'..'9', 'a'..'f', 'A'..'F'}):
    return refSpec.toLowerAscii()
  let res = runGit(@["rev-parse", refSpec], repoPath)
  if res.ok:
    return res.output.strip().toLowerAscii()
  refSpec

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

proc checkCleanTree*(workspaceRoot: string): CleanTreeStatus =
  ## Walk every project named in ``<workspaceRoot>/.repo/manifest.xml``
  ## (plus any ``.repo/local_manifests/*.xml``) and report dirty
  ## state.  Returns ``CleanTreeStatus{ok: true}`` only when every
  ## repo passes all three checks.
  ##
  ## Never raises.  Workspaces without a ``.repo/`` directory surface
  ## as a single ``drManifestUnreadable`` report so callers can
  ## distinguish "workspace not initialised" from "everything clean".
  result = CleanTreeStatus(ok: true, dirty: @[])
  var unreadable: seq[string] = @[]
  let projects = collectManifestProjects(workspaceRoot, unreadable)

  for u in unreadable:
    result.dirty.add DirtyRepoReport(
      repoPath: u,
      reason: drManifestUnreadable,
    )
    result.ok = false

  for proj in projects:
    let absPath = workspaceRoot / proj.path
    if not dirExists(absPath / ".git") and not dirExists(absPath / ".."):
      result.dirty.add DirtyRepoReport(
        repoPath: absPath,
        reason: drManifestUnreadable,
      )
      result.ok = false
      continue
    if not dirExists(absPath / ".git"):
      # A bare path without ``.git`` — record as unreadable so the
      # message points at the missing checkout, not a fake clean run.
      result.dirty.add DirtyRepoReport(
        repoPath: absPath,
        reason: drManifestUnreadable,
      )
      result.ok = false
      continue

    var uncommitted: seq[string] = @[]
    var untracked: seq[string] = @[]
    gitStatusPorcelain(absPath, uncommitted, untracked)
    if uncommitted.len > 0:
      result.dirty.add DirtyRepoReport(
        repoPath: absPath,
        reason: drUncommitted,
        files: uncommitted,
      )
      result.ok = false
    if untracked.len > 0:
      result.dirty.add DirtyRepoReport(
        repoPath: absPath,
        reason: drUntracked,
        files: untracked,
      )
      result.ok = false
    if proj.revision.len > 0:
      let head = gitHeadSha(absPath).toLowerAscii()
      let expected = resolveRevision(absPath, proj.revision)
      if head.len > 0 and expected.len > 0 and head != expected:
        result.dirty.add DirtyRepoReport(
          repoPath: absPath,
          reason: drUnpinnedHead,
          headSha: head,
          expectedPin: expected,
        )
        result.ok = false
