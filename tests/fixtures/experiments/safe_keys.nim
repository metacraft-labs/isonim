## Author keys remain data even when they name JavaScript object properties.
import std/tables
import isonim/[experiments]
import isonim/core/owner
type
  Proto {.experimentKey: "__proto__".} = enum
    p0, p1
  Constructor {.experimentKey: "constructor".} = enum
    c0, c1
let a = newExperimentAssignment()
a.assign["__proto__"] = 1
a.assign["constructor"] = 1
createRoot proc(dispose: proc()) =
  withExperiments(a):
    doAssert useExperiment[Proto]() == p1
    doAssert useExperiment[Constructor]() == c1
    doAssert a.exposed.len == 2
  dispose()
