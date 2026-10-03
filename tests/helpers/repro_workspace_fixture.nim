## Hermetic reprobuild workspace for the design-review gate / pin tests.
##
## Builds, under a fresh temp directory:
##
##   <scratch>/
##     origins/<repo>.git          bare "remote" per repo
##     ws/                         the workspace root
##       .repro/workspace.toml     active project set: <project> [, <otherProject>]
##       projects/<project>.toml   declares one remote + repo per name
##       projects/<otherProject>.toml  (optional) an unrelated second project
##       repos/<repo>.toml
##       <repo>/                   clone of origins/<repo>.git, one pushed commit
##
## ``project`` defaults to ``isonim`` — the project the design review gates
## and pins by default — so CLI-level tests need no extra configuration.
## so ``repro workspace status`` / ``list`` (what the gate and the pin
## read) see a real workspace whose repos are clean and published.  It
## never touches the real workspace or any shared record store.
##
## Every git call goes through ``startProcess`` with an argv — no shell —
## so the fixture runs the same on native Windows and POSIX.

import std/[os, osproc, streams, strutils, times, uri]

import isonim/editor/design_review/workspace_observation

type
  ReproWorkspace* = object
    scratch*: string   ## parent temp dir; removed by ``cleanup``
    root*: string      ## the workspace root the code under test reads
    project*: string
    repos*: seq[string]
    otherProject*: string    ## second project in the active set, or ""
    otherRepos*: seq[string]

