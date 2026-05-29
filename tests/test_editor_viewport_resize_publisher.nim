## VRS-M2 — Editor viewport-resize publisher tests.
##
## Headless coverage for the editor-side sender that fires an
## ``iekResize`` I packet whenever the user changes the viewport pill
## (or a freshly-attached launcher needs the current viewport).
## Browser-level wiring (``page_preview.nim`` /
## ``component_detail.nim`` / ``foundations_page.nim`` render effects
## + ``canvas_mount.nim``'s ``installStoryPublisher`` extension) is
## verified by the e2e Playwright test
## ``tests/browser/e2e_editor_viewport_resize_send_live.mjs``; this
## file pins the contract at the publish-path level:
##
##   1. ``encodeResizeBody`` produces the locked byte-stable JSON
##      body the launcher's ``decodeInputEvent`` consumes.
##   2. ``publishResize`` routes (width, height) through the
##      registered ``sendResizeFn`` closure on the
##      ``StreamingPreviewVM``'s publisher.
##   3. ``publishResize`` short-circuits on the Web backend (no
##      streaming launcher in that path) and on missing-publisher /
##      non-positive dimensions.
##   4. A ``createRenderEffect`` that reads
##      ``vm.viewport.val`` + ``vm.platform.val`` and calls
##      ``publishResize`` fires the right (w, h) pair on initial run,
##      on subsequent viewport changes, and does NOT fire when
##      ``platform == pbWeb``.
##
## VRS-M2's spec brief lists these three reactive-effect requirements
## (initial mount, viewport change, web short-circuit) explicitly;
## suites 4a–4c below pin one apiece.

import std/[unittest]

import isonim/core/[signals, computation, owner]
import isonim/editor/types
import isonim/editor/viewmodels
import isonim/editor/streaming_preview

suite "VRS-M2: encodeResizeBody":

  test "encodeResizeBody matches a hand-rolled reference":
    # Field order locked to ``type, width, height`` so the body is
    # byte-stable across JSON-ordering refactors. The launcher side
    # (``isonim-render-serve/.../event_dispatch.nim:163-169``) reads
    # width + height by name, but the editor-side test surface (the
    # mock launcher in the e2e test) compares the bytes verbatim.
    check encodeResizeBody(375, 667) ==
      """{"type":"resize","width":375,"height":667}"""
    check encodeResizeBody(1, 1) ==
      """{"type":"resize","width":1,"height":1}"""
    check encodeResizeBody(1920, 1080) ==
      """{"type":"resize","width":1920,"height":1080}"""

suite "VRS-M2: publishResize routes through the publisher":

  test "publishResize fires the registered sendResize closure (non-Web)":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbGpui  # non-Web → resize is meaningful
      var captured: seq[tuple[w, h: int]] = @[]
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          captured.add((w, h)))
      vm.publishResize(375, 667)
      vm.publishResize(1024, 768)
      check captured.len == 2
      check captured[0] == (375, 667)
      check captured[1] == (1024, 768)
      dispose()

  test "publishResize is a no-op for the Web backend":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      # Default selectedBackend is pbWeb.
      var captured = 0
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          inc captured)
      vm.publishResize(375, 667)
      check captured == 0
      # Switch to a non-Web backend → publish flows through.
      vm.selectedBackend.val = pbGpui
      vm.publishResize(375, 667)
      check captured == 1
      dispose()

  test "publishResize is a no-op without a publisher":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbGpui
      # No setStoryPublisher call → publisher is nil.
      vm.publishResize(375, 667)  # must not raise
      vm.clearStoryPublisher()
      vm.publishResize(375, 667)  # must not raise after clear either
      dispose()

  test "publishResize ignores non-positive dimensions":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbGpui
      var captured = 0
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          inc captured)
      vm.publishResize(0, 100)
      vm.publishResize(100, 0)
      vm.publishResize(-1, 100)
      check captured == 0
      vm.publishResize(100, 100)
      check captured == 1
      dispose()

  test "clearStoryPublisher silences subsequent publishResize calls":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbFreya
      var captured = 0
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          inc captured)
      vm.publishResize(100, 200)
      check captured == 1
      vm.clearStoryPublisher()
      vm.publishResize(300, 400)
      check captured == 1  # cleared → no-op
      dispose()

