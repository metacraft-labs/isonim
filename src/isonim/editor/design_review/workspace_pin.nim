## REV-M5 — the workspace pin a design-review run is captured against.
##
## A run records *which source it was captured from* so it can be
## replayed later (``brief_at_revision.nim`` resolves the brief at that
## state).  The pin is a reprobuild workspace lock — the same
## ``reprobuild.workspace.lock.v1`` record shape reprobuild writes under
## ``locks/<project>/<repo>/<sha>.toml`` (reprobuild-specs
## ``Workspace-Manifests.md`` § "Workspace Lock") — reduced to the part
## that identifies the workspace *state*:
##
## .. code-block:: toml
##
##   schema = "reprobuild.workspace.lock.v1"
##
##   [lock]
##   project = "<primary project>"
##
##   [[repo]]
##   name = "<repo>"
##   path = "<checkout path>"
##   remote = "<declared remote>"
##   revision = "<full sha>"
##
##   [extensions]
##   pin_scope = "project"
##   unmaterialized_repos = [
##     { name = "<repo>", path = "<path>", remote = "<remote>", reason = "no on-disk checkout" },
##   ]
##
## Canonical form (this exact byte sequence is what is hashed):
##
##   * ``[[repo]]`` entries sorted by ``path``, then ``name``; exactly
##     the four keys above, in that order.  The record's ``created_at``,
##     ``created_by``, ``workspace_branch`` and per-repo ``branch`` are
##     provenance, not state, and are omitted so two captures of the same
##     source yield the same pin.
##   * ``[lock] project`` names the reprobuild project whose members the
##     pin covers, and ``[extensions] pin_scope = "project"`` says that the
##     ``[[repo]]`` list is exactly that project's membership (not the
##     workspace's whole active project set).  Both are hashed, so pins of
##     different projects, or a project pin and a differently-scoped one,
##     can never be equal.  ``[extensions]`` is where reprobuild's record
##     format admits keys of its own readers do not know.
##   * ``[extensions] unmaterialized_repos`` lists declared repos with no
##     checkout (Workspace-Manifests.md § "Declared repos with no on-disk
##     checkout"); emitted only when non-empty, sorted like ``[[repo]]``.
##   * TOML basic strings, LF line endings, UTF-8, no BOM, one trailing
##     newline.
##
## The value stored in ``runs.manifest_hash`` / ``campaigns.manifest_hash``
## is ``wslock-v1:sha256:<hex>`` — the sha256 of the canonical record —
## and the record itself is stored next to it in
## ``design_review.workspace_pins`` (migration 011), so a pin is
## resolvable from the database alone.  Every revision in a pin is
## *published*: capture refuses unpublished HEADs (``clean_tree.nim``),
## and ``captureWorkspacePin`` refuses them again, so a stored pin is
## replayable on any machine that can fetch the repos.
##
## Older values in the same columns are recognisable by shape and are
## never mistaken for a workspace lock (``classifyPin``): a bare 64-hex
## value is a retired ``repo manifest -r`` hash (no content was ever
## stored for it), ``seeded:<tag>`` marks a run ingested by
## ``isonim-review seed-run``.

import std/[algorithm, strutils]

import ./workspace_observation

type
  WorkspacePinError* = object of CatchableError

  LockedRepo* = object
    name*, path*, remote*, revision*: string

  UnmaterializedRepo* = object
    name*, path*, remote*, reason*: string

  WorkspaceLock* = object
    project*: string
      ## The reprobuild project whose membership the pin covers.
    scope*: string
      ## ``pin_scope``; ``ProjectScope`` for every pin capture writes.
    repos*: seq[LockedRepo]
    unmaterialized*: seq[UnmaterializedRepo]

  WorkspacePin* = object
    pin*: string
      ## ``wslock-v1:sha256:<hex>`` — what the run row stores.
    lockToml*: string
      ## The canonical record the digest is taken over.
    lockRecord*: string
      ## ``<project>/<repo>@<sha>`` of a published reprobuild lock record
      ## pinning the same revisions, when one existed at capture time;
      ## "" otherwise.  Advisory: not part of the pin's identity.

  PinKind* = enum
    pkWorkspaceLock       ## ``wslock-v1:sha256:<hex>`` — resolvable
    pkSeeded              ## ``seeded:<tag>`` — seed-run, no pin
    pkLegacyRepoManifest  ## bare sha256 of a retired ``repo manifest -r``
    pkUnrecognised        ## anything else ("local", test strings, ...)