proc git*(args: openArray[string]; cwd: string): string =
  ## Run git; raise ``IOError`` with its output on failure.
  let p = startProcess("git", args = args, workingDir = cwd,
                       options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  let output = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(IOError, "git " & args.join(" ") & " (in " & cwd &
                       ") failed (" & $code & "):\n" & output)
  output.strip()

proc requireRepro*() =
  ## The gate and the pin read the workspace through ``repro``; without
  ## it these tests cannot say anything, so fail loudly instead of
  ## skipping.
  if reproBinary().len == 0:
    raise newException(IOError,
      "`repro` is not on PATH (or $" & ReproOverrideEnv & "); " &
      "run the design-review tests through `repro exec --`")

proc fileUrlOf(path: string): string =
  var p = path.replace('\\', '/')
  if not p.startsWith("/"): p = "/" & p
  "file://" & encodeUrl(p, usePlus = false).multiReplace(
    ("%2F", "/"), ("%3A", ":"))

proc configureIdentity(repo: string) =
  discard git(["config", "user.email", "test@test"], repo)
  discard git(["config", "user.name", "tester"], repo)
  discard git(["config", "commit.gpgsign", "false"], repo)
  discard git(["config", "core.autocrlf", "false"], repo)

proc writeProjectManifest(ws: ReproWorkspace; project: string;
                          repos: openArray[string]) =
  var text = "schema = \"reprobuild.workspace.project.v1\"\n\n" &
    "[project]\nname = \"" & project & "\"\n" &
    "default_revision = \"main\"\ntrunk = \"main\"\n"
  for name in repos:
    text.add "\n[[remote]]\nname = \"" & name & "-origin\"\nfetch = \"" &
      fileUrlOf(ws.scratch / "origins" / (name & ".git")) & "\"\n"
  text.add "\nincludes = [\n"
  for name in repos:
    text.add "  \"repos/" & name & ".toml\",\n"
  text.add "]\n"
  writeFile(ws.root / "projects" / (project & ".toml"), text)
  for name in repos:
    writeFile(ws.root / "repos" / (name & ".toml"),
      "schema = \"reprobuild.workspace.repo.v1\"\n\n[repo]\n" &
      "name = \"" & name & "\"\npath = \"" & name & "\"\n" &
      "remote = \"" & name & "-origin\"\nrevision = \"main\"\n")

proc writeWorkspaceMetadata(ws: ReproWorkspace) =
  createDir(ws.root / "projects")
  createDir(ws.root / "repos")
  createDir(ws.root / ".repro")
  ws.writeProjectManifest(ws.project, ws.repos)
  var active = "\"" & ws.project & "\""
  if ws.otherProject.len > 0:
    ws.writeProjectManifest(ws.otherProject, ws.otherRepos)
    active.add ", \"" & ws.otherProject & "\""
  writeFile(ws.root / ".repro" / "workspace.toml",
    "schema = \"reprobuild.workspace.local.v1\"\n\n[workspace]\n" &
    "project = \"" & ws.project & "\"\n" &
    "projects = [" & active & "]\nbranch = \"main\"\n")

proc repoDir*(ws: ReproWorkspace; name: string): string =
  ws.root / name

proc headSha*(ws: ReproWorkspace; name: string): string =
  git(["rev-parse", "HEAD"], ws.repoDir(name))

proc commit*(ws: ReproWorkspace; name, message: string;
             files: openArray[(string, string)] = []): string =
  ## Write ``files`` (relative path, content) into the repo, commit
  ## everything, and return the new HEAD.  Not pushed.
  let repo = ws.repoDir(name)
  for (rel, body) in files:
    createDir(parentDir(repo / rel))
    writeFile(repo / rel, body)
  discard git(["add", "-A"], repo)
  discard git(["commit", "-q", "--allow-empty", "-m", message], repo)
  ws.headSha(name)

proc publish*(ws: ReproWorkspace; name: string) =
  ## Push the repo's HEAD to its origin (``main``), refreshing the
  ## remote-tracking ref.
  discard git(["push", "-q", "origin", "HEAD:main"], ws.repoDir(name))
  discard git(["fetch", "-q", "origin"], ws.repoDir(name))

proc commitAndPublish*(ws: ReproWorkspace; name, message: string;
                       files: openArray[(string, string)] = []): string =
  result = ws.commit(name, message, files)
  ws.publish(name)

proc newReproWorkspace*(suffix: string; repos: openArray[string];
                        project = DesignReviewProject;
                        files: openArray[(string, string, string)] = [];
                        otherProject = "";
                        otherRepos: openArray[string] = []):
                        ReproWorkspace =
  ## ``files`` = (repo, relative path, content) committed in each repo's
  ## initial (published) commit.  ``otherProject`` / ``otherRepos`` add a
  ## second, unrelated project to the workspace's active project set.
  requireRepro()
  result.scratch = getTempDir() / ("isonim_rws_" & suffix & "_" &
    $getCurrentProcessId() & "_" & $int(epochTime() * 1000))
  removeDir(result.scratch)
  createDir(result.scratch / "origins")
  result.root = result.scratch / "ws"
  createDir(result.root)
  result.project = project
  for name in repos: result.repos.add name
  result.otherProject = otherProject
  for name in otherRepos: result.otherRepos.add name
  for name in @repos & @otherRepos:
    let origin = result.scratch / "origins" / (name & ".git")
    discard git(["init", "-q", "--bare", "-b", "main", origin], result.scratch)
    discard git(["clone", "-q", origin, result.root / name], result.scratch)
    configureIdentity(result.root / name)
    discard git(["symbolic-ref", "HEAD", "refs/heads/main"], result.root / name)
    var initial = @[("README.md", name & "\n")]
    for (repo, rel, body) in files:
      if repo == name: initial.add (rel, body)
    discard result.commitAndPublish(name, "initial", initial)
    discard git(["branch", "-q", "--set-upstream-to=origin/main"],
                result.root / name)
  result.writeWorkspaceMetadata()

proc recordStore*(ws: ReproWorkspace): string =
  ws.root / ".repro" / "manifests"

proc addRecordStore*(ws: ReproWorkspace) =
  ## Give the workspace a lock record store: a checkout at
  ## ``.repro/manifests`` whose upstream is a bare repo inside the
  ## fixture's own scratch dir.
  let origin = ws.scratch / "origins" / "record-store.git"
  discard git(["init", "-q", "--bare", "-b", "main", origin], ws.scratch)
  discard git(["clone", "-q", origin, ws.recordStore], ws.scratch)
  configureIdentity(ws.recordStore)
  discard git(["symbolic-ref", "HEAD", "refs/heads/main"], ws.recordStore)
  writeFile(ws.recordStore / ".gitkeep", "")
  discard git(["add", "-A"], ws.recordStore)
  discard git(["commit", "-q", "-m", "seed record store"], ws.recordStore)
  discard git(["push", "-q", "-u", "origin", "main"], ws.recordStore)

proc lockAndPublish*(ws: ReproWorkspace): string =
  ## ``repro workspace lock`` against the fixture's OWN record store
  ## (``addRecordStore``), which publishes to the fixture's scratch bare
  ## repo and nowhere else.  Returns repro's output.
  let p = startProcess(reproBinary(), args = [
      "workspace", "lock", "--workspace-root=" & ws.root,
      "--record-store-root=" & ws.recordStore],
    workingDir = ws.root, options = {poStdErrToStdOut})
  defer: p.close()
  result = p.outputStream.readAll()
  let code = p.waitForExit()
  if code != 0:
    raise newException(IOError, "repro workspace lock failed (" & $code &
                       "):\n" & result)

proc cleanup*(ws: ReproWorkspace) =
  if ws.scratch.len > 0 and dirExists(ws.scratch):
    try: removeDir(ws.scratch)
    except OSError: discard  # a lingering handle on Windows; temp dir anyway
