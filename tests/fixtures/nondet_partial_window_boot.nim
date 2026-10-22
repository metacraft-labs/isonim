## Importing the nondeterminism boundary is the behaviour under test: when a
## `window` object exists, module initialisation installs the real backend and
## takes the boot environment snapshot. The host decides which window members
## exist; this fixture only publishes, as JSON text, what that snapshot recorded.
import std/json
import isonim/core/nondet

let bootSnapshot = cstring($env())
{.emit: "globalThis.isonimBootEnv = `bootSnapshot`;".}