const
  LockSchema* = "reprobuild.workspace.lock.v1"
  WorkspacePinPrefix* = "wslock-v1:sha256:"
  SeededManifestHashPrefix* = "seeded:"
    ## Follow-up 3 — sentinel that marks runs ingested via
    ## ``isonim-review seed-run`` (no workspace pin, just pre-existing
    ## PNGs).  ``brief_at_revision`` reads the brief from the working
    ## tree for these.  Documented limitation: brief edits between
    ## seeding and review WILL affect the review output.
  NoCheckoutReason* = "no on-disk checkout"
  ProjectScope* = "project"
    ## ``pin_scope`` of a pin covering exactly one project's members.

# ---------------------------------------------------------------------------
# sha256 (FIPS 180-4).  In-process so the pin is identical on every host:
# the stdlib has no SHA-2, and the ``shasum`` shell-out used elsewhere in
# the design-review code does not exist as an executable on Windows.
# ---------------------------------------------------------------------------

const K256: array[64, uint32] = [
  0x428a2f98'u32, 0x71374491'u32, 0xb5c0fbcf'u32, 0xe9b5dba5'u32,
  0x3956c25b'u32, 0x59f111f1'u32, 0x923f82a4'u32, 0xab1c5ed5'u32,
  0xd807aa98'u32, 0x12835b01'u32, 0x243185be'u32, 0x550c7dc3'u32,
  0x72be5d74'u32, 0x80deb1fe'u32, 0x9bdc06a7'u32, 0xc19bf174'u32,
  0xe49b69c1'u32, 0xefbe4786'u32, 0x0fc19dc6'u32, 0x240ca1cc'u32,
  0x2de92c6f'u32, 0x4a7484aa'u32, 0x5cb0a9dc'u32, 0x76f988da'u32,
  0x983e5152'u32, 0xa831c66d'u32, 0xb00327c8'u32, 0xbf597fc7'u32,
  0xc6e00bf3'u32, 0xd5a79147'u32, 0x06ca6351'u32, 0x14292967'u32,
  0x27b70a85'u32, 0x2e1b2138'u32, 0x4d2c6dfc'u32, 0x53380d13'u32,
  0x650a7354'u32, 0x766a0abb'u32, 0x81c2c92e'u32, 0x92722c85'u32,
  0xa2bfe8a1'u32, 0xa81a664b'u32, 0xc24b8b70'u32, 0xc76c51a3'u32,
  0xd192e819'u32, 0xd6990624'u32, 0xf40e3585'u32, 0x106aa070'u32,
  0x19a4c116'u32, 0x1e376c08'u32, 0x2748774c'u32, 0x34b0bcb5'u32,
  0x391c0cb3'u32, 0x4ed8aa4a'u32, 0x5b9cca4f'u32, 0x682e6ff3'u32,
  0x748f82ee'u32, 0x78a5636f'u32, 0x84c87814'u32, 0x8cc70208'u32,
  0x90befffa'u32, 0xa4506ceb'u32, 0xbef9a3f7'u32, 0xc67178f2'u32]

proc rotr(x: uint32; n: int): uint32 {.inline.} =
  (x shr n) or (x shl (32 - n))

