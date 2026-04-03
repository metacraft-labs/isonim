## isonim/core/reconcile.nim
##
## Generic array reconciliation algorithm for efficient list diffing.
## Minimizes DOM mutations when reactive arrays change.
## Works with any renderer/node type that implements the RendererBackend concept.
##
## Port of dom-expressions reconcileArrays algorithm.

when defined(js):
  import js_collections
  template initNodeMap(N: typedesc): auto = newJsMap[N, int]()
  template initIndexSet(): auto = newJsSet[int]()
  template inclIndex(s: auto, val: int) = s.incl(val)
else:
  import std/tables
  template initNodeMap(N: typedesc): auto = initTable[N, int]()
  template initIndexSet(): auto = initTable[int, bool]()
  template inclIndex(s: auto, val: int) = s[val] = true

proc reconcileArrays*[R, N](
    renderer: R;
    parent: N;
    currentNodes: var seq[N];
    newNodes: seq[N]) =
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
  var oldMap = initNodeMap(N)
  for i in cStart .. cEnd:
    oldMap[currentNodes[i]] = i

  # For each new node, check if it exists in old
  var
    newIndices = newSeq[int](nEnd - nStart + 1) # maps new range index -> old index (-1 if new)
    usedOld = initIndexSet()

  for i in 0 ..< newIndices.len:
    let nNode = newNodes[nStart + i]
    if nNode in oldMap:
      newIndices[i] = oldMap[nNode]
      inclIndex(usedOld, oldMap[nNode])
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
      let curParent = renderer.parentNode(nNode)
      if curParent == parent:
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
