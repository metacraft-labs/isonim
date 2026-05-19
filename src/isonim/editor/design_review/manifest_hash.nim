## REV-M5 — workspace manifest hashing.
##
## Runs ``repo manifest -r`` under a workspace root, normalises the
## XML the canonical way described in the milestone, and returns
## the lowercase-hex sha256 of the canonical UTF-8 bytes.
##
## Normalisation rules (must be stable across machines and Nim
## versions):
##
##   * Strip ``<!-- comments -->``.
##   * Sort ``<project>`` elements alphabetically by their ``name``
##     attribute.
##   * For each ``<project>``, sort attributes alphabetically by name.
##   * Collapse runs of whitespace in element bodies to a single
##     space and trim per-line leading/trailing whitespace.
##   * Emit canonical UTF-8 without a BOM, LF line endings.
##
## sha256 reuses the ``shasum -a 256`` / ``sha256sum`` shell-out
## pattern REV-M4 established (the same one in
## ``tools/isonim_review/cmd_init.nim``).  In-process SHA-256 is
## not on the import path until ``nim_everywhere`` exposes it.
##
## If ``repo manifest -r`` fails — for example because the
## directory has no ``.repo/`` or the ``repo`` binary is missing —
## we raise ``ManifestHashError`` rather than silently returning a
## bogus hash.

import std/[os, osproc, parsexml, streams, strutils, algorithm]

type
  ManifestHashError* = object of CatchableError

# ---------------------------------------------------------------------------
# `repo manifest -r` invocation
# ---------------------------------------------------------------------------

