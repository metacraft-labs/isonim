## isonim/routing/outlet.nim
##
## Outlet — projects the matched child route inside a layout component.
## When a parent route has children, the parent component renders an Outlet
## that displays the currently matched child. Layout components persist
## across sibling route transitions; only the Outlet content swaps.

import ../core/[signals, computation, owner, graph]

# Thread-local depth counter: tracks which level of the match chain
# the current render is at, so nested Outlets know which entry to show.
var outletDepth* {.threadvar.}: int

type
  MatchChainEntry* = object
    ## One level of the matched route chain.
    component*: proc()
    params*: seq[(string, string)]

  OutletState* = ref object
    ## Manages the reactive rendering of a single Outlet level.
    chain*: Signal[seq[MatchChainEntry]]
    depth*: int
    currentRoot*: OwnerBase
    currentDispose*: proc()
    lastComponent*: proc()

proc renderOutlet*(state: OutletState) =
  ## Renders (or re-renders) the child component at this Outlet's depth.
  ## If the component identity hasn't changed, does nothing (layout persistence).
  let chainVal = state.chain.val
  if state.depth >= chainVal.len:
    # No child at this depth — dispose any existing content
    if state.currentDispose != nil:
      state.currentDispose()
      state.currentDispose = nil
      state.currentRoot = nil
      state.lastComponent = nil
    return

  let entry = chainVal[state.depth]
  if entry.component == state.lastComponent:
    # Same layout/component — don't re-render (layout persistence)
    return

  # Different component — dispose old, render new
  if state.currentDispose != nil:
    state.currentDispose()

  state.lastComponent = entry.component

  createRoot proc(dispose: proc()) =
    state.currentDispose = dispose
    state.currentRoot = getOwner()
    let prevDepth = outletDepth
    outletDepth = state.depth + 1
    entry.component()
    outletDepth = prevDepth

proc createOutletState*(chain: Signal[seq[MatchChainEntry]]; depth: int): OutletState =
  ## Creates an OutletState that reactively renders the child at `depth`.
  let state = OutletState(
    chain: chain,
    depth: depth,
  )

  # Set up reactive effect: when the chain changes, re-render if needed
  createEffect proc() =
    renderOutlet(state)

  # Register cleanup to dispose the child root when this owner is cleaned
  onCleanup proc() =
    if state.currentDispose != nil:
      state.currentDispose()

  state