proc sha256Hex*(data: string): string =
  ## Lowercase-hex sha256 of ``data``'s bytes.
  var h = [0x6a09e667'u32, 0xbb67ae85'u32, 0x3c6ef372'u32, 0xa54ff53a'u32,
           0x510e527f'u32, 0x9b05688c'u32, 0x1f83d9ab'u32, 0x5be0cd19'u32]
  var msg = data
  let bitLen = uint64(data.len) * 8
  msg.add '\x80'
  while msg.len mod 64 != 56: msg.add '\0'
  for i in countdown(7, 0):
    msg.add char((bitLen shr (8 * i)) and 0xff)
  var w: array[64, uint32]
  var chunk = 0
  while chunk < msg.len:
    for t in 0 .. 15:
      let j = chunk + 4 * t
      w[t] = (uint32(ord(msg[j])) shl 24) or (uint32(ord(msg[j + 1])) shl 16) or
             (uint32(ord(msg[j + 2])) shl 8) or uint32(ord(msg[j + 3]))
    for t in 16 .. 63:
      let s0 = rotr(w[t - 15], 7) xor rotr(w[t - 15], 18) xor (w[t - 15] shr 3)
      let s1 = rotr(w[t - 2], 17) xor rotr(w[t - 2], 19) xor (w[t - 2] shr 10)
      w[t] = w[t - 16] + s0 + w[t - 7] + s1
    var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
    for t in 0 .. 63:
      let t1 = hh + (rotr(e, 6) xor rotr(e, 11) xor rotr(e, 25)) +
               ((e and f) xor ((not e) and g)) + K256[t] + w[t]
      let t2 = (rotr(a, 2) xor rotr(a, 13) xor rotr(a, 22)) +
               ((a and b) xor (a and c) xor (b and c))
      hh = g; g = f; f = e; e = d + t1
      d = c; c = b; b = a; a = t1 + t2
    h[0] += a; h[1] += b; h[2] += c; h[3] += d
    h[4] += e; h[5] += f; h[6] += g; h[7] += hh
    chunk += 64
  for v in h:
    result.add toHex(v, 8).toLowerAscii

# ---------------------------------------------------------------------------
# Canonical record
# ---------------------------------------------------------------------------

proc tomlString(s: string): string =
  ## TOML basic string.
  result = "\""
  for ch in s:
    case ch
    of '"': result.add "\\\""
    of '\\': result.add "\\\\"
    of '\b': result.add "\\b"
    of '\t': result.add "\\t"
    of '\n': result.add "\\n"
    of '\f': result.add "\\f"
    of '\r': result.add "\\r"
    of '\0' .. '\x07', '\x0B', '\x0E' .. '\x1F', '\x7F':
      result.add "\\u" & toHex(ord(ch), 4)
    else: result.add ch
  result.add '"'

proc cmpRepo(a, b: LockedRepo): int =
  result = cmp(a.path, b.path)
  if result == 0: result = cmp(a.name, b.name)

proc cmpUnmat(a, b: UnmaterializedRepo): int =
  result = cmp(a.path, b.path)
  if result == 0: result = cmp(a.name, b.name)

proc renderCanonicalLock*(lock: WorkspaceLock): string =
  ## The canonical record.  Order-insensitive in its inputs.
  var repos = lock.repos
  repos.sort(cmpRepo)
  var unmat = lock.unmaterialized
  unmat.sort(cmpUnmat)
  result = "schema = " & tomlString(LockSchema) & "\n\n[lock]\nproject = " &
           tomlString(lock.project) & "\n"
  for r in repos:
    result.add "\n[[repo]]\n"
    result.add "name = " & tomlString(r.name) & "\n"
    result.add "path = " & tomlString(r.path) & "\n"
    result.add "remote = " & tomlString(r.remote) & "\n"
    result.add "revision = " & tomlString(r.revision) & "\n"
  result.add "\n[extensions]\npin_scope = " & tomlString(lock.scope) & "\n"
  if unmat.len > 0:
    result.add "unmaterialized_repos = [\n"
    for u in unmat:
      result.add "  { name = " & tomlString(u.name) &
                 ", path = " & tomlString(u.path) &
                 ", remote = " & tomlString(u.remote) &
                 ", reason = " & tomlString(u.reason) & " },\n"
    result.add "]\n"

