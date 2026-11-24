## isonim/dsl/components.nim
##
## Built-in control-flow components: For, Index, Show, ErrorBoundary.
## Generic over renderer and node types -- works with any RendererBackend.
##
## Port of SolidJS rendering control flow components.

import std/tables
import ../core/[signals, computation, owner, platform, graph]
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
  ## Error boundary. Renders `body`; if it throws, or a computation created
  ## under it fails -- in its first run or in any later re-run -- shows
  ## `fallback` with the error instead. The body's content stays alive while
  ## the fallback is shown, and comes back once every computation under it
  ## that failed has run again successfully (for example when the memo they
  ## read produces a new value) or has been disposed. A later failure shows
  ## a new fallback; the same error reported by several computations (the
  ## readers of one failing memo) shows it once. An error raised by
  ## `fallback` goes to the boundary's own owner (an outer boundary).
  ##
  ## When `body` itself raises there is no content to come back to: the
  ## fallback stays until the boundary is disposed.
  when stableIdsEnabled:
    let renderStableScope = captureStableScope()
  let boundaryOwner = getOwner()
  var shown: N
  var hasShown = false
  var content: N
  var hasContent = false
  var showingContent = false
  var rendering = true
  var firstFailure, shownFailure: ref CatchableError
  var failing: seq[ComputationBase]
    # The computations under the body whose last run failed.
  var disposeBody, disposeFallback: proc()

  proc display(node: N) =
    # Keep the boundary's place among its siblings.
    if hasShown:
      renderer.insertBefore(parent, node, shown)
      renderer.removeChild(parent, shown)
    else:
      renderer.appendChild(parent, node)
    shown = node
    hasShown = true

  proc releaseFallback() =
    if not disposeFallback.isNil:
      disposeFallback()
      disposeFallback = nil

  proc showFallback(err: ref CatchableError) =
    if not showingContent and err == shownFailure: return
    shownFailure = err
    releaseFallback()
    var node: N
    # Outside the body's root, so that a failure of the fallback itself goes
    # to the handlers above this boundary, not to this one.
    runWithOwner(boundaryOwner, proc() =
      createRoot proc(dispose: proc()) =
        disposeFallback = dispose
        when stableIdsEnabled:
          withStableScope(renderStableScope): node = fallback(err)
        else:
          node = fallback(err)
    )
    showingContent = false
    display(node)

  # Call, then clear (as `show` does). Not `let d = disposeBody;
  # disposeBody = nil; d()`: under ARC/ORC, Nim 2.2 infers that copy to be a
  # cursor (no reference of its own), so clearing the captured variable
  # frees the closure before the call, and disposal then runs on freed
  # memory.
  onCleanup proc() =
    releaseFallback()
    if not disposeBody.isNil:
      disposeBody()
      disposeBody = nil

  var bodyFailure: ref CatchableError
  try:
    createRoot proc(dispose: proc()) =
      disposeBody = dispose
      setErrorBox(getOwner(), ErrorBox(
        handler: proc(err: ref CatchableError; source: ComputationBase) =
          # A computation disposed while it was failing never recovers, so
          # it no longer counts; nor does `source` once it has recovered.
          var i = 0
          while i < failing.len:
            if failing[i].fn == nil or (err == nil and failing[i] == source):
              failing.del(i)
            else:
              inc i
          if err != nil:
            if source notin failing: failing.add source
            if rendering:
              # During the first render, the content is not shown yet.
              if firstFailure == nil: firstFailure = err
            else:
              showFallback(err)
          elif failing.len == 0 and not rendering and hasContent and
              not showingContent:
            releaseFallback()
            shownFailure = nil
            showingContent = true
            display(content)))
      content = body()
      hasContent = true
  except CatchableError as e:
    bodyFailure = e
  rendering = false
  if bodyFailure != nil:
    disposeBody()
    disposeBody = nil
    showFallback(bodyFailure)
  elif firstFailure != nil:
    let err = firstFailure
    firstFailure = nil
    showFallback(err)
  else:
    showingContent = true
    display(content)