proc runRepoManifest(workspaceRoot: string): string =
  ## Run ``repo manifest -r`` inside ``workspaceRoot``; return its
  ## stdout.  Raises ``ManifestHashError`` on any failure mode.
  if not dirExists(workspaceRoot / ".repo"):
    raise newException(ManifestHashError,
      "captureManifestHash: not a repo-managed workspace (no .repo/): " &
      workspaceRoot)
  let repoBin = findExe("repo")
  if repoBin.len == 0:
    raise newException(ManifestHashError,
      "captureManifestHash: `repo` binary not on PATH; " &
      "install Android `repo` or set up the workspace toolchain")
  let p = startProcess(repoBin, args = @["manifest", "-r"],
                       workingDir = workspaceRoot,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(ManifestHashError,
      "captureManifestHash: `repo manifest -r` failed (" & $code &
      ") in " & workspaceRoot & ":\n" & output)
  result = output

# ---------------------------------------------------------------------------
# XML normalisation
# ---------------------------------------------------------------------------

type
  NormElement = ref object
    tag: string
    attrs: seq[(string, string)]    ## kept sorted by key
    body: string                     ## inner text (whitespace-collapsed)
    children: seq[NormElement]

proc collapseSpaces(s: string): string =
  ## Collapse runs of ASCII whitespace (space, tab, CR, LF) to one
  ## space; trim leading/trailing whitespace.
  result = newStringOfCap(s.len)
  var inWs = false
  for ch in s:
    let isWs = ch in {' ', '\t', '\r', '\n'}
    if isWs:
      inWs = true
    else:
      if inWs and result.len > 0:
        result.add ' '
      result.add ch
      inWs = false

proc parseNormalisedTree(xml: string): NormElement =
  ## Parse the XML into a tree of ``NormElement`` nodes.  Strips
  ## comments + processing instructions outright; normalises whitespace
  ## inside element bodies.  Attribute lists are sorted lexically by
  ## key.  ``<project>`` siblings are sorted by their ``name`` attribute.
  let stream = newStringStream(xml)
  var p: XmlParser
  p.open(stream, "<manifest>")
  defer:
    p.close()
    stream.close()

  var root = NormElement(tag: "__root__")
  var stack: seq[NormElement] = @[root]
  template top(): NormElement = stack[^1]

  while true:
    p.next()
    case p.kind
    of xmlEof: break
    of xmlElementStart:
      let n = NormElement(tag: p.elementName)
      top().children.add n
      stack.add n
    of xmlElementOpen:
      let n = NormElement(tag: p.elementName)
      var collected: seq[(string, string)] = @[]
      while true:
        p.next()
        case p.kind
        of xmlAttribute:
          collected.add (p.attrKey, p.attrValue)
        of xmlElementClose:
          break
        of xmlEof:
          break
        else:
          discard
      collected.sort(proc(a, b: (string, string)): int = cmp(a[0], b[0]))
      n.attrs = collected
      top().children.add n
      stack.add n
    of xmlElementEnd:
      if stack.len > 1:
        stack.setLen(stack.len - 1)
    of xmlCharData, xmlWhitespace:
      let collapsed = collapseSpaces(p.charData)
      if collapsed.len > 0:
        top().body.add collapsed
    of xmlCData:
      top().body.add collapseSpaces(p.charData)
    of xmlComment, xmlPI, xmlSpecial, xmlEntity:
      discard
    of xmlError:
      raise newException(ManifestHashError,
        "captureManifestHash: malformed XML: " & p.errorMsg)
    else:
      discard

  # Sort <project> children by ``name`` attribute (deterministic order).
  proc projectKey(e: NormElement): string =
    for (k, v) in e.attrs:
      if k == "name": return v
    ""

  proc sortChildren(e: NormElement) =
    var projects: seq[NormElement] = @[]
    var others: seq[NormElement] = @[]
    for c in e.children:
      if c.tag == "project": projects.add c
      else: others.add c
    projects.sort(proc(a, b: NormElement): int =
      cmp(projectKey(a), projectKey(b)))
    e.children = others & projects
    for c in e.children:
      sortChildren(c)

  sortChildren(root)
  result = root

proc emitNormalised(e: NormElement; indent: int; accum: var string) =
  ## Emit one canonical line per element.  Indentation = 2 spaces × depth.
  ## Empty bodies + no children → self-closing ``<tag .../>``.
  if e.tag == "__root__":
    for c in e.children:
      emitNormalised(c, indent, accum)
    return
  for _ in 0 ..< indent: accum.add ' '
  accum.add '<'
  accum.add e.tag
  for (k, v) in e.attrs:
    accum.add ' '
    accum.add k
    accum.add '='
    accum.add '"'
    for ch in v:
      case ch
      of '<': accum.add "&lt;"
      of '>': accum.add "&gt;"
      of '&': accum.add "&amp;"
      of '"': accum.add "&quot;"
      else: accum.add ch
    accum.add '"'
  let body = collapseSpaces(e.body)
  if e.children.len == 0 and body.len == 0:
    accum.add "/>\n"
    return
  accum.add ">\n"
  if body.len > 0:
    for _ in 0 ..< (indent + 2): accum.add ' '
    accum.add body
    accum.add '\n'
  for c in e.children:
    emitNormalised(c, indent + 2, accum)
  for _ in 0 ..< indent: accum.add ' '
  accum.add "</"
  accum.add e.tag
  accum.add ">\n"

proc normaliseManifest*(xml: string): string =
  ## Build the canonical byte stream from raw ``repo manifest -r``
  ## output.  Pure function — exposed so tests can pin the exact
  ## normalisation behaviour.
  let tree = parseNormalisedTree(xml)
  result = ""
  emitNormalised(tree, 0, result)

# ---------------------------------------------------------------------------
# sha256 over the canonical bytes
# ---------------------------------------------------------------------------

proc sha256Hex(s: string): string =
  ## Compute lowercase-hex sha256 by shelling out to ``shasum -a 256``
  ## or ``sha256sum``.  Same pattern as
  ## ``isonim/tools/isonim_review/cmd_init.nim``.
  let exe = findExe("shasum")
  let cmd =
    if exe.len > 0: "shasum -a 256"
    else: "sha256sum"
  let p = startProcess(cmd.split()[0], args = cmd.split()[1 .. ^1],
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let stdin = p.inputStream
  stdin.write(s)
  stdin.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(ManifestHashError,
      "captureManifestHash: " & cmd & " failed (" & $code & "): " & output)
  let parts = output.splitWhitespace()
  if parts.len == 0:
    raise newException(ManifestHashError,
      "captureManifestHash: " & cmd & " returned empty output")
  parts[0].toLowerAscii()

# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------

proc captureManifestHash*(workspaceRoot: string): string =
  ## Capture the workspace's pinned manifest hash.  Resolution
  ## order (each subsequent step is a fallback, used only when the
  ## prior step is unavailable):
  ##
  ##   1. ``repo manifest -r`` — the canonical path for a real
  ##      ``repo``-initialised workspace.
  ##   2. Direct read of ``<workspaceRoot>/.repo/manifest.xml``
  ##      when (a) the ``repo`` binary isn't on PATH, or (b) the
  ##      workspace was built with a synthetic manifest (no
  ##      ``.repo/repo/`` clone — common in tests and
  ##      hand-curated fixtures).
  ##   3. Raise ``ManifestHashError`` if neither path is available
  ##      so callers never silently produce a bogus hash.
  ##
  ## All paths feed the same normalisation + sha256 step.
  let manifestXmlPath = workspaceRoot / ".repo" / "manifest.xml"
  let repoBin = findExe("repo")
  let canTryRepo = repoBin.len > 0 and
                   dirExists(workspaceRoot / ".repo" / "repo")
  var raw: string
  if canTryRepo:
    raw = runRepoManifest(workspaceRoot)
  elif fileExists(manifestXmlPath):
    raw = readFile(manifestXmlPath)
  else:
    raise newException(ManifestHashError,
      "captureManifestHash: workspace " & workspaceRoot &
      " has neither a `repo`-initialised .repo/ tree nor a direct " &
      ".repo/manifest.xml file at " & manifestXmlPath)
  let canonical = normaliseManifest(raw)
  result = sha256Hex(canonical)

proc captureManifestHashOfBytes*(xml: string): string =
  ## Variant that hashes a pre-fetched manifest XML (used by tests
  ## that construct synthetic XML without a ``repo`` binary).
  let canonical = normaliseManifest(xml)
  result = sha256Hex(canonical)
