## REV-M6 — historical brief resolver.
##
## Resolves the markdown body of a brief at the *pinned* revision a run
## was captured against.  Past runs remain reviewable even after briefs
## are renamed, moved, or rewritten — the working tree state is
## irrelevant, only ``git show`` against the manifest pin is consulted.
##
## *Design choice — manifest XML lookup, not hash cache.*
##
## Two options were on the table:
##
##   1. Cache the canonical manifest XML keyed by ``manifestHash`` at
##      capture time.
##   2. Re-run ``repo manifest -r`` (or read ``.repo/manifest.xml``) at
##      review time and validate that the recomputed hash matches.
##
## We went with (2):
##
##   * Avoids a new on-disk artefact + cache-eviction policy.
##   * The hash↔XML mapping is already deterministic, so re-resolution
##     is cheap and the validation step *proves* the workspace still
##     pins the expected revisions.  A stale cache would lie silently.
##   * The capture pipeline never had to write a cache; REV-M5 didn't
##     touch it.  Symmetric: review-time fetches the manifest the same
##     way capture-time hashed it.
##
## *briefId → path convention.*  The brief index walker (REV-M1)
## enforces ``briefs/<kind>/<slug>.md`` and ``briefId == "<kind>.<slug>"``.
## This module mirrors that convention to turn a ``briefId`` into a
## relative path candidate.

import std/[os, osproc, parsexml, streams, strutils]

import ./manifest_hash

type
  BriefNotFoundAtRevisionError* = object of CatchableError
  BriefAtRevisionError* = object of CatchableError
    ## Catch-all for non-NotFound failure modes (manifest mismatch,
    ## git invocation failure, etc.).

const SeededManifestHashPrefix* = "seeded:"
  ## Follow-up 3 — sentinel that marks runs ingested via
  ## ``isonim-review seed-run`` (no manifest pin, just pre-existing
  ## PNGs).  When the prefix is seen, :proc:`briefAtRevision` falls
  ## back to reading the brief from the working tree instead of
  ## ``git show``-ing it at a manifest pin.  Documented limitation:
  ## brief edits between seeding and review WILL affect the review
  ## output — the seeded flow trades reproducibility for the ability
  ## to drive a review against historical screenshots that pre-date
  ## the design-review milestone.

# --------------------------------------------------------------------------- #
#  Manifest XML walk (similar shape to clean_tree's, but we keep the
#  data we need: name + path + revision per repo).
# --------------------------------------------------------------------------- #

type
  ManifestProject = object
    name: string
    path: string
    revision: string

proc parseRepoManifest(xml: string;
                       projects: var seq[ManifestProject]) =
  var defaultRevision = ""
  let stream = newStringStream(xml)
  var p: XmlParser
  p.open(stream, "<manifest>")
  defer:
    p.close()
    stream.close()
  while true:
    p.next()
    case p.kind
    of xmlEof: break
    of xmlElementOpen, xmlElementStart:
      let tag = p.elementName
      var attrs: seq[(string, string)] = @[]
      if p.kind == xmlElementOpen:
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
        if proj.path.len == 0: proj.path = proj.name
        if proj.revision.len == 0: proj.revision = defaultRevision
        projects.add(proj)
    else:
      discard

proc collectManifestProjects(workspaceRoot: string;
                             xmlBytes: var string): seq[ManifestProject] =
  ## Read every project recorded in ``.repo/manifest.xml`` plus any
  ## ``.repo/local_manifests/*.xml`` overlay.  Returns the merged list
  ## and writes the *concatenated* canonical XML bytes used for hash
  ## validation into ``xmlBytes``.
  result = @[]
  xmlBytes = ""
  let main = workspaceRoot / ".repo" / "manifest.xml"
  if fileExists(main):
    let xml = readFile(main)
    xmlBytes.add xml
    parseRepoManifest(xml, result)
  let localDir = workspaceRoot / ".repo" / "local_manifests"
  if dirExists(localDir):
    for kind, path in walkDir(localDir):
      if kind != pcFile: continue
      if not path.endsWith(".xml"): continue
      let xml = readFile(path)
      xmlBytes.add xml
      parseRepoManifest(xml, result)

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
#  git show wrapper.
# --------------------------------------------------------------------------- #

proc runGitShow(repoPath, pin, relPath: string):
    tuple[ok: bool; content: string; stderr: string] =
  ## ``git -C <repoPath> show <pin>:<relPath>``.  Returns ok=false if
  ## the file does not exist at that revision (``fatal: path 'X' does
  ## not exist in 'Y'``) — the caller raises ``BriefNotFoundAtRevisionError``.
  let p = startProcess("git",
    args = @["-C", repoPath, "show", pin & ":" & relPath],
    options = {poUsePath})
  defer: p.close()
  let outStream = p.outputStream
  let errStream = p.errorStream
  let stdoutRead = outStream.readAll()
  let stderrRead = errStream.readAll()
  let exitCode = p.waitForExit()
  result = (exitCode == 0, stdoutRead, stderrRead)

