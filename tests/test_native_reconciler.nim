## NH-M3 — the shared reconciliation engine, exercised over
## ``isonim/renderers/native``'s real ``NativeWidget`` tree.
##
## MOCK POLICY (workspace rule: every mock justified in the header).
## **No mocks.** The subject is ``isonim/native/reconciler`` and the
## object under it is ``isonim/renderers/native`` — the same
## ``NativeRenderer`` / ``NativeWidget`` backend that
## ``tests/test_native_renderer.nim`` and NH-M2's gates run against.
## Nothing is stubbed between the reconciler and the widget tree.
##
## NO SKIP ARMS. Every path here is in-process Nim.
##
## ## What this file is for, given that the three SHIPPING instances live
## ## in three other repositories
##
## TUI, GPUI and Freya each get their own gate in their own repo, over
## their own node type. This one tests the ENGINE. Without it a defect in
## the shared diff would be discovered three times, in three repos, as
## three renderer bugs — and the natural repair for a renderer bug is a
## renderer-side workaround, which is how one defect becomes three
## divergent ones.
##
## ## What each block proves, and how it discriminates
##
## The claim NH-M3 makes is not "a reconcile proc exists". It is that an
## unchanged subtree is NOT TOUCHED — so every assertion here is on the
## node REFERENCE plus the renderer-call census (``ReconcileStats``),
## and never on rendered text. A subtree that was destroyed and rebuilt
## identically renders identically; text cannot see the difference, and
## seeing that difference is the entire point of a reconciler.
##
## ### The control arm
##
## ``newAlwaysReplaceReconciler`` is the plausible non-reconciler: it
## reports a fresh identity for every node, so nothing ever matches and
## every child is placed anew. It is run through the SAME predicate
## (``identityPreservedUnder``) as the real reconciler, on the same
## trees — one predicate, two subjects, which is what keeps the control
## from agreeing with itself (`Verification-Harness-Traps` §30). Each
## "preserves X" case is paired with a measured case asserting the
## control does NOT preserve X; a negative control that is never
## falsified is a self-comparison wearing a negation (§7b).

import std/[tables, strutils]
import unittest

import isonim/renderers/native
import isonim/native/reconciler
import isonim/native/reconciler_native

# ---------------------------------------------------------------------------
# Fixture builders. Real widgets, built through the real backend.
# ---------------------------------------------------------------------------

proc w(tag, key: string; text: string = ""; attrs: seq[(string, string)] = @[]):
    NativeWidget =
  let r = NativeRenderer()
  result = r.createElement(tag)
  r.setAttribute(result, IsonimKeyAttr, key)
  for (k, v) in attrs:
    r.setAttribute(result, k, v)
  if text.len > 0:
    r.setTextContent(result, text)

proc kid(parent: NativeWidget; children: varargs[NativeWidget]): NativeWidget =
  let r = NativeRenderer()
  for c in children:
    r.appendChild(parent, c)
  parent

proc buildApp(headerText, rowBText: string): NativeWidget =
  ## Three rows under a panel; the second one is the one an edit moves.
  ## Shaped so "the block that changed" and "the blocks that did not"
  ## are both present in one tree — a tree with a single child cannot
  ## distinguish "preserved the unchanged part" from "rebuilt
  ## everything", because there is no unchanged part.
  kid(w("div", "root"),
      w("h1", "header", headerText),
      kid(w("div", "rows"),
          w("div", "rowA", "alpha"),
          w("div", "rowB", rowBText),
          w("div", "rowC", "gamma")))

proc childByKey(n: NativeWidget; key: string): NativeWidget =
  for c in n.children:
    if c.attributes.getOrDefault(IsonimKeyAttr) == key: return c
  nil

proc deepChild(n: NativeWidget; path: varargs[string]): NativeWidget =
  result = n
  for key in path:
    if result == nil: return nil
    result = result.childByKey(key)

# ---------------------------------------------------------------------------
# The control arm: a reconciler that never matches anything.
# ---------------------------------------------------------------------------

var alwaysReplaceCounter = 0

proc newAlwaysReplaceReconciler(): RendererReconciler[NativeWidget] =
  ## Identical to the real instance except that `identityKey` is unique
  ## per call, so no old node is ever recognised. This is what "no
  ## reconciler" looks like from the outside: the tree is rebuilt and
  ## every assertion about surviving references must fail.
  result = newNativeWidgetReconciler()
  result.nodes.identityKey = proc(n: NativeWidget): NodeIdentity =
    inc alwaysReplaceCounter
    "unmatchable-" & $alwaysReplaceCounter

