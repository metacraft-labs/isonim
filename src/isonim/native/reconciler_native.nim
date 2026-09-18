## isonim/native/reconciler_native.nim
##
## ``RendererReconciler`` instance for ``isonim/renderers/native``'s
## ``NativeWidget`` tree — the in-repo renderer NH-M2's gates already run
## against.
##
## It exists for two reasons beyond "one more renderer". First, it lets
## the shared engine in ``isonim/native/reconciler.nim`` be tested inside
## ``isonim`` with no sibling checkout, which matters because the three
## shipping instances live in three other repositories and a defect in
## the engine would otherwise be discovered three times. Second, it is
## the reference the per-renderer instances are written against: every
## decision below (where the key comes from, what "props" means, how
## ``move`` is expressed) recurs in all of them.
##
## ## The identity attribute
##
## Nodes carry their key in the ``data-isonim-key`` attribute. That name
## is the contract between an app author and the reconciler, and it is a
## plain attribute rather than anything clever because every renderer
## IsoNim targets already has attributes and none of them has a spare
## field. Nodes with no key fall back to ``defaultIdentityKey(tag,
## index)``; see that proc for what the positional fallback costs.

when defined(js):
  {.error: "isonim/native/reconciler_native is for native targets only.".}

import std/[tables, strutils]
import isonim/renderers/native
import isonim/native/reconciler

export reconciler

const IsonimKeyAttr* = "data-isonim-key"
  ## The attribute an author sets to give a node a stable identity. Kept
  ## as a public const so the per-renderer instances and their tests all
  ## name it once (`Verification-Harness-Traps` §30: one rule, one
  ## definition, everybody calling it).

proc nativeIdentityKey*(n: NativeWidget; index: int): NodeIdentity =
  if n == nil: return ""
  if n.attributes.hasKey(IsonimKeyAttr):
    return n.attributes[IsonimKeyAttr]
  defaultIdentityKey(n.tag, index)

proc indexInParent(n: NativeWidget): int =
  ## A node's own position under its parent, used only for the
  ## positional fallback. Returns 0 for a root or an orphan, which is
  ## right: a root has no siblings to be confused with.
  if n == nil or n.parent == nil: return 0
  for i, c in n.parent.children:
    if c == n: return i
  0

proc newNativeWidgetReconciler*(): RendererReconciler[NativeWidget] =
  ## The reconciler for ``NativeRenderer``'s tree.
  ##
  ## ``placeAt`` / ``remove`` go through the RendererBackend's own
  ## ``insertBefore`` / ``removeChild`` rather than touching
  ## ``children`` directly. That is not tidiness: the backend ops are
  ## what maintain ``parent`` back-references, and a reconciler that
  ## edited the seq in place would leave a tree whose upward links point
  ## at the wrong node — visible only later, from a hit-test.
  let r = NativeRenderer()
  RendererReconciler[NativeWidget](
    nodes: RendererTreeNodeOps[NativeWidget](
      identityKey: proc(n: NativeWidget): NodeIdentity =
        nativeIdentityKey(n, indexInParent(n)),
      kind: proc(n: NativeWidget): NodeKind =
        if n == nil: "" else: $n.kind & ":" & n.tag,
      children: proc(n: NativeWidget): seq[NativeWidget] =
        if n == nil: @[] else: n.children,
      properties: proc(n: NativeWidget): Table[string, string] =
        result = initTable[string, string]()
        if n == nil: return
        for k, v in n.attributes:
          # The identity key is excluded ON PURPOSE. It is not a
          # property of the node, it is the reason this node matched
          # the other one, and including it would make every
          # positionally-keyed node that moved also report a prop
          # change — a renderer call for something that did not change.
          if k != IsonimKeyAttr: result[k] = v
        for k, v in n.styles:
          result["style:" & k] = v
        if n.text.len > 0: result["text"] = n.text),
    placeAt: proc(parent, child: NativeWidget; index: int) =
      if parent == nil or child == nil: return
      if index >= parent.children.len:
        r.appendChild(parent, child)
      else:
        r.insertBefore(parent, child, parent.children[index]),
    move: proc(parent, child: NativeWidget; fromIndex, toIndex: int) =
      if parent == nil or child == nil: return
      r.removeChild(parent, child)
      if toIndex >= parent.children.len:
        r.appendChild(parent, child)
      else:
        r.insertBefore(parent, child, parent.children[toIndex]),
    remove: proc(parent, child: NativeWidget) =
      if parent == nil or child == nil: return
      r.removeChild(parent, child),
    updateProps: proc(node: NativeWidget;
                      oldProps, newProps: Table[string, string]) =
      if node == nil: return
      for k, v in newProps:
        if k == "text":
          if node.text != v: r.setTextContent(node, v)
        elif k.startsWith("style:"):
          r.setStyle(node, k["style:".len .. ^1], v)
        else:
          r.setAttribute(node, k, v)
      for k in oldProps.keys:
        if not newProps.hasKey(k):
          if k == "text":
            r.setTextContent(node, "")
          elif not k.startsWith("style:"):
            r.removeAttribute(node, k))
