## isonim/native/reconciler.nim
##
## The shared reconciliation engine for IsoNim's NATIVE renderers — the
## thing that gives "unchanged ui block → unchanged native subtree" an
## operational meaning instead of a hopeful one.
##
## Specs:
## - ``isonim-specs/Hot-Module-Reload-Native.md``
##   § "Per-renderer reconciliation contract" — the normative shape of
##   ``RendererReconciler[T]``.
## - ``…/Hot-Module-Reload-Native.milestones.org`` § NH-M3.
##
## ## What a reconciler is for, stated precisely
##
## After a hot swap, a changed ui block's memo invalidates and its body
## produces a NEW subtree of renderer nodes. Handing that subtree to the
## renderer wholesale is correct and awful: every widget under the mount
## is destroyed and rebuilt, so focus, scroll offset, selection, caret
## position and in-flight animation all die — including inside blocks
## that did not change. The browser gets identity preservation for free
## because the DOM is a persistent tree the framework mutates in place;
## a native renderer's build proc returns a fresh graph every time, so
## somebody has to do the matching. That is this module.
##
## ## The contract, and the one place it deviates from the design doc
##
## The design doc writes the read side as a Nim ``concept``:
##
## ```nim
## RendererTreeNode* = concept
##   proc identityKey(n: T): NodeIdentity
##   proc kind(n: T): NodeKind
##   proc children(n: T): seq[T]
##   proc properties(n: T): Table[string, string]
## ```
##
## **It is a record of procs here instead** (``RendererTreeNodeOps[T]``),
## and the four write operations keep the doc's names and meanings
## verbatim in ``RendererReconciler[T]``. Two reasons, both load-bearing
## rather than stylistic:
##
## 1. ``concept`` is still experimental in Nim 2.2 and its overload
##    resolution inside a generic is not something a cross-repo contract
##    should depend on. ``isonim/renderers/native`` already made the same
##    call for ``RendererBackend`` — see its ``checkRendererBackend``
##    note about "every other renderer fails to instantiate".
## 2. A concept binds the operations to the node TYPE. Two renderers
##    whose nodes are the same type (``GpuiElement`` and
##    ``FreyaElement`` are both ``pointer``) could then not have
##    different reconcilers, and a ``pointer``-typed node cannot carry
##    the identity anywhere except through renderer-specific calls. A
##    proc record binds them to the INSTANCE, which is what the two
##    ``pointer`` renderers need.
##
## The doc's ``move``'s parameters are spelled ``fromIndex`` /
## ``toIndex``: ``from`` is a reserved word in Nim and the doc's
## ``proc move(parent, child: T; from, to: int)`` does not parse.
##
## ## The algorithm
##
## One keyed pass per child list, which is the standard keyed-children
## diff and is deliberately not cleverer than that:
##
## - Two nodes are THE SAME NODE when their ``identityKey`` AND their
##   ``kind`` are equal. Key alone is not enough: a key reused across a
##   type change (a ``text`` slot that became a ``button``) must be
##   replaced, not updated, or the renderer is asked to mutate a widget
##   into one it is not.
## - Matched → the OLD node survives. ``updateProps`` is called with
##   (old props, new props) — and only when they differ, so an unchanged
##   subtree issues no renderer call at all. Then recurse.
## - Unmatched new → ``placeAt``.
## - Unmatched old → ``remove``.
## - Matched but relocated → ``move``.
##
## ``ReconcileStats`` counts each operation. The counters are not
## diagnostics; they are the only way a test can assert "nothing was
## mutated", which is the actual claim. Asserting on rendered output
## instead would pass for a subtree that was destroyed and rebuilt
## identically — exactly the failure a reconciler exists to prevent.
##
## ## Identity
##
## ``identityKey`` is the load-bearing operation and the renderer owns
## it. The design doc's recommendation is the position-based key the ui
## block macro produces under ``-d:isonimHmr`` — the same
## ``(symBodyHash, callsite-index)`` pair the web reconciler uses. The
## per-renderer instances in the renderer repos read it from a
## well-known attribute and fall back to ``tag@index`` when the author
## has not set one; see ``defaultIdentityKey`` below for why the
## fallback is positional and what it costs.