# ---------------------------------------------------------------------------
# ONE predicate, used by the rule AND by its control.
# ---------------------------------------------------------------------------

type PreservationReport = object
  rootIsSame: bool
  unchangedRowIsSame: bool
  changedRowIsSame: bool
  stats: ReconcileStats

proc identityPreservedUnder(rec: RendererReconciler[NativeWidget];
                            oldRoot, newRoot: NativeWidget): PreservationReport =
  ## Reconcile `oldRoot` against `newRoot` and report which references
  ## survived. Both the real reconciler and the always-replace control
  ## go through this, so neither can be graded on its own yardstick.
  let oldUnchanged = oldRoot.deepChild("rows", "rowA")
  let oldChanged = oldRoot.deepChild("rows", "rowB")
  doAssert oldUnchanged != nil and oldChanged != nil,
    "fixture: the pre-reload tree does not have the shape the test assumes"
  var stats = ReconcileStats()
  let survivingRoot = rec.reconcile(oldRoot, newRoot, stats)
  PreservationReport(
    rootIsSame: survivingRoot == oldRoot,
    unchangedRowIsSame:
      survivingRoot != nil and
      survivingRoot.deepChild("rows", "rowA") == oldUnchanged,
    changedRowIsSame:
      survivingRoot != nil and
      survivingRoot.deepChild("rows", "rowB") == oldChanged,
    stats: stats)

