## isonim/dsl/components.nim
##
## Built-in control-flow components: For, Index, Show, Switch, Match, ErrorBoundary.
## These are reactive-aware flow control primitives used within the DSL.
##
## Port of SolidJS rendering control flow components.

import std/tables
import ../core/[signals, computation, owner]
import ../core/reconcile
import ../testing/mock_dom

proc forEachKeyed*[T](
    renderer: MockRenderer;
    parent: MockNode;
    each: proc(): seq[T];
    body: proc(item: proc(): T, index: proc(): int): MockNode) =
  ## Keyed list rendering using item identity (== comparison) for keys.
  ## Watches `each()` and reconciles the child nodes when the list changes.
  ## `body` renders a single item; receives accessor for item and index.

  var currentNodes: seq[MockNode] = @[]
  var currentItems: seq[T] = @[]
  var itemSignals: seq[Signal[T]] = @[]
  var indexSignals: seq[Signal[int]] = @[]

  createRenderEffect proc() =
    let newItems = each()

    # Build map from item value -> old index
    var oldItemMap = initTable[T, int]()
    for i, item in currentItems:
      oldItemMap[item] = i

    var newNodes: seq[MockNode] = @[]
    var newItemSignals: seq[Signal[T]] = @[]
    var newIndexSignals: seq[Signal[int]] = @[]

    for i, item in newItems:
      if item in oldItemMap:
        let oldIdx = oldItemMap[item]
        # Reuse existing node and update signals
        newNodes.add(currentNodes[oldIdx])
        newItemSignals.add(itemSignals[oldIdx])
        newIndexSignals.add(indexSignals[oldIdx])
        # Update index value (item is same by identity)
        indexSignals[oldIdx].val = i
        # Remove from map so duplicate items get new nodes
        oldItemMap.del(item)
      else:
        # Create new node
        var itemSig = createSignal(item)
        var idxSig = createSignal(i)
        let node = body(
          proc(): T = itemSig.val,
          proc(): int = idxSig.val
        )
        newNodes.add(node)
        newItemSignals.add(itemSig)
        newIndexSignals.add(idxSig)

    reconcileArrays(renderer, parent, currentNodes, newNodes)
    currentItems = newItems
    itemSignals = newItemSignals
    indexSignals = newIndexSignals

proc indexEach*[T](
    renderer: MockRenderer;
    parent: MockNode;
    each: proc(): seq[T];
    body: proc(item: proc(): T, index: int): MockNode) =
  ## Index-keyed list rendering. Uses position-based identity.
  ## Keeps stable node refs; updates signal value in-place when item at an
  ## index changes. Body-created effects are NOT owned by the tracking
  ## effect so they survive list updates.

  var currentNodes: seq[MockNode] = @[]
  var itemSignals: seq[Signal[T]] = @[]
  let savedOwner = getOwner()

  createRenderEffect proc() =
    let newItems = each()
    let oldLen = currentNodes.len
    let newLen = newItems.len

    if newLen > oldLen:
      # Add new nodes -- create body in the parent owner scope so
      # its effects survive re-runs of this tracking effect
      for i in oldLen ..< newLen:
        var itemSig = createSignal(newItems[i])
        let idx = i
        # Use a proc to force separate closure capture per iteration
        proc makeAccessor(sig: Signal[T]): proc(): T =
          result = proc(): T = sig.val
        var node: MockNode
        runWithOwner(savedOwner, proc() =
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

proc show*(
    renderer: MockRenderer;
    parent: MockNode;
    condition: proc(): bool;
    body: proc(): MockNode;
    fallback: proc(): MockNode = nil) =
  ## Conditional rendering. Renders `body` when condition is true,
  ## `fallback` (if provided) when false.

  var currentNode: MockNode = nil
  var currentState = false

  createRenderEffect proc() =
    let newState = condition()
    if newState == currentState and currentNode != nil:
      return

    # Remove current node if any
    if currentNode != nil:
      renderer.removeChild(parent, currentNode)
      currentNode = nil

    currentState = newState

    if newState:
      currentNode = body()
      renderer.appendChild(parent, currentNode)
    elif fallback != nil:
      currentNode = fallback()
      renderer.appendChild(parent, currentNode)

proc errorBoundary*(
    renderer: MockRenderer;
    parent: MockNode;
    body: proc(): MockNode;
    fallback: proc(err: ref CatchableError): MockNode) =
  ## Error boundary. Renders `body`; if it throws, renders `fallback` with
  ## the caught error instead.

  var node: MockNode
  try:
    node = body()
  except CatchableError as e:
    node = fallback(e)

  renderer.appendChild(parent, node)
