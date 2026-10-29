## isonim/dsl/components.nim
##
## Built-in control-flow components: For, Index, Show, ErrorBoundary.
## Generic over renderer and node types -- works with any RendererBackend.
##
## Port of SolidJS rendering control flow components.

import std/tables
import ../core/[signals, computation, owner, platform]
import ../core/reconcile
import ./stable_ids

proc forEachKeyed*[T, R, N](
    renderer: R;
    parent: N;
    each: proc(): seq[T];
    body: proc(item: proc(): T, index: proc(): int): N) =
  ## Keyed list rendering using item identity (== comparison) for keys.
  ## Watches `each()` and reconciles the child nodes when the list changes.
  ## `body` renders a single item; receives accessor for item and index.

  var currentNodes: NativeSeq[N] = newNativeSeq[N]()
  var currentItems: seq[T] = @[]
  var itemSignals: seq[Signal[T]] = @[]
  var indexSignals: seq[Signal[int]] = @[]
  var itemDisposers: seq[proc()] = @[]
  let listOwner = getOwner()
  when stableIdsEnabled:
    let listStableScope = captureStableScope()

  # Row lifetimes follow reconciliation, not the tracking effect's reruns.
  # Each row has its own root; retained rows keep subscriptions and removed
  # rows release them. The list's owner releases all remaining rows on unmount.
  onCleanup proc() =
    for dispose in itemDisposers: dispose()
    itemDisposers.setLen(0)

  createRenderEffect proc() =
    let newItems = each()
    var oldItemMap = initTable[T, int]()
    for i, item in currentItems:
      oldItemMap[item] = i

    var newNodes: NativeSeq[N] = newNativeSeq[N]()
    var newItemSignals: seq[Signal[T]] = @[]
    var newIndexSignals: seq[Signal[int]] = @[]
    var newDisposers: seq[proc()] = @[]
    var retained = newSeq[bool](currentItems.len)
    var created: seq[proc()] = @[]
    var reconciled = false
    try:
      for i, item in newItems:
        if item in oldItemMap:
          let oldIdx = oldItemMap[item]
          newNodes.add(currentNodes[oldIdx])
          newItemSignals.add(itemSignals[oldIdx])
          newIndexSignals.add(indexSignals[oldIdx])
          newDisposers.add(itemDisposers[oldIdx])
          retained[oldIdx] = true
          `val=`(indexSignals[oldIdx], i)
          oldItemMap.del(item)
        else:
          var node: N
          var itemSig: Signal[T]
          var idxSig: Signal[int]
          var itemDispose: proc()
          runWithOwner(listOwner, proc() =
            createRoot proc(dispose: proc()) =
              itemDispose = dispose
              created.add(dispose)
              itemSig = createSignal(item)
              idxSig = createSignal(i)
              proc accessor[V](signal: Signal[V]): proc(): V =
                # Accessors escape the render callback; capture each signal
                # in its own invocation rather than a shared loop variable.
                result = proc(): V = signal.val
              when stableIdsEnabled:
                withStableScope(listStableScope):
                  withStableKey($item):
                    node = body(accessor(itemSig), accessor(idxSig))
              else:
                node = body(accessor(itemSig), accessor(idxSig))
          )
          newNodes.add(node)
          newItemSignals.add(itemSig)
          newIndexSignals.add(idxSig)
          newDisposers.add(itemDispose)

      reconcileArrays(renderer, parent, currentNodes, newNodes)
      reconciled = true
    finally:
      # A constructor can fail after earlier rows were built in this pass.
      # None of those new roots may escape without a reconciliation owner.
      if not reconciled:
        for dispose in created: dispose()
    for i, dispose in itemDisposers:
      if not retained[i]: dispose()
    currentItems = newItems
    itemSignals = newItemSignals
    indexSignals = newIndexSignals
    itemDisposers = newDisposers