when defined(js):
  {.error: "isonim/native/reconciler is for native (nim c) targets only. " &
      "The web target reconciles through the browser DOM, which is a " &
      "persistent tree — there is nothing for this module to do there.".}

import std/[tables, strutils]

type
  NodeIdentity* = string
    ## Stable across reloads when the two nodes are "the same logical
    ## node". Opaque to this module.

  NodeKind* = string
    ## Element class. Drives the replace-vs-update decision.

  RendererTreeNodeOps*[T] = ref object
    ## The design doc's ``RendererTreeNode`` concept, as a proc record.
    ## See the module header for why.
    identityKey*: proc(n: T): NodeIdentity {.closure.}
    kind*: proc(n: T): NodeKind {.closure.}
    children*: proc(n: T): seq[T] {.closure.}
    properties*: proc(n: T): Table[string, string] {.closure.}

  RendererReconciler*[T] = ref object
    ## The renderer's own tree-mutation API, named so IsoNim can call it.
    ## Every one of these already exists on every renderer; the contract
    ## does not ask for new capability, only for a handle on it.
    nodes*: RendererTreeNodeOps[T]
    placeAt*: proc(parent, child: T; index: int) {.closure.}
    move*: proc(parent, child: T; fromIndex, toIndex: int) {.closure.}
    remove*: proc(parent, child: T) {.closure.}
    updateProps*: proc(node: T; oldProps, newProps: Table[string, string]) {.closure.}

  ReconcileStats* = object
    ## Per-run operation census. See the module header: these are the
    ## assertion surface, not telemetry.
    placed*: int
    moved*: int
    removed*: int
    propUpdates*: int
    matched*: int      ## nodes that survived, i.e. identity preserved
    replaced*: int     ## nodes whose key matched but whose kind did not

proc `$`*(s: ReconcileStats): string =
  "ReconcileStats(matched: " & $s.matched & ", placed: " & $s.placed &
    ", moved: " & $s.moved & ", removed: " & $s.removed &
    ", propUpdates: " & $s.propUpdates & ", replaced: " & $s.replaced & ")"

proc touched*(s: ReconcileStats): int =
  ## Total renderer mutations. `touched == 0` is the operative form of
  ## "the native subtree was not touched".
  s.placed + s.moved + s.removed + s.propUpdates

proc defaultIdentityKey*(tag: string; index: int): NodeIdentity =
  ## The fallback a renderer instance uses when a node carries no
  ## explicit key.
  ##
  ## It is POSITIONAL, and the cost is worth stating rather than
  ## discovering: under it, inserting a child at the front of a list
  ## renames every sibling after it, so all of them are treated as new
  ## and the whole tail is rebuilt. That is correct (nothing is
  ## corrupted) and unhelpful (identity is lost where it could have been
  ## kept). It is the fallback precisely because the fix is on the
  ## author's side — give the nodes keys — and a silent non-positional
  ## guess (matching by tag alone, say) would preserve identity between
  ## nodes that are not the same node, which is worse than rebuilding.
  tag & "@" & $index

proc validate*[T](r: RendererReconciler[T]) =
  ## Fail loudly, at the seam, with the name of the missing operation.
  ## A nil proc field would otherwise surface as a segfault inside the
  ## diff, several frames from the renderer that forgot to supply it.
  if r == nil:
    raise newException(ValueError, "reconciler: nil RendererReconciler")
  if r.nodes == nil:
    raise newException(ValueError,
      "reconciler: RendererReconciler.nodes is nil — the read side of " &
      "the contract (identityKey/kind/children/properties) is missing.")
  var missing: seq[string] = @[]
  if r.nodes.identityKey == nil: missing.add("nodes.identityKey")
  if r.nodes.kind == nil: missing.add("nodes.kind")
  if r.nodes.children == nil: missing.add("nodes.children")
  if r.nodes.properties == nil: missing.add("nodes.properties")
  if r.placeAt == nil: missing.add("placeAt")
  if r.move == nil: missing.add("move")
  if r.remove == nil: missing.add("remove")
  if r.updateProps == nil: missing.add("updateProps")
  if missing.len > 0:
    raise newException(ValueError,
      "reconciler: incomplete RendererReconciler — missing " &
      missing.join(", ") & ". Every operation is required; a reconciler " &
      "with a hole in it preserves identity right up to the node that " &
      "needs the missing call and then does something arbitrary.")