suite "VRS-M2: reactive viewport→publishResize wiring":

  # These tests mirror the contract page_preview.nim /
  # component_detail.nim / foundations_page.nim implement in their
  # createRenderEffect blocks. We don't depend on the renderer here —
  # the publisher closure is the seam — but we DO drive the same
  # signal subscription pattern (read viewport + platform inside the
  # effect, call publishResize) so the test asserts the trigger
  # shape, not just the publisher plumbing.

  test "initial mount fires publishResize with the current viewport":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbGpui
      let viewport = createSignal(makeBuiltinViewport(pvkPhone))
      var captured: seq[tuple[w, h: int]] = @[]
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          captured.add((w, h)))
      createRenderEffect proc() =
        let vp = viewport.val
        # Mirror the page_preview gate: short-circuit on Web.
        if vm.selectedBackend.val != pbWeb:
          vm.publishResize(previewViewportWidth(vp),
                           previewViewportHeight(vp))
      check captured.len == 1
      let phone = makeBuiltinViewport(pvkPhone)
      check captured[0] == (previewViewportWidth(phone),
                            previewViewportHeight(phone))
      dispose()

  test "subsequent viewport change fires publishResize again":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      vm.selectedBackend.val = pbFreya
      let viewport = createSignal(makeBuiltinViewport(pvkPhone))
      var captured: seq[tuple[w, h: int]] = @[]
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          captured.add((w, h)))
      createRenderEffect proc() =
        let vp = viewport.val
        if vm.selectedBackend.val != pbWeb:
          vm.publishResize(previewViewportWidth(vp),
                           previewViewportHeight(vp))
      check captured.len == 1
      # Change the viewport — the effect re-runs and re-publishes.
      viewport.val = makeBuiltinViewport(pvkTablet)
      check captured.len == 2
      let tablet = makeBuiltinViewport(pvkTablet)
      check captured[1] == (previewViewportWidth(tablet),
                            previewViewportHeight(tablet))
      # Third change.
      viewport.val = makeBuiltinViewport(pvkDesktop)
      check captured.len == 3
      let desktop = makeBuiltinViewport(pvkDesktop)
      check captured[2] == (previewViewportWidth(desktop),
                            previewViewportHeight(desktop))
      dispose()

  test "platform == pbWeb suppresses publishResize entirely":
    createRoot do (dispose: proc()):
      let vm = newStreamingPreviewVM()
      # selectedBackend stays at the default pbWeb.
      check vm.selectedBackend.val == pbWeb
      let viewport = createSignal(makeBuiltinViewport(pvkPhone))
      var captured = 0
      vm.setStoryPublisher(
        sendStory = proc(g, n, k, sid: string) = discard,
        sendMutation = proc(t, k, v: string; s: MutationScopeKind) = discard,
        sendResize = proc(w, h: int) =
          inc captured)
      createRenderEffect proc() =
        let vp = viewport.val
        # Short-circuit on Web — the platform check lives in the
        # view layer's render effect (page_preview.nim guards on
        # ``vm.platform.val != pbWeb``); ``publishResize`` itself
        # also short-circuits on web for defense in depth.
        if vm.selectedBackend.val != pbWeb:
          vm.publishResize(previewViewportWidth(vp),
                           previewViewportHeight(vp))
      check captured == 0
      # Even an explicit publish call is suppressed by the Web gate
      # inside publishResize.
      vm.publishResize(375, 667)
      check captured == 0
      # Flip to a non-Web backend → the render effect re-runs (it
      # observed selectedBackend via the gate read) and publishes
      # the current viewport; an additional explicit publishResize
      # then also flows.
      vm.selectedBackend.val = pbGpui
      check captured == 1  # render-effect re-run after backend flip
      vm.publishResize(375, 667)
      check captured == 2
      dispose()
