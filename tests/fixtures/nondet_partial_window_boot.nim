## Importing the nondeterminism boundary is the behaviour under test: when a
## `window` object exists, module initialisation installs the real backend and
## takes the boot environment snapshot. The host decides which window members
## exist. Publish the snapshot as JSON plus public-facade operations for browser
## cache/copy controls; no private raw read or environment value is synthesized.
import std/json
import isonim/core/nondet

let bootSnapshot = cstring($env())
{.emit: "globalThis.isonimBootEnv = `bootSnapshot`;".}

proc readSnapshot(): cstring = cstring($env())
proc resetSnapshot() = install(newRealBackend(1))
proc mutateSnapshot() =
  let copy = env()
  copy["timeZone"] = %"caller-mutation"
  copy["colorScheme"] = %99
  copy["referrerOrigin"] = %"caller-mutation"
  copy["bootDateEpochMs"] = %(-1)
{.emit: "globalThis.isonimReadEnv = `readSnapshot`; globalThis.isonimResetEnv = `resetSnapshot`; globalThis.isonimMutateEnv = `mutateSnapshot`;".}