# --------------------------------------------------------------------------- #
#  Public API.
# --------------------------------------------------------------------------- #

proc isSeededManifestHash*(manifestHash: string): bool =
  ## Follow-up 3 — true iff ``manifestHash`` carries the
  ## :const:`SeededManifestHashPrefix` sentinel.  Callers use this to
  ## branch into the working-tree fallback path of
  ## :proc:`briefAtRevision`.
  manifestHash.startsWith(SeededManifestHashPrefix)

proc briefFromWorkingTree(workspaceRoot, briefId: string): string =
  ## Walk every git repo under ``workspaceRoot`` (mirrors the manifest
  ## walk for non-seeded runs) and return the first matching brief
  ## body found *in the working tree*.  Used by :proc:`briefAtRevision`
  ## when ``manifestHash`` is a ``seeded:`` sentinel.
  ##
  ## *Limitation.*  Brief edits between ``seed-run`` and
  ## ``run-review`` flow into the review.  This is the explicit
  ## tradeoff documented on :const:`SeededManifestHashPrefix`.
  let relPath = briefIdToRelativePath(briefId)
  # Sweep the manifest's project list first (preserves locator ordering
  # with the non-seeded path), then fall back to a top-level workspace
  # scan in case the workspace isn't ``repo``-managed.
  var xmlBytes: string
  let projects = collectManifestProjects(workspaceRoot, xmlBytes)
  for proj in projects:
    let candidate = workspaceRoot / proj.path / relPath
    if fileExists(candidate):
      return readFile(candidate)
  # Plain workspace fallback — scan immediate subdirectories of
  # ``workspaceRoot`` for a matching brief.  This is what makes the
  # seeded flow work in fresh test fixtures that don't include a
  # ``.repo/manifest.xml`` at all.
  for kind, sub in walkDir(workspaceRoot):
    if kind != pcDir: continue
    let candidate = sub / relPath
    if fileExists(candidate):
      return readFile(candidate)
  # Last resort: the brief might sit directly under ``workspaceRoot``.
  let direct = workspaceRoot / relPath
  if fileExists(direct):
    return readFile(direct)
  raise newException(BriefNotFoundAtRevisionError,
    "briefAtRevision (seeded): brief '" & briefId & "' (" & relPath &
    ") not found under working tree at " & workspaceRoot)

proc briefAtRevision*(workspaceRoot, manifestHash, briefId: string): string =
  ## Resolve the brief markdown body at the captured manifest pin.
  ##
  ## Sequence:
  ##   1. **Follow-up 3 — seeded-run shortcut.**  When ``manifestHash``
  ##      starts with ``seeded:`` the run was ingested via
  ##      ``isonim-review seed-run`` from historical PNGs and has no
  ##      manifest pin to validate against.  Fall back to reading the
  ##      brief from the working tree (:proc:`briefFromWorkingTree`).
  ##      Caveat: edits between seed-run and run-review flow into the
  ##      review.
  ##   2. Re-read the workspace's manifest XML and validate that the
  ##      recomputed hash matches ``manifestHash``.  Mismatch raises
  ##      ``BriefAtRevisionError`` — the workspace's manifest has
  ##      shifted since the run was captured (the user has to check
  ##      out the original manifest snapshot to reproduce the review).
  ##   3. Walk every project recorded in the manifest; for each, run
  ##      ``git show <revision>:<briefs/<kind>/<slug>.md>``.  Return
  ##      the first successful result.
  ##   4. If no project contains the brief at its pinned revision,
  ##      raise ``BriefNotFoundAtRevisionError``.
  if briefId.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: briefId must be non-empty")
  if manifestHash.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: manifestHash must be non-empty")

  if isSeededManifestHash(manifestHash):
    return briefFromWorkingTree(workspaceRoot, briefId)

  var xmlBytes: string
  let projects = collectManifestProjects(workspaceRoot, xmlBytes)
  if projects.len == 0:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: no projects found in " & workspaceRoot &
      "/.repo/manifest.xml")

  let actualHash = captureManifestHashOfBytes(xmlBytes).toLowerAscii
  if actualHash != manifestHash.toLowerAscii:
    raise newException(BriefAtRevisionError,
      "briefAtRevision: workspace manifest hash " & actualHash &
      " does not match requested " & manifestHash &
      " — check out the captured manifest pins to reproduce this review.")

  let relPath = briefIdToRelativePath(briefId)
  var lastStderr = ""
  for proj in projects:
    let absRepo = workspaceRoot / proj.path
    if not dirExists(absRepo / ".git"):
      continue
    if proj.revision.len == 0:
      continue
    let r = runGitShow(absRepo, proj.revision, relPath)
    if r.ok:
      return r.content
    lastStderr = r.stderr

  raise newException(BriefNotFoundAtRevisionError,
    "briefAtRevision: brief '" & briefId & "' (" & relPath & ") not found " &
    "at manifest hash " & manifestHash & " in any repo of " & workspaceRoot &
    (if lastStderr.len > 0: " — last git stderr: " & lastStderr.strip()
     else: ""))
