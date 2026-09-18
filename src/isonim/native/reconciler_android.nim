## isonim/native/reconciler_android.nim
##
## NH-M3 **partial-Linux scaffold** for the Android View reconciler.
##
## ## Status — read this before using it
##
## **This is not a working reconciler and must not be reported as one.**
## NH-M3's Scope says "Android: partial-linux scaffold only; macOS host
## completes the View-side reconciler", and this file is exactly that:
## the wiring that can be written and reviewed without a device or an
## emulator, with every operation that needs one raising a refusal that
## names what it needs.
##
## The whole body is under ``when defined(android)``. On a host build
## this module compiles to nothing — deliberately, so a Linux CI lane
## cannot report a green result for a reconciler it never built.
##
## ## What the macOS host has to do, specifically
##
## 1. Replace ``AndroidView`` with the real JNI handle type from
##    ``isonim-android`` and delete the placeholder.
## 2. Implement the six ``androidNotImplemented`` sites. Each names its
##    View call: ``addView``, ``removeView``, the reorder pair,
##    ``getTag`` / ``setTag`` for the isonim key, and ``getChildAt`` /
##    ``getChildCount``.
## 3. **The Choreographer / draw-thread split is the hard part**, and it
##    is what makes Android different from Cocoa rather than merely
##    similar. Every one of these calls must happen on the UI thread;
##    a reconcile driven from the HMR after-reload callback arrives on
##    whatever thread the Reprobuild agent used, so the reconciler needs
##    a post-to-main-looper hop. Doing the tree mutation off-thread does
##    not throw reliably — it corrupts layout intermittently, which is
##    the worst possible failure mode for a gate to have to catch.
## 4. Write ``test_android_reconciler_preserves_identity`` asserting on
##    the View REFERENCE across a simulated reload. **Note the hazard
##    already recorded against this repo:** the two existing
##    ``test_android_launcher_*`` gates in ``isonim-examples`` require an
##    attached device and HANG without one (rc 124 on whichever arm runs
##    first, rc 1 on the next because an orphaned ``adb`` fork-server is
##    reused — so rc is not a fingerprint there). A new Android gate must
##    not join that family: give it a device probe that FAILS with a
##    remedy, and a bounded timeout.

import std/tables
import isonim/native/reconciler

export reconciler

when defined(android):
  type
    AndroidView* = ref object
      ## PLACEHOLDER. The macOS host replaces this with the real JNI
      ## handle from ``isonim-android``. A distinct type rather than an
      ## alias so a half-finished port fails to compile instead of
      ## type-checking against the wrong handle.
      placeholder: int

  proc androidNotImplemented(op, viewCall: string) {.noreturn.} =
    raise newException(Defect,
      "isonim Android reconciler: '" & op & "' is a NH-M3 partial-Linux " &
      "scaffold and has no implementation. The macOS host completes it " &
      "with android.view.ViewGroup's " & viewCall & " (see the header of " &
      "isonim/native/reconciler_android.nim), on the UI thread. This " &
      "raises rather than returning a default because a reconciler that " &
      "silently does nothing preserves identity perfectly and renders " &
      "the wrong tree.")

  proc newAndroidReconciler*(): RendererReconciler[AndroidView] =
    ## Assembles the contract with every operation present — so
    ## ``validate`` passes and the FAILURE IS THE CALL, not a nil field.
    RendererReconciler[AndroidView](
      nodes: RendererTreeNodeOps[AndroidView](
        identityKey: proc(n: AndroidView): NodeIdentity =
          androidNotImplemented("identityKey",
            "View.getTag(R.id.isonim_key)"),
        kind: proc(n: AndroidView): NodeKind =
          androidNotImplemented("kind", "the View subclass name"),
        children: proc(n: AndroidView): seq[AndroidView] =
          androidNotImplemented("children",
            "ViewGroup.getChildCount / getChildAt"),
        properties: proc(n: AndroidView): Table[string, string] =
          androidNotImplemented("properties",
            "the isonim attribute bundle carried on the View's tag")),
      placeAt: proc(parent, child: AndroidView; index: int) =
        androidNotImplemented("placeAt", "ViewGroup.addView(child, index)"),
      move: proc(parent, child: AndroidView; fromIndex, toIndex: int) =
        androidNotImplemented("move",
          "ViewGroup.removeView + addView(child, toIndex)"),
      remove: proc(parent, child: AndroidView) =
        androidNotImplemented("remove", "ViewGroup.removeView"),
      updateProps: proc(node: AndroidView;
                        oldProps, newProps: Table[string, string]) =
        androidNotImplemented("updateProps",
          "the property setters PLUS View.requestLayout / invalidate, " &
          "posted to the main Looper — see point 3 in this module's header"))
