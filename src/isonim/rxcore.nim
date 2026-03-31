## rxcore — the adapter seam between IsoNim's reactive core and renderers.
##
## Renderers import only this module, never core/* directly.
## This provides a stable, minimal API surface for renderer implementations.

import isonim/core/[owner, computation, batch, graph, signals]

# Re-export core types and procs that renderers need
export owner.createRoot, owner.onCleanup, owner.getOwner, owner.runWithOwner
export signals.createSignal, signals.val, signals.`val=`, signals.update
export computation.createEffect, computation.createRenderEffect, computation.createMemo
export batch.batch, batch.untrack
export graph.OwnerBase

# ---- Renderer-facing convenience wrappers ----

proc root*(fn: proc(dispose: proc())) =
  ## Creates a reactive root (wraps createRoot). Void variant.
  createRoot(fn)

proc effect*(fn: proc()) =
  ## Creates a render effect (synchronous, used by renderers).
  createRenderEffect(fn)

proc memo*[T](fn: proc(): T): proc(): T =
  ## Creates a memoized accessor (wraps createMemo).
  ## Returns a closure that reads the memo value.
  let m = createMemo(fn)
  return proc(): T = m.val

proc createComponent*[P, R](comp: proc(props: P): R; props: P): R =
  ## Invokes a component function under untrack with proper owner tracking.
  ## Components don't track their own props -- only their body does.
  untrack(proc(): R = comp(props))

proc mergeProps*[T](base: T; overrides: T): T =
  ## Merges two property objects. Simple shallow merge for now.
  ## Server version may differ (added in SSR milestone).
  # For now, overrides take full precedence
  result = overrides

# Shared hydration config
type
  HydrationContext* = ref object
    id*: string
    count*: int
    noHydrate*: bool

  SharedConfig* = object
    context*: HydrationContext

var sharedConfig*: SharedConfig
