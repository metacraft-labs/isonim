## isonim/core/reconcile.nim
##
## Array reconciliation algorithm for efficient list diffing.
## Minimizes DOM mutations when reactive arrays change.
##
## Port of dom-expressions reconcileArrays algorithm.

import std/tables
import std/hashes
import ../testing/mock_dom

proc hash*(node: MockNode): Hash =
  ## Hash MockNode by its unique ID (works on both C and JS backends).
  result = hash(node.id)

proc reconcileArrays*(
    renderer: MockRenderer;
    parent: MockNode;
    currentNodes: var seq[MockNode];
    newNodes: seq[MockNode]) =
  ## Efficiently reconcile the current list of child nodes with a new list.
  ## Uses a bidirectional scan with map fallback for efficient node reordering.
  ## Modifies currentNodes in-place to match newNodes.

  let cLen = currentNodes.len
  let nLen = newNodes.len

  # Fast path: nothing to do
  if cLen == 0 and nLen == 0:
    return

  # Fast path: all new
  if cLen == 0:
    for node in newNodes:
      renderer.appendChild(parent, node)
    currentNodes = newNodes
    return

  # Fast path: clear all
  if nLen == 0:
    for i in countdown(cLen - 1, 0):
      renderer.removeChild(parent, currentNodes[i])
    currentNodes = @[]
    return

  # General case: bidirectional scan
  var
    cStart = 0
    cEnd = cLen - 1
    nStart = 0
    nEnd = nLen - 1

  # Prefix match
  while cStart <= cEnd and nStart <= nEnd and currentNodes[cStart] == newNodes[nStart]:
    inc cStart
    inc nStart

  # Suffix match
  while cStart <= cEnd and nStart <= nEnd and currentNodes[cEnd] == newNodes[nEnd]:
    dec cEnd
    dec nEnd

  # Simple cases after prefix/suffix matching
  if cStart > cEnd:
    # Only insertions remain
    let refNode = if nEnd + 1 < nLen: newNodes[nEnd + 1] else: nil
    for i in nStart .. nEnd:
      if refNode != nil:
        renderer.insertBefore(parent, newNodes[i], refNode)
      else:
        renderer.appendChild(parent, newNodes[i])
    currentNodes = newNodes
    return

  if nStart > nEnd:
    # Only removals remain
    for i in cStart .. cEnd:
      renderer.removeChild(parent, currentNodes[i])
    currentNodes = newNodes
    return

  # Map fallback for the remaining range
  # Build a map from old node identity to old index
  var oldMap = initTable[MockNode, int]()
  for i in cStart .. cEnd:
    oldMap[currentNodes[i]] = i

  # For each new node, check if it exists in old
  var
    newIndices = newSeq[int](nEnd - nStart + 1) # maps new range index -> old index (-1 if new)
    usedOld = initTable[int, bool]()

  for i in 0 ..< newIndices.len:
    let nNode = newNodes[nStart + i]
    if nNode in oldMap:
      newIndices[i] = oldMap[nNode]
      usedOld[oldMap[nNode]] = true
    else:
      newIndices[i] = -1

  # Remove old nodes not present in new list
  for i in cStart .. cEnd:
    if i notin usedOld:
      renderer.removeChild(parent, currentNodes[i])

  # Now insert/move nodes to match new order
  # Work backwards from the end of the range
  let refNode = if nEnd + 1 < nLen: newNodes[nEnd + 1] else: nil
  var nextRef = refNode
  for i in countdown(nEnd - nStart, 0):
    let nNode = newNodes[nStart + i]
    if newIndices[i] == -1:
      # New node - insert it
      if nextRef != nil:
        renderer.insertBefore(parent, nNode, nextRef)
      else:
        renderer.appendChild(parent, nNode)
    else:
      # Existing node - check if it needs to move
      # We need to ensure it's in the right position
      # Remove and reinsert to guarantee order
      # First check if it's already in the right place
      let curParent = renderer.parentNode(nNode)
      if curParent == parent:
        # Check if next sibling matches expected
        let ns = renderer.nextSibling(nNode)
        if ns != nextRef:
          # Need to move
          renderer.removeChild(parent, nNode)
          if nextRef != nil:
            renderer.insertBefore(parent, nNode, nextRef)
          else:
            renderer.appendChild(parent, nNode)
      else:
        if nextRef != nil:
          renderer.insertBefore(parent, nNode, nextRef)
        else:
          renderer.appendChild(parent, nNode)
    nextRef = nNode

  currentNodes = newNodes
