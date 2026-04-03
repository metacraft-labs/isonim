## isonim/core/reconcile.nim
##
## Generic array reconciliation algorithm for efficient list diffing.
## Minimizes DOM mutations when reactive arrays change.
## Works with any renderer/node type that implements the RendererBackend concept.
##
## Port of dom-expressions reconcileArrays algorithm.

import platform

proc reconcileArrays*[R, N](
    renderer: R;
    parent: N;
    currentNodes: var NativeSeq[N];
    newNodes: NativeSeq[N]) =
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
    currentNodes = newNativeSeq[N]()
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

  # LIS-based reconciliation for the remaining middle range.
  # Build a map from old node identity to old index
  var oldMap = newHashMap[N, int]()
  for i in cStart .. cEnd:
    oldMap[currentNodes[i]] = i

  # For each new node, look up its old index (or -1 if new)
  let rangeLen = nEnd - nStart + 1
  var
    newToOld = newSeq[int](rangeLen)
    usedOld = newHashSet[int]()

  for i in 0 ..< rangeLen:
    let nNode = newNodes[nStart + i]
    if nNode in oldMap:
      newToOld[i] = oldMap[nNode]
      usedOld.incl(oldMap[nNode])
    else:
      newToOld[i] = -1

  # Remove old nodes not present in new list
  for i in cStart .. cEnd:
    if i notin usedOld:
      renderer.removeChild(parent, currentNodes[i])

  # Compute LIS of newToOld (only entries != -1) using patience sorting O(n log n).
  # Returns indices into newToOld that form the longest increasing subsequence.
  var
    tails: seq[int] = @[]      # tails[i] = smallest ending value of IS of length i+1
    tailIdx: seq[int] = @[]    # index in newToOld of that tail value
    parentLis: seq[int] = newSeq[int](rangeLen)

  for i in 0 ..< rangeLen:
    parentLis[i] = -1

  for i in 0 ..< rangeLen:
    if newToOld[i] < 0: continue  # skip new nodes

    # Binary search for the leftmost tail >= newToOld[i]
    var lo = 0
    var hi = tails.len
    while lo < hi:
      let mid = (lo + hi) div 2
      if tails[mid] < newToOld[i]:
        lo = mid + 1
      else:
        hi = mid

    if lo == tails.len:
      tails.add(newToOld[i])
      tailIdx.add(i)
    else:
      tails[lo] = newToOld[i]
      tailIdx[lo] = i

    parentLis[i] = if lo > 0: tailIdx[lo - 1] else: -1

  # Reconstruct LIS indices into a set for O(1) lookup
  var lisSet = newHashSet[int]()
  if tailIdx.len > 0:
    var idx = tailIdx[^1]
    while idx >= 0:
      lisSet.incl(idx)
      idx = parentLis[idx]

  # Work backwards, inserting/moving only non-LIS nodes
  let refNode = if nEnd + 1 < nLen: newNodes[nEnd + 1] else: nil
  var nextRef = refNode
  for i in countdown(rangeLen - 1, 0):
    let nNode = newNodes[nStart + i]
    if newToOld[i] == -1:
      # New node - insert it
      if nextRef != nil:
        renderer.insertBefore(parent, nNode, nextRef)
      else:
        renderer.appendChild(parent, nNode)
    elif i notin lisSet:
      # Existing node not in LIS - needs to move
      renderer.removeChild(parent, nNode)
      if nextRef != nil:
        renderer.insertBefore(parent, nNode, nextRef)
      else:
        renderer.appendChild(parent, nNode)
    # else: in LIS, already in correct relative position - skip
    nextRef = nNode

  currentNodes = newNodes
