## isonim/native/reconciler_cocoa.nim
##
## NH-M3 **partial-Linux scaffold** for the Cocoa/AppKit reconciler.
##
## ## Status — read this before using it
##
## **This is not a working reconciler and must not be reported as one.**
## NH-M3's Scope says "Cocoa: partial-linux scaffold only; macOS host
## completes the AppKit-side reconciler", and this file is exactly that
## and no more: the wiring that can be written and reviewed without an
## AppKit toolchain, with every operation that needs one raising a
## refusal that names what it needs.
##
## The whole body is under ``when defined(macosx)``. On Linux this
## module compiles to nothing, which is deliberate: it means a Linux CI
## lane cannot report a green result for a reconciler it never built,
## and it means a Linux developer importing it gets a compile error at
## the call site rather than a silently inert object.
##
## ## What the macOS host has to do, specifically
##
## 1. Replace ``CocoaView`` with the real handle type from
##    ``isonim-cocoa`` (``src/isonim_cocoa/…`` — the ``NSView``
##    wrapper), and delete the placeholder below.
## 2. Implement the six ``cocoaNotImplemented`` sites. Each names its
##    AppKit call in its message; they are ``addSubview:``,
##    ``removeFromSuperview``, the subview reordering pair, the
##    attribute read/write, and ``subviews``.
## 3. **Invalidation is the hard part and is why Cocoa is graded
##    "Hardest" in the design doc.** AppKit caches layout aggressively:
##    a reconciled subtree that changes a constraint-affecting property
##    without ``setNeedsLayout:`` / ``setNeedsUpdateConstraints`` shows
##    the OLD geometry with the NEW content. ``updateProps`` is the
##    place for that, and a gate for it has to assert on measured frame
##    geometry after the reconcile, not on the property value.
## 4. Write ``test_cocoa_reconciler_preserves_identity`` as the sibling
##    of the three Linux ones
##    (``isonim-tui/tests/test_tui_reconciler_identity.nim`` and its two
##    peers are the shape), asserting on the ``NSView`` REFERENCE across
##    a simulated reload — never on rendered pixels, which a
##    destroyed-and-rebuilt subtree reproduces exactly.

import std/tables
import isonim/native/reconciler

export reconciler

when defined(macosx):
  type
    CocoaView* = ref object
      ## PLACEHOLDER. The macOS host replaces this with the real
      ## ``NSView`` handle from ``isonim-cocoa``. It is a distinct type
      ## rather than an alias so that a half-finished port fails to
      ## compile instead of type-checking against the wrong handle.
      placeholder: int

  proc cocoaNotImplemented(op, appKitCall: string) {.noreturn.} =
    raise newException(Defect,
      "isonim Cocoa reconciler: '" & op & "' is a NH-M3 partial-Linux " &
      "scaffold and has no implementation. The macOS host completes it " &
      "with AppKit's " & appKitCall & " (see the header of " &
      "isonim/native/reconciler_cocoa.nim). This raises rather than " &
      "returning a default because a reconciler that silently does " &
      "nothing preserves identity perfectly and renders the wrong tree.")

  proc newCocoaReconciler*(): RendererReconciler[CocoaView] =
    ## Assembles the contract with every operation present — so
    ## ``validate`` passes and the FAILURE IS THE CALL, not a nil field.
    ## A scaffold that failed validation would be indistinguishable from
    ## a renderer that forgot to supply an operation, and those are
    ## different problems.
    RendererReconciler[CocoaView](
      nodes: RendererTreeNodeOps[CocoaView](
        identityKey: proc(n: CocoaView): NodeIdentity =
          cocoaNotImplemented("identityKey",
            "an associated-object lookup of the isonim key on the NSView"),
        kind: proc(n: CocoaView): NodeKind =
          cocoaNotImplemented("kind", "the NSView subclass name"),
        children: proc(n: CocoaView): seq[CocoaView] =
          cocoaNotImplemented("children", "-[NSView subviews]"),
        properties: proc(n: CocoaView): Table[string, string] =
          cocoaNotImplemented("properties",
            "the isonim attribute dictionary carried on the NSView")),
      placeAt: proc(parent, child: CocoaView; index: int) =
        cocoaNotImplemented("placeAt",
          "-[NSView addSubview:positioned:relativeTo:]"),
      move: proc(parent, child: CocoaView; fromIndex, toIndex: int) =
        cocoaNotImplemented("move",
          "-[NSView sortSubviewsUsingFunction:context:] or a " &
          "removeFromSuperview + addSubview:positioned: pair"),
      remove: proc(parent, child: CocoaView) =
        cocoaNotImplemented("remove", "-[NSView removeFromSuperview]"),
      updateProps: proc(node: CocoaView;
                        oldProps, newProps: Table[string, string]) =
        cocoaNotImplemented("updateProps",
          "the property setters PLUS -[NSView setNeedsLayout:] / " &
          "setNeedsUpdateConstraints — see point 3 in this module's header"))
