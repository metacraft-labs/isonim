## Genuine caller context, actual owner cursor, deliberate private early choice.
import std/json
import isonim/core/clock
import isonim/core/private/replay_reads
proc context():cstring {.importjs:"JSON.stringify(globalThis.storageContext)".}
currentClock = newInternalReadReplay(parseJson($context()))
