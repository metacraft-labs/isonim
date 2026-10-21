## Exercises real compiler generic instantiation and real owner-scoped contexts.
## No mocks: companion shell harness compiles C, JS and invalid declarations.
import std/[tables, json]
import isonim/core/owner
import fixtures/experiments/[first, second]
when not defined(js):
  import std/[os, osproc, strutils]

proc local(): Cta = useExperiment[Cta]()
static:
  doAssert registrationCount("home-cta") == 1
  doAssert registrationCount("Color") == 1

doAssert first() == control
doAssert local() == control
let a = newExperimentAssignment("2026-10-22")
a.assign["unknown"] = 1
createRoot proc(dispose: proc()) =
  withExperiments(a):
    doAssert first() == control
    a.assign["home-cta"] = 1
    doAssert second() == control
    doAssert experimentResource(a)["assign"]["home-cta"].getInt == 0
    doAssert color() == plain
    doAssert a.exposed.len == 2
    doAssert a.exposed[0].key == "home-cta"
    doAssert a.exposed[0].callSite.len > 0
  dispose()
a.assign["home-cta"] = 9
createRoot proc(dispose: proc()) =
  withExperiments(a):
    doAssert first() == control
    doAssert a.exposed.len == 1
    doAssert a.exposed[0].arm == 0
  dispose()
a.assign["home-cta"] = 1
a.qaOverrides["home-cta"] = 2
createRoot proc(dispose: proc()) =
  withExperiments(a): doAssert first() == estimate
  dispose()
a.production = false
createRoot proc(dispose: proc()) =
  withExperiments(a): doAssert second() == startFree
  dispose()
doAssert first() == control
let resource = experimentResource(a)
doAssert resource["assign"]["home-cta"].getInt == 2
doAssert assignmentFromResource(resource).assign["home-cta"] == 2
doAssert a.assign["home-cta"] == 1
a.qaOverrides["home-cta"] = -1
createRoot proc(dispose: proc()) =
  withExperiments(a): doAssert first() == control
  dispose()
a.production = true
a.assign["home-cta"] = -1
createRoot proc(dispose: proc()) =
  withExperiments(a): doAssert first() == control
  dispose()
when not defined(js):
  # The standalone native milestone command must exercise the compiler's
  # rejection too, rather than relying exclusively on the aggregate harness.
  let root = currentSourcePath().parentDir.parentDir
  let compiler = findExe("nim")
  doAssert compiler.len > 0
  let duplicate = execCmdEx(quoteShell(compiler) & " c --hints:off --path:" &
    quoteShell(root / "src") & " --path:" &
    quoteShell(root.parentDir / "nim-everywhere/src") & " --out:" &
    quoteShell(root / "build/duplicate-experiment") & " " &
    quoteShell(root / "tests/fixtures/experiments/duplicate.nim"))
  doAssert duplicate.exitCode != 0
  doAssert duplicate.output.contains("duplicate experiment key"), duplicate.output
echo "experiment registration/runtime passed"
