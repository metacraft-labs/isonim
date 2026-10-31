## Real private-producer acceptance test. No transports, builds or processes
## are mocked. Invoke explicitly in a workspace containing Agent Harbor; absence
## is an error here, while ordinary public editor tests use the real tiny Repro
## producer in test_design_review_harbor_build.nim and require no private repo.
import std/[os, httpclient, unittest, tempfiles, strutils]
import ../tools/isonim_review/[config, local_harbor]

suite "workspace Harbor live runtime":
  test "two runtimes share source build but keep independent services":
    let repo = getEnv("ISONIM_AGENT_HARBOR_SIBLING")
    require repo.len > 0
    require fileExists(repo / "repro.nim")
    let runtimeHome = createTempDir("isonim-live-harbor-home-", "")
    let oldHome = getEnv("AH_HOME")
    let oldDb = getEnv("AH_DAEMON_DB_PATH")
    let inheritedDb = runtimeHome / "inherited.sqlite"
    writeFile(inheritedDb, "parent database must remain untouched")
    putEnv("AH_DAEMON_DB_PATH", inheritedDb)
    putEnv("AH_HOME", runtimeHome)
    defer:
      if oldHome.len > 0: putEnv("AH_HOME", oldHome)
      else: delEnv("AH_HOME")
      if oldDb.len > 0: putEnv("AH_DAEMON_DB_PATH", oldDb)
      else: delEnv("AH_DAEMON_DB_PATH")
      removeDir(runtimeHome)
    var cfg = defaults()
    var runtime = prepareLocalHarbor(cfg)
    defer: runtime.stop()
    require cfg.agent.backend == "harbor"
    require cfg.agent.harborUrl.len > 0
    require runtime.process != nil
    check getFilePermissions(runtime.stateDir) == {fpUserRead, fpUserWrite, fpUserExec}
    let client = newHttpClient(timeout = 3000)
    defer: client.close()
    check int(client.get(cfg.agent.harborUrl & "/api/v1/healthz").code) == 200
    let builtTimestamp = getLastModificationTime(runtime.executable)
    var secondCfg = defaults()
    var second = prepareLocalHarbor(secondCfg)
    defer: second.stop()
    require second.executable == runtime.executable
    check getLastModificationTime(second.executable) == builtTimestamp
    require secondCfg.agent.harborUrl != cfg.agent.harborUrl
    require second.stateDir != runtime.stateDir
    check getFilePermissions(second.stateDir) == {fpUserRead, fpUserWrite, fpUserExec}
    require fileExists(runtime.stateDir / "daemon.sqlite")
    require fileExists(second.stateDir / "daemon.sqlite")
    check readFile(runtime.stateDir / "daemon.sqlite").startsWith("SQLite format 3")
    check readFile(second.stateDir / "daemon.sqlite").startsWith("SQLite format 3")
    check readFile(inheritedDb) == "parent database must remain untouched"
    check not fileExists(runtimeHome / "daemon.sqlite")
    check getEnv("AH_HOME") == runtimeHome
    check getEnv("AH_DAEMON_DB_PATH") == inheritedDb
    check int(client.get(secondCfg.agent.harborUrl & "/api/v1/healthz").code) == 200
    second.stop()
    check int(client.get(cfg.agent.harborUrl & "/api/v1/healthz").code) == 200
    expect CatchableError:
      discard client.get(secondCfg.agent.harborUrl & "/api/v1/healthz")
    var thirdCfg = defaults()
    var third = prepareLocalHarbor(thirdCfg)
    defer: third.stop()
    check getFilePermissions(third.stateDir) == {fpUserRead, fpUserWrite, fpUserExec}
    runtime.stop()
    check int(client.get(thirdCfg.agent.harborUrl & "/api/v1/healthz").code) == 200
    check readFile(inheritedDb) == "parent database must remain untouched"