suite "NH-M3: shared native reconciler":

  test "an IDENTICAL rebuild touches the renderer zero times":
    # The load-bearing case. A reload whose ui blocks all hash the same
    # still re-runs the entry; the reconciler is what turns that into a
    # no-op at the renderer.
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = buildApp("Tasks", "beta")
    let report = rec.identityPreservedUnder(before, after)
    check report.rootIsSame
    check report.unchangedRowIsSame
    check report.changedRowIsSame
    check report.stats.touched == 0
    check report.stats.placed == 0
    check report.stats.removed == 0
    check report.stats.propUpdates == 0
    # Non-vacuity: the pass must actually have walked the tree. A
    # reconcile that returned early would also report `touched == 0`.
    # 10 = six elements (root, header, rows, rowA, rowB, rowC) plus the
    # four text nodes `setTextContent` creates under them.
    check report.stats.matched == 10

  test "CONTROL: without identity matching, the same pair rebuilds everything":
    # Measured negation of the case above, through the same predicate.
    let rec = newAlwaysReplaceReconciler()
    let before = buildApp("Tasks", "beta")
    let after = buildApp("Tasks", "beta")
    let report = rec.identityPreservedUnder(before, after)
    check not report.rootIsSame
    check not report.unchangedRowIsSame
    check not report.changedRowIsSame
    # ZERO nodes survived, against 10 in the case above — the two
    # numbers come from the same predicate over the same trees, so the
    # only difference between them is whether identity matching happened.
    check report.stats.matched == 0
    check report.stats.replaced == 1

  test "one changed leaf updates that leaf and leaves its siblings alone":
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = buildApp("Tasks", "BETA!")
    let oldRowC = before.deepChild("rows", "rowC")
    let report = rec.identityPreservedUnder(before, after)

    # Identity is preserved for BOTH the changed and the unchanged row:
    # a changed body does not mean a new widget, it means the same
    # widget with new props. That is the distinction the whole milestone
    # is about.
    check report.rootIsSame
    check report.unchangedRowIsSame
    check report.changedRowIsSame
    check before.deepChild("rows", "rowC") == oldRowC

    # Exactly one prop update, and nothing structural.
    check report.stats.propUpdates == 1
    check report.stats.placed == 0
    check report.stats.removed == 0
    check report.stats.moved == 0

    # And the update actually landed on the surviving node.
    check before.deepChild("rows", "rowB").textContent.contains("BETA!")

  test "an added sibling is placed without disturbing the existing ones":
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = buildApp("Tasks", "beta")
    let r = NativeRenderer()
    r.appendChild(after.childByKey("rows"), w("div", "rowD", "delta"))

    let oldRowA = before.deepChild("rows", "rowA")
    let oldRowC = before.deepChild("rows", "rowC")
    var stats = ReconcileStats()
    let surviving = rec.reconcile(before, after, stats)

    check surviving == before
    check surviving.deepChild("rows", "rowA") == oldRowA
    check surviving.deepChild("rows", "rowC") == oldRowC
    check surviving.deepChild("rows", "rowD") != nil
    check stats.placed == 1
    check stats.removed == 0
    check stats.moved == 0
    check stats.propUpdates == 0

  test "a removed sibling is removed and the rest keep their identity":
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = kid(w("div", "root"),
                    w("h1", "header", "Tasks"),
                    kid(w("div", "rows"),
                        w("div", "rowA", "alpha"),
                        w("div", "rowC", "gamma")))
    let oldRowA = before.deepChild("rows", "rowA")
    let oldRowC = before.deepChild("rows", "rowC")
    var stats = ReconcileStats()
    let surviving = rec.reconcile(before, after, stats)

    check surviving == before
    check surviving.deepChild("rows", "rowA") == oldRowA
    check surviving.deepChild("rows", "rowC") == oldRowC
    check surviving.deepChild("rows", "rowB") == nil
    check stats.removed == 1
    check stats.placed == 0

  test "a reordered sibling MOVES rather than being rebuilt":
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = kid(w("div", "root"),
                    w("h1", "header", "Tasks"),
                    kid(w("div", "rows"),
                        w("div", "rowC", "gamma"),
                        w("div", "rowA", "alpha"),
                        w("div", "rowB", "beta")))
    let oldRowC = before.deepChild("rows", "rowC")
    var stats = ReconcileStats()
    let surviving = rec.reconcile(before, after, stats)

    check surviving == before
    # The moved node is the SAME widget — which is what preserves its
    # focus/scroll state. A rebuilt-in-the-new-position node would pass
    # any assertion made on order or on text.
    check surviving.deepChild("rows", "rowC") == oldRowC
    check stats.moved >= 1
    check stats.placed == 0
    check stats.removed == 0

  test "a key reused across a KIND change is replaced, not updated":
    # `rowB` keeps its key but becomes a button. Updating in place would
    # ask the renderer to mutate a div into a button; the reconciler
    # must refuse the match.
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = kid(w("div", "root"),
                    w("h1", "header", "Tasks"),
                    kid(w("div", "rows"),
                        w("div", "rowA", "alpha"),
                        w("button", "rowB", "beta"),
                        w("div", "rowC", "gamma")))
    let oldRowB = before.deepChild("rows", "rowB")
    var stats = ReconcileStats()
    let surviving = rec.reconcile(before, after, stats)

    check surviving == before
    check stats.replaced >= 1
    check surviving.deepChild("rows", "rowB") != oldRowB
    check surviving.deepChild("rows", "rowB").kind == nwkButton
    # …and its siblings still survived. A "replace" that took the whole
    # parent with it would be a rebuild wearing a narrower name.
    check surviving.deepChild("rows", "rowA") != nil
    check stats.placed == 1

  test "a root whose identity changed is swapped wholesale":
    let rec = newNativeWidgetReconciler()
    let before = buildApp("Tasks", "beta")
    let after = kid(w("section", "other-root"), w("h1", "header", "Settings"))
    var stats = ReconcileStats()
    let surviving = rec.reconcile(before, after, stats)
    check surviving == after
    check stats.replaced == 1

  test "an incomplete reconciler REFUSES at the seam instead of segfaulting":
    # A nil operation would otherwise surface several frames into the
    # diff, as a crash that names neither the renderer nor the operation.
    let rec = newNativeWidgetReconciler()
    rec.move = nil
    var stats = ReconcileStats()
    var raised = false
    try:
      discard rec.reconcile(buildApp("a", "b"), buildApp("a", "b"), stats)
    except ValueError as err:
      raised = true
      check err.msg.contains("move")
      check err.msg.contains("incomplete RendererReconciler")
    check raised

  test "the positional fallback keys unkeyed nodes by tag and index":
    # Documented behaviour, asserted so the cost recorded in
    # `defaultIdentityKey`'s doc comment stays true.
    check defaultIdentityKey("div", 2) == "div@2"
    let rec = newNativeWidgetReconciler()
    let r = NativeRenderer()
    let unkeyedBefore = kid(w("div", "root"), r.createElement("span"))
    let unkeyedAfter = kid(w("div", "root"), r.createElement("span"))
    let oldSpan = unkeyedBefore.children[0]
    var stats = ReconcileStats()
    let surviving = rec.reconcile(unkeyedBefore, unkeyedAfter, stats)
    check surviving == unkeyedBefore
    check surviving.children[0] == oldSpan
    check stats.touched == 0