proc pinOf*(lockToml: string): string =
  ## The pin value for a canonical record.
  WorkspacePinPrefix & sha256Hex(lockToml)

# --- reader -----------------------------------------------------------------

proc fail(msg: string) {.noreturn.} =
  raise newException(WorkspacePinError, "workspace lock: " & msg)

proc readString(s: string; i: var int): string =
  ## Read a TOML basic string starting at ``s[i] == '"'``.
  if i >= s.len or s[i] != '"': fail("expected a string at column " & $i)
  inc i
  while true:
    if i >= s.len: fail("unterminated string")
    let ch = s[i]
    if ch == '"':
      inc i
      return
    if ch == '\\':
      if i + 1 >= s.len: fail("dangling escape")
      let e = s[i + 1]
      i += 2
      case e
      of '"': result.add '"'
      of '\\': result.add '\\'
      of 'b': result.add '\b'
      of 't': result.add '\t'
      of 'n': result.add '\n'
      of 'f': result.add '\f'
      of 'r': result.add '\r'
      of 'u':
        if i + 4 > s.len: fail("short \\u escape")
        let code = parseHexInt(s[i ..< i + 4])
        if code > 0x7F: fail("non-ASCII \\u escape is not canonical")
        result.add char(code)
        i += 4
      else: fail("unknown escape \\" & e)
    else:
      result.add ch
      inc i

proc expectLit(s: string; i: var int; lit: string) =
  if not s.continuesWith(lit, i):
    fail("expected `" & lit & "`")
  i += lit.len

proc keyValue(line, key: string): string =
  var i = 0
  expectLit(line, i, key & " = ")
  result = readString(line, i)
  if i != line.len: fail("trailing text after `" & key & "`")

proc parseCanonicalLock*(lockToml: string): WorkspaceLock =
  ## Parse a canonical record.  Strict: anything ``renderCanonicalLock``
  ## would not have produced byte-for-byte is rejected, so a stored
  ## record can never mean something other than its digest says.
  if not lockToml.endsWith("\n"): fail("missing trailing newline")
  let lines = lockToml[0 ..< lockToml.len - 1].split('\n')
  var n = 0
  proc next(): string =
    if n >= lines.len: fail("unexpected end of record")
    result = lines[n]
    inc n
  if keyValue(next(), "schema") != LockSchema:
    fail("unsupported schema (want " & LockSchema & ")")
  if next() != "": fail("expected a blank line after `schema`")
  if next() != "[lock]": fail("expected `[lock]`")
  result.project = keyValue(next(), "project")
  while n < lines.len:
    if next() != "": fail("expected a blank line between tables")
    let header = next()
    if header == "[[repo]]":
      var r: LockedRepo
      r.name = keyValue(next(), "name")
      r.path = keyValue(next(), "path")
      r.remote = keyValue(next(), "remote")
      r.revision = keyValue(next(), "revision")
      result.repos.add r
    elif header == "[extensions]":
      result.scope = keyValue(next(), "pin_scope")
      if n == lines.len: break
      if next() != "unmaterialized_repos = [":
        fail("expected `unmaterialized_repos = [`")
      while true:
        let line = next()
        if line == "]": break
        var i = 0
        var u: UnmaterializedRepo
        expectLit(line, i, "  { name = "); u.name = readString(line, i)
        expectLit(line, i, ", path = "); u.path = readString(line, i)
        expectLit(line, i, ", remote = "); u.remote = readString(line, i)
        expectLit(line, i, ", reason = "); u.reason = readString(line, i)
        expectLit(line, i, " },")
        if i != line.len: fail("trailing text in unmaterialized_repos")
        result.unmaterialized.add u
      if n != lines.len: fail("`[extensions]` must be the last table")
    else:
      fail("unexpected table `" & header & "`")
  if result.scope.len == 0:
    fail("missing `[extensions] pin_scope`")
  if renderCanonicalLock(result) != lockToml:
    fail("record is not in canonical form")

