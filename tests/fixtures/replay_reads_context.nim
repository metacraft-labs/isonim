## Actual public Real snapshot used as explicit test configuration, not log Env.
import std/json
import isonim/core/nondet
# Include every guarded module in ordinary/dormant artifact omission controls.
import isonim/core/scheduler
import isonim/web/[events, hydration]
let context = ($env()).cstring
{.emit:["globalThis.xrReadBootContext=JSON.parse(",context,");"].}
