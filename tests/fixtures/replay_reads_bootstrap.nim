## Deliberate INTERNAL foundation import. Context is an actual prior snapshot
## supplied by the owner integration driver, not alleged archive metadata.
import std/json
import isonim/core/clock
import isonim/core/private/replay_reads
proc context(): cstring {.importjs: "JSON.stringify(globalThis.xrReadBootContext)".}
let originalContext = parseJson($context())
let selected* = newInternalReadReplay(originalContext)
originalContext["buildId"] = %"mutated-caller"
originalContext["assignment"]["read"] = %"mutated-nested-caller"
currentClock = selected
