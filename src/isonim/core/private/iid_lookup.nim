## Shared stable-IID lookup only. Renderer initialization owns all registry,
## validation, observer and weak-reference state; importing this binding creates
## none. Lookup itself validates/mutates membership and dereferences weak refs.
import std/jsffi

proc resolveIidLookup*(iid: cstring): JsObject {.importjs: "((iid) => { globalThis.__isonimValidateIids(iid); return globalThis.__isonimIids.get(iid)?.deref() || null; })(#)".}