# ---------------------------------------------------------------------------
# Pin classification
# ---------------------------------------------------------------------------

proc isLowerHex64(s: string): bool =
  s.len == 64 and s.allCharsInSet({'0'..'9', 'a'..'f'})

proc classifyPin*(value: string): PinKind =
  ## What kind of value a ``manifest_hash`` column holds.
  if value.startsWith(WorkspacePinPrefix) and
      isLowerHex64(value[WorkspacePinPrefix.len .. ^1]):
    pkWorkspaceLock
  elif value.startsWith(SeededManifestHashPrefix):
    pkSeeded
  elif isLowerHex64(value.toLowerAscii):
    pkLegacyRepoManifest
  else:
    pkUnrecognised

proc isSeededManifestHash*(manifestHash: string): bool =
  ## True iff ``manifestHash`` carries the ``seeded:`` sentinel.
  classifyPin(manifestHash) == pkSeeded

proc resolvePin*(pin, lockToml: string): WorkspaceLock =
  ## Verify that ``lockToml`` is the record ``pin`` names and parse it.
  if classifyPin(pin) != pkWorkspaceLock:
    fail("`" & pin & "` is not a workspace-lock pin")
  if pinOf(lockToml) != pin:
    fail("stored record does not hash to " & pin)
  parseCanonicalLock(lockToml)

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------

proc lockFromObservation*(obs: WorkspaceObservation): WorkspaceLock =
  ## The lock content for an observed workspace.  Raises when the
  ## observation contains a state a pin must never describe (dirty,
  ## untracked, unpublished, or unreadable checkouts) — the clean-tree
  ## gate refuses those first; this is the second line of defence.
  if obs.project.len == 0:
    fail("observation names no project")
  result.project = obs.project
  result.scope = ProjectScope
  for r in obs.repos:
    if not r.materialized:
      result.unmaterialized.add UnmaterializedRepo(
        name: r.name, path: r.path, remote: r.remote,
        reason: NoCheckoutReason)
      continue
    if r.headSha.len != 40 and r.headSha.len != 64:
      fail("repo `" & r.path & "` has no readable HEAD")
    if r.uncommitted.len > 0 or r.untracked.len > 0:
      fail("repo `" & r.path & "` has uncommitted or untracked files")
    if not r.isPublished:
      fail("repo `" & r.path & "` HEAD " & r.headSha &
           " is not on its declared remote '" & r.remote &
           "'; push it before capturing" &
           (if r.publicationDetail.len > 0: " (" & r.publicationDetail & ")"
            else: ""))
    result.repos.add LockedRepo(name: r.name, path: r.path,
                                remote: r.remote, revision: r.headSha)
  if result.repos.len == 0:
    fail("no checked-out repo to pin")

proc captureWorkspacePin*(obs: WorkspaceObservation): WorkspacePin =
  ## The pin for an observed (and gated) workspace.
  let toml = renderCanonicalLock(lockFromObservation(obs))
  WorkspacePin(pin: pinOf(toml), lockToml: toml,
               lockRecord: publishedLockRecord(obs))

proc captureWorkspacePin*(workspaceRoot: string;
                          project = DesignReviewProject): WorkspacePin =
  ## Observe ``project`` in the workspace at ``workspaceRoot`` through
  ## reprobuild and pin it.  Raises ``WorkspacePinError`` (or
  ## ``WorkspaceObservationError``) when it cannot be pinned.
  captureWorkspacePin(observeWorkspace(workspaceRoot, project))
