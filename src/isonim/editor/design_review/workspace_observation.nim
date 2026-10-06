## REV-M5 — read-only observation of a reprobuild workspace.
##
## The design-review clean-tree gate and the workspace pin both need the
## same facts about the workspace: which repos participate, what each
## one's HEAD is, whether its tree is clean, and whether that HEAD is on
## a remote.  reprobuild owns all of those facts (membership is the
## project's manifest; the per-repo evidence is reprobuild's own VCS
## query layer), so this module asks reprobuild instead of re-deriving
## them.
##
## *Scope: one reprobuild project.*  Every query names the project
## explicitly (``repro workspace status <project>``), which reprobuild
## resolves to exactly that project's members — the repos its
## ``projects/<project>.toml`` includes, which for ``isonim`` are the
## repos the design review builds from (``isonim``, ``isonim-examples``,
## ``isonim-render-serve``, ``nim-everywhere``, ...).  Without the
## argument reprobuild answers for the whole active project set
## (``.repro/workspace.toml`` ``projects``), so an unpublished commit in
## an unrelated project would block every capture.  reprobuild has no
## per-repo dependency closure query for ``status``; the project's own
## member list is how a project declares what it consumes.
##
##   * ``repro workspace status <project> --files --file-details --json`` — per declared
##     repo: ``checkoutState`` (``missing`` / ``dirty`` / ``clean``),
##     ``headSha``, and one ``{code, path}`` per changed path (``??`` =
##     untracked).  Also the latest lock record in the workspace's record
##     store and each repo's ``lockState`` against it.
##   * ``repro workspace list <project> --json`` — the declared ``remote``
##     of every repo (which the lock record format carries but ``status``
##     doesn't) and the ``fetchUrl`` it resolves to.
##
## *Publication is checked against the declared remote.*  ``status``
## also reports ``isPublished``, but reprobuild scopes it to a git remote
## literally named ``origin`` and, when the checkout has none, accepts a
## remote-tracking ref of *any* remote.  A commit that only a personal
## fork or a stray mirror holds would then count as published although
## nobody cloning from the manifest can fetch it.  So the observation
## decides publication itself (``checkDeclaredRemotePublication``): HEAD
## must be reachable from a ``refs/remotes/<r>/*`` ref of a git remote
## ``<r>`` whose URL is the repo's declared ``fetchUrl``.
##
## Both are read-only verbs with a documented JSON report contract
## (reprobuild-specs ``CLI/README.md`` § "Report Documents",
## ``CLI/workspace.md`` § ``status`` / ``list``).  We use
## ``--write-report=<tmp>`` to read the document from a file of our own,
## so warnings repro prints on stderr can never corrupt the JSON we
## parse.  ``repro workspace lock`` is deliberately *not* used: an
## explicit ``workspace lock`` publishes (commit + push) to the record
## store, and capturing a design-review run must not publish anything.
##
## The ``repro`` binary is found on ``PATH`` (it is how the dev shell is
## entered, so it is always there in a real workspace).
## ``ISONIM_REVIEW_REPRO`` overrides it.

import std/[json, os, osproc, streams, strutils, uri]

type
  WorkspaceObservationError* = object of CatchableError

  ObservedRepo* = object
    name*: string
    path*: string           ## workspace-relative, forward slashes
    remote*: string         ## declared remote name (``repos/<repo>.toml``)
    fetchUrl*: string       ## the URL the declared remote resolves to
    materialized*: bool     ## false when reprobuild reports ``missing``
    headSha*: string
    isPublished*: bool
      ## HEAD is reachable from a remote-tracking ref of the declared
      ## remote (``checkDeclaredRemotePublication``).
    publicationDetail*: string
      ## Why ``isPublished`` is false, when that is known.
    uncommitted*: seq[string]
    untracked*: seq[string]
    diagnostic*: string     ## reprobuild's per-repo query diagnostic
    lockState*: string      ## ``at-lock`` / ``drifted-from-lock`` / ...

  WorkspaceObservation* = object
    workspaceRoot*: string
    project*: string        ## the reprobuild project observed (the scope)
    repos*: seq[ObservedRepo]
    recordStoreRoot*: string
    latestLockRecord*: string
      ## Absolute path of the latest lock record reprobuild found in the
      ## record store, or "" when none exists.