proc indexEach*[T, R, N](
    renderer: R;
    parent: N;
    each: proc(): seq[T];
    body: proc(item: proc(): T, index: int): N) =
  ## Index-keyed list rendering. Uses position-based identity.
  ## Keeps stable node refs; updates signal value in-place when item at an
  ## index changes. Body-created effects are NOT owned by the tracking
  ## effect so they survive list updates.

  var currentNodes: NativeSeq[N] = newNativeSeq[N]()
  var itemSignals: seq[Signal[T]] = @[]
  let savedOwner = getOwner()
  when stableIdsEnabled:
    let listStableScope = captureStableScope()

  createRenderEffect proc() =
    let newItems = each()
    let oldLen = currentNodes.len
    let newLen = newItems.len

    if newLen > oldLen:
      # Add new nodes -- create body in the parent owner scope so
      # its effects survive re-runs of this tracking effect
      for i in oldLen ..< newLen:
        let itemSig = createSignal(newItems[i])
        let idx = i
        # Use a proc to force separate closure capture per iteration
        proc makeAccessor(sig: Signal[T]): proc(): T =
          result = proc(): T = sig.val
        var node: N
        runWithOwner(savedOwner, proc() =
          when stableIdsEnabled:
            withStableScope(listStableScope):
              withStableKey($idx):
                node = body(makeAccessor(itemSig), idx)
          else:
            node = body(makeAccessor(itemSig), idx)
        )
        itemSignals.add(itemSig)
        currentNodes.add(node)
        renderer.appendChild(parent, node)

    if newLen < oldLen:
      # Remove excess nodes
      for i in countdown(oldLen - 1, newLen):
        renderer.removeChild(parent, currentNodes[i])
      currentNodes.setLen(newLen)
      itemSignals.setLen(newLen)

    # Update existing item signals -- these fire the body effects
    let updateLen = min(oldLen, newLen)
    for i in 0 ..< updateLen:
      itemSignals[i].val = newItems[i]

proc show*[R, N](
    renderer: R;
    parent: N;
    condition: proc(): bool;
    body: proc(): N;
    fallback: proc(): N = nil) =
  ## Conditional rendering. Renders `body` when condition is true,
  ## `fallback` (if provided) when false.

  when stableIdsEnabled:
    let renderStableScope = captureStableScope()
  var currentNode: N
  var hasNode = false
  var currentState = false
  var disposeBranch: proc()
  let branchOwner = getOwner()
  # The condition can rerun without changing branches. Its computation must
  # not own the retained branch's effects: rerunning a computation disposes
  # its children before the unchanged-state guard runs. Give the branch its
  # own root and release it only on replacement or when Show is unmounted.
  onCleanup proc() =
    if not disposeBranch.isNil:
      disposeBranch()
      disposeBranch = nil

  createRenderEffect proc() =
    let newState = condition()
    if newState == currentState and hasNode:
      return

    # Remove current node if any
    if hasNode:
      disposeBranch()
      disposeBranch = nil
      renderer.removeChild(parent, currentNode)
      hasNode = false

    currentState = newState

    let renderBranch = if newState: body else: fallback
    if not renderBranch.isNil:
      try:
        runWithOwner(branchOwner, proc() =
          createRoot proc(dispose: proc()) =
            disposeBranch = dispose
            when stableIdsEnabled:
              withStableScope(renderStableScope): currentNode = renderBranch()
            else:
              currentNode = renderBranch()
        )
      except:
        if not disposeBranch.isNil:
          disposeBranch()
          disposeBranch = nil
        raise
      hasNode = true
      renderer.appendChild(parent, currentNode)

proc errorBoundary*[R, N](
    renderer: R;
    parent: N;
    body: proc(): N;
    fallback: proc(err: ref CatchableError): N) =
  ## Error boundary. Renders `body`; if it throws, renders `fallback` with
  ## the caught error instead.

  var node: N
  try:
    node = body()
  except CatchableError as e:
    node = fallback(e)

  renderer.appendChild(parent, node)