proc propsDiffer(a, b: Table[string, string]): bool =
  if a.len != b.len: return true
  for k, v in a:
    if not b.hasKey(k) or b[k] != v: return true
  false

proc reconcileNode*[T](r: RendererReconciler[T]; oldNode, newNode: T;
                       stats: var ReconcileStats): T

proc reconcileChildren*[T](r: RendererReconciler[T]; parent: T;
                           oldChildren, newChildren: seq[T];
                           stats: var ReconcileStats): seq[T] =
  ## Keyed diff of one child list. Returns the surviving list, in the
  ## new order — surviving OLD nodes where identity matched, new nodes
  ## where it did not.
  var oldIndexByKey = initTable[NodeIdentity, int]()
  for i, child in oldChildren:
    # First occurrence wins. Duplicate keys within one parent are an
    # author error; taking the first keeps the pass deterministic
    # instead of letting the later duplicate silently claim the match.
    let k = r.nodes.identityKey(child)
    if not oldIndexByKey.hasKey(k):
      oldIndexByKey[k] = i

  var claimed = newSeq[bool](oldChildren.len)
  result = newSeq[T](newChildren.len)

  for newIdx, newChild in newChildren:
    let key = r.nodes.identityKey(newChild)
    var matchedIdx = -1
    if oldIndexByKey.hasKey(key):
      let candidate = oldIndexByKey[key]
      if not claimed[candidate] and
         r.nodes.kind(oldChildren[candidate]) == r.nodes.kind(newChild):
        matchedIdx = candidate
      elif not claimed[candidate]:
        # Key matched, kind did not: the slot changed shape. Replace
        # rather than update — see the module header.
        inc stats.replaced

    if matchedIdx >= 0:
      claimed[matchedIdx] = true
      let survivor = oldChildren[matchedIdx]
      inc stats.matched
      if matchedIdx != newIdx:
        r.move(parent, survivor, matchedIdx, newIdx)
        inc stats.moved
      result[newIdx] = r.reconcileNode(survivor, newChild, stats)
    else:
      r.placeAt(parent, newChild, newIdx)
      inc stats.placed
      result[newIdx] = newChild

  for i, oldChild in oldChildren:
    if not claimed[i]:
      r.remove(parent, oldChild)
      inc stats.removed

proc reconcileNode*[T](r: RendererReconciler[T]; oldNode, newNode: T;
                       stats: var ReconcileStats): T =
  ## Reconcile one matched pair: update the props that actually changed,
  ## then recurse. The OLD node is returned — that return value IS the
  ## identity-preservation guarantee, and the per-renderer tests assert
  ## on the reference it carries, never on rendered output.
  let oldProps = r.nodes.properties(oldNode)
  let newProps = r.nodes.properties(newNode)
  if propsDiffer(oldProps, newProps):
    r.updateProps(oldNode, oldProps, newProps)
    inc stats.propUpdates
  discard r.reconcileChildren(oldNode, r.nodes.children(oldNode),
                              r.nodes.children(newNode), stats)
  oldNode

proc reconcile*[T](r: RendererReconciler[T]; oldRoot, newRoot: T;
                   stats: var ReconcileStats): T =
  ## Reconcile two whole trees and return the surviving root.
  ##
  ## When the roots are the same logical node the OLD root comes back,
  ## with its identity — and every identity beneath it that matched —
  ## intact. When they are not, the new root is returned and the caller
  ## is expected to swap it in; there is nothing to preserve across a
  ## root whose type changed.
  r.validate()
  if r.nodes.identityKey(oldRoot) == r.nodes.identityKey(newRoot) and
     r.nodes.kind(oldRoot) == r.nodes.kind(newRoot):
    inc stats.matched
    return r.reconcileNode(oldRoot, newRoot, stats)
  inc stats.replaced
  newRoot

proc reconcile*[T](r: RendererReconciler[T]; oldRoot, newRoot: T): T =
  ## Stats-free overload for callers that only want the surviving tree.
  var stats = ReconcileStats()
  r.reconcile(oldRoot, newRoot, stats)