const ReproOverrideEnv* = "ISONIM_REVIEW_REPRO"

const DesignReviewProject* = "isonim"
  ## The reprobuild project the design review gates and pins by default:
  ## the project whose members isonim's previews are built from.

proc reproBinary*(): string =
  ## The ``repro`` executable to run, or "" when none is available.
  result = getEnv(ReproOverrideEnv)
  if result.len == 0:
    result = findExe("repro")

proc runReproReport(repro, workspaceRoot: string;
                    verbArgs: openArray[string]): JsonNode =
  ## Run ``repro workspace <verbArgs> --json --write-report=<tmp>`` and
  ## return the parsed report.
  let reportPath = getTempDir() / ("isonim-review-repro-" &
    $getCurrentProcessId() & "-" & verbArgs[0] & ".json")
  if fileExists(reportPath): removeFile(reportPath)
  defer:
    if fileExists(reportPath): removeFile(reportPath)
  var args = @["workspace"]
  for a in verbArgs: args.add a
  args.add "--json"
  args.add "--workspace-root=" & workspaceRoot
  args.add "--write-report=" & reportPath
  let p = startProcess(repro, args = args, workingDir = workspaceRoot,
                       options = {poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  let cmdLine = "repro " & args[0 .. ^2].join(" ")
  if code != 0:
    raise newException(WorkspaceObservationError,
      "`" & cmdLine & "` failed (exit " & $code & "): " & output.strip())
  if not fileExists(reportPath):
    raise newException(WorkspaceObservationError,
      "`" & cmdLine & "` wrote no report document")
  try:
    result = parseFile(reportPath)
  except CatchableError as e:
    raise newException(WorkspaceObservationError,
      "`" & cmdLine & "` wrote an unreadable report: " & e.msg)

proc str(node: JsonNode; key: string): string =
  if node.kind == JObject and node.hasKey(key) and node[key].kind == JString:
    node[key].getStr
  else: ""

proc parseWorkspaceObservation*(workspaceRoot: string;
                                status, list: JsonNode): WorkspaceObservation =
  ## Build the observation from the two report documents.  Pure, so the
  ## field mapping can be tested without a workspace.
  if status.kind != JObject or not status.hasKey("repos") or
      status["repos"].kind != JArray:
    raise newException(WorkspaceObservationError,
      "`repro workspace status` report has no `repos` array")
  result.workspaceRoot = workspaceRoot
  result.project = status.str("project")
  result.recordStoreRoot = status.str("recordStoreRoot")
  if status.hasKey("hasLockIndex") and status["hasLockIndex"].getBool:
    result.latestLockRecord = status.str("lockIndexPath")
  var remotes: seq[(string, string, string)]
  if list.kind == JObject and list.hasKey("repos"):
    for r in list["repos"]:
      remotes.add (r.str("path"), r.str("remote"), r.str("fetchUrl"))
  for r in status["repos"]:
    var repo = ObservedRepo(
      name: r.str("name"),
      path: r.str("path").replace('\\', '/'),
      materialized: r.str("checkoutState") != "missing",
      headSha: r.str("headSha").toLowerAscii,
      isPublished: r.hasKey("isPublished") and r["isPublished"].getBool,
      diagnostic: r.str("diagnostic"),
      lockState: r.str("lockState"))
    for (path, remote, fetchUrl) in remotes:
      if path.replace('\\', '/') == repo.path:
        repo.remote = remote
        repo.fetchUrl = fetchUrl
        break
    if r.hasKey("fileDetails"):
      for fd in r["fileDetails"]:
        let code = fd.str("code")
        let path = fd.str("path")
        if path.len == 0: continue
        if code == "??": repo.untracked.add path
        else: repo.uncommitted.add path
    let isClean = r.hasKey("isClean") and r["isClean"].getBool
    if repo.materialized and not isClean and
        repo.uncommitted.len == 0 and repo.untracked.len == 0:
      # reprobuild says dirty but listed no paths (a repro without
      # ``--file-details``): keep the verdict, never drop it.
      repo.uncommitted.add "<reported dirty by `repro workspace status`>"
    result.repos.add repo

proc git(args: openArray[string]; cwd: string): tuple[ok: bool; output: string]

proc normalizeRemoteUrl*(url: string): string =
  ## Comparable form of a git remote URL: scheme, user info and a
  ## trailing ``.git`` / ``/`` dropped, scp-style ``host:path`` turned
  ## into ``host/path``, ``file://`` URLs and local paths reduced to a
  ## forward-slash path, all lowercased (hosts and Windows paths are
  ## case-insensitive).
  var u = url.strip()
  if u.toLowerAscii.startsWith("file://"):
    u = decodeUrl(u["file://".len .. ^1], decodePlus = false)
    if u.len >= 3 and u[0] == '/' and u[2] == ':': u = u[1 .. ^1]
  else:
    let schemeEnd = u.find("://")
    if schemeEnd > 0:
      u = u[schemeEnd + 3 .. ^1]
      let at = u.find('@')
      let slash = u.find('/')
      if at >= 0 and (slash < 0 or at < slash): u = u[at + 1 .. ^1]
    elif not (u.len >= 2 and u[1] == ':') and ':' in u and
        (u.find('/') < 0 or u.find(':') < u.find('/')):
      # scp-like ``[user@]host:path``
      let at = u.find('@')
      if at >= 0 and at < u.find(':'): u = u[at + 1 .. ^1]
      u[u.find(':')] = '/'
  u = u.replace('\\', '/').toLowerAscii
  while u.endsWith("/"): u.setLen(u.len - 1)
  if u.endsWith(".git"): u.setLen(u.len - ".git".len)
  u

proc checkDeclaredRemotePublication*(obs: var WorkspaceObservation) =
  ## Set every materialized repo's ``isPublished`` from its declared
  ## remote: true iff HEAD is reachable from a ``refs/remotes/<r>/*`` ref
  ## of a git remote ``<r>`` whose URL is the declared ``fetchUrl``.
  ## Anything that prevents the check answers "not published", with
  ## ``publicationDetail`` saying why.
  for repo in obs.repos.mitems:
    if not repo.materialized or repo.headSha.len == 0: continue
    repo.isPublished = false
    let abs = obs.workspaceRoot / repo.path
    if repo.fetchUrl.len == 0:
      repo.publicationDetail = "`repro workspace list` names no fetch URL " &
        "for the declared remote '" & repo.remote & "'"
      continue
    let want = normalizeRemoteUrl(repo.fetchUrl)
    let cfg = git(["config", "--get-regexp", "^remote\\..*\\.url$"], abs)
    var names: seq[string]
    if cfg.ok:
      for line in cfg.output.splitLines:
        let sp = line.find(' ')
        if sp <= 0: continue
        let key = line[0 ..< sp]                 # remote.<name>.url
        if key.len > "remote..url".len and
            normalizeRemoteUrl(line[sp + 1 .. ^1]) == want:
          names.add key["remote.".len ..< key.len - ".url".len]
    if names.len == 0:
      repo.publicationDetail = "no git remote of this checkout points at " &
        "the declared remote '" & repo.remote & "' (" & repo.fetchUrl & ")"
      continue
    var failure = ""
    for name in names:
      let refs = git(["for-each-ref", "--contains", repo.headSha,
                      "--format=%(refname)", "refs/remotes/" & name & "/"], abs)
      if not refs.ok:
        failure = "`git for-each-ref --contains` failed: " & refs.output
        continue
      if refs.output.len > 0:
        repo.isPublished = true
        break
    if not repo.isPublished:
      repo.publicationDetail =
        if failure.len > 0: failure
        else: "HEAD is on no branch of the declared remote '" & repo.remote &
          "' (git remote " & names.join(", ") & ")"

proc observeWorkspace*(workspaceRoot: string;
                       project = DesignReviewProject): WorkspaceObservation =
  ## Ask reprobuild for ``project``'s membership and per-repo state in the
  ## workspace at ``workspaceRoot``.  Raises ``WorkspaceObservationError``
  ## when ``repro`` is missing, the directory is not a reprobuild
  ## workspace, the project is not defined there, or a report is
  ## malformed.
  if project.len == 0:
    raise newException(WorkspaceObservationError,
      "observeWorkspace: a reprobuild project name is required")
  let repro = reproBinary()
  if repro.len == 0:
    raise newException(WorkspaceObservationError,
      "`repro` is not on PATH (set " & ReproOverrideEnv &
      " to override); the design-review workspace gate reads the " &
      "workspace through reprobuild")
  let root = absolutePath(workspaceRoot)
  if not dirExists(root):
    raise newException(WorkspaceObservationError,
      "workspace root does not exist: " & root)
  # ``--files`` narrows status to the file query (HEAD, cleanliness and
  # publication are always gathered); stash / ahead-behind / unmerged
  # queries cost a git call per repo and the gate needs none of them.
  let status = runReproReport(repro, root,
                              ["status", project, "--files", "--file-details"])
  let list = runReproReport(repro, root, ["list", project])
  result = parseWorkspaceObservation(root, status, list)
  if result.project != project:
    raise newException(WorkspaceObservationError,
      "`repro workspace status " & project & "` answered for project '" &
      result.project & "'")
  if list.kind != JObject or list.str("project") != project:
    raise newException(WorkspaceObservationError,
      "`repro workspace list " & project & "` answered for project '" &
      list.str("project") & "'")
  checkDeclaredRemotePublication(result)

# ---------------------------------------------------------------------------
# Published lock record lookup
# ---------------------------------------------------------------------------

proc decodeLockComponent(s: string): string =
  ## Inverse of reprobuild's lock path-component encoding
  ## (Workspace-Manifests.md § "Path components are encoded names"):
  ## ``%HH`` (uppercase hex) stands for one byte; everything else is
  ## literal.
  var i = 0
  while i < s.len:
    if s[i] == '%' and i + 2 <= s.high and
        s[i + 1] in HexDigits and s[i + 2] in HexDigits:
      result.add char(parseHexInt(s[i + 1 .. i + 2]))
      i += 3
    else:
      result.add s[i]
      inc i

proc git(args: openArray[string]; cwd: string): tuple[ok: bool; output: string] =
  let p = startProcess("git", args = args, workingDir = cwd,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  (p.waitForExit() == 0, output.strip())

proc publishedLockRecord*(obs: WorkspaceObservation): string =
  ## ``<project>/<repo>@<sha>`` of a *published* reprobuild lock record
  ## that pins exactly the revisions this observation saw, or "".
  ##
  ## The record qualifies when every materialized repo is ``at-lock``
  ## against the latest record (so the record and the observation agree
  ## on every checkout) and the record file is present in the record
  ## store's upstream branch (so anybody with access to the store can
  ## read it).  Advisory only — the pin's identity is its content hash,
  ## and nothing is ever written or pushed here.
  if obs.latestLockRecord.len == 0 or obs.recordStoreRoot.len == 0:
    return ""
  var anyMaterialized = false
  for r in obs.repos:
    if not r.materialized: continue
    anyMaterialized = true
    if r.lockState != "at-lock": return ""
  if not anyMaterialized: return ""
  let rel = relativePath(obs.latestLockRecord, obs.recordStoreRoot)
                .replace('\\', '/')
  let parts = rel.split('/')
  if parts.len != 4 or parts[0] != "locks" or not parts[3].endsWith(".toml"):
    return ""
  let upstream = git(["rev-parse", "--abbrev-ref",
                      "--symbolic-full-name", "@{u}"], obs.recordStoreRoot)
  if not upstream.ok or upstream.output.len == 0: return ""
  if not git(["cat-file", "-e", upstream.output & ":" & rel],
             obs.recordStoreRoot).ok:
    return ""
  decodeLockComponent(parts[1]) & "/" & decodeLockComponent(parts[2]) &
    "@" & decodeLockComponent(parts[3][0 ..< parts[3].len - ".toml".len])
