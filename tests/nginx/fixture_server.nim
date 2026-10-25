## fixture_server.nim
##
## Starts and stops the nginx fixture (README.md) for the tests that run
## against it: tests/test_route_manifest.nim,
## tests/routing/t_manifest_negotiation.nim and
## tests/routing/t_manifest_streaming.nim.  The fixture must be built
## (`just build-nginx-fixture`); `ISONIM_NGINX_MODULE` names another module
## build (run_mutants.sh's mutants).

import std/[os, osproc, strutils, net, times, monotimes]

const
  repoRoot* = currentSourcePath().parentDir.parentDir.parentDir
  fixtureDir* = repoRoot / "build/nginx-fixture"

type Fixture* = object
  ## A running nginx of the fixture (one worker), on a free port.
  prefix*, pidFile*, errorLog*: string
  port*: int

proc readNginxBin(): string =
  for line in readFile(fixtureDir / "env.sh").splitLines:
    if line.startsWith("NGINX_BIN="):
      return line["NGINX_BIN=".len .. ^1]

proc freePort(): int =
  let s = newSocket()
  s.bindAddr(Port(0), "127.0.0.1")
  result = int(s.getLocalAddr()[1])
  s.close()

proc startFixture*(name = "isonim-route-manifest"): Fixture =
  ## Starts the fixture's nginx under a fresh prefix in the temporary
  ## directory (`<name>-<pid>`) and waits for its port.
  # ISONIM_NGINX_MODULE: another module build (run_mutants.sh's mutants).
  let module = getEnv("ISONIM_NGINX_MODULE", fixtureDir / "ngx_http_isonim_module.so")
  if not fileExists(module) or not fileExists(fixtureDir / "env.sh"):
    raise newException(IOError, "the nginx fixture is not built: run " &
      "`just build-nginx-fixture` (needs the ngx-isonim sibling checkout)")
  result.prefix = getTempDir() / (name & "-" & $getCurrentProcessId())
  removeDir(result.prefix)
  for d in ["client_body", "proxy", "fastcgi", "uwsgi", "scgi"]:
    createDir(result.prefix / d)
  result.port = freePort()
  result.pidFile = result.prefix / "nginx.pid"
  result.errorLog = result.prefix / "error.log"
  let conf = result.prefix / "nginx.conf"
  let (text, code) = execCmdEx("bash " & quoteShell(repoRoot / "tests/nginx/fixture_conf.sh") &
    " " & quoteShell(result.prefix) & " " & $result.port & " " & quoteShell(module) &
    " " & quoteShell(fixtureDir / "www"))
  doAssert code == 0, text
  writeFile(conf, text)
  let start = execShellCmd(quoteShell(readNginxBin()) & " -c " & quoteShell(conf) &
    " -p " & quoteShell(result.prefix) & " -e " & quoteShell(result.errorLog) &
    " < /dev/null > " & quoteShell(result.prefix / "start.log") & " 2>&1")
  doAssert start == 0, readFile(result.prefix / "start.log")
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while true:
    let s = newSocket()
    try:
      s.connect("127.0.0.1", Port(result.port), timeout = 200)
      s.close()
      break
    except CatchableError:
      s.close()
      doAssert getMonoTime() < deadline, "nginx did not open its port"

proc stop*(f: Fixture) =
  ## Stops the nginx this fixture started (its own pid file).
  if fileExists(f.pidFile):
    discard execCmd("kill -TERM " & readFile(f.pidFile).strip)

proc baseUrl*(f: Fixture): string = "http://127.0.0.1:" & $f.port
