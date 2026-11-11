## PSZ-M3 note 22: a renderer that falls back mid-connection shows
## "GPUI preview unavailable: renderer fell back" in the page preview, in
## place of the frame.
##
## The render-serve bridge closes the WebSocket with code 4001 when the
## launcher's frame source changes after its hello (a headless error on macOS,
## or a later change of source). This file checks the editor's state for that:
##
##   * `applyBridgeClose` moves `StreamingPreviewVM.rendererFellBack` only for
##     code 4001; a normal close, a protocol error and any other code leave it;
##   * a new `hello` clears it (a new launch is a new connection), and so does
##     selecting a backend;
##   * the page preview shows the note (`data-renderer-fell-back`) with the
##     text, and hides the synthetic-frame label, once the state is set.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only, as in the other native preview tests. They let the test read the
##   note's inline ``display`` and its text. Nothing is faked on the editor side.
## - The close is a plain (code, reason) pair, as the browser's WebSocket close
##   event delivers it. No socket runs here. The socket side is the browser test
##   tests/browser/e2e_preview_renderer_fell_back_live.mjs, which simulates the
##   close with ``routeWebSocket``.
## - The 4001 value is checked against the bridge's constant by
##   isonim-render-serve tests/test_bridge_renderer_fell_back.nim, which pins
##   `rendererFellBackCloseCode == 4001'u16`.
##
## Negative control: with the assignment in `applyBridgeClose` removed (in a
## scratch copy) the "a fallback close" case fails: the note never shows.

import std/[strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, streaming_preview]
import isonim/editor/views/page_preview

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and node.attributes.hasKey(name) and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc textOf(node: MockNode): string =
  if node.kind == mnkText:
    return node.text
  for child in node.children:
    result.add textOf(child)

proc renderedPage(vm: EditorVM): MockNode =
  let r = MockRenderer()
  renderPagePreview[MockRenderer, MockNode](r, vm)

proc pageStory(): StoryRef =
  StoryRef(group: "Destination", name: "Default", kind: skPage, index: 0)

const
  realHello =
    """{"type":"hello","protocolVersion":1,"backend":"gpui","capabilities":""" &
    """{"diffRegions":true,"encoder":"raw_rgba","transports":["f/rgba"],""" &
    """"frameSource":"real"},"initialSize":{"width":1440,"height":900}}"""
  rendererFellBackCode = 4001
    ## The bridge's close code (isonim-render-serve `rendererFellBackCloseCode`).

proc noteState(vm: EditorVM): tuple[shown: bool, text: string] =
  ## What the page preview shows for the fallback note.
  let page = renderedPage(vm)
  let note = findByAttr(page, "data-renderer-fell-back", "true")
  doAssert note != nil, "the page preview has no renderer-fell-back note"
  result = (shown: note.styles.getOrDefault("display", "") != "none",
            text: textOf(note).strip())

proc labelShown(vm: EditorVM): bool =
  let page = renderedPage(vm)
  let label = findByAttr(page, "data-preview-frame-source", "synthetic")
  doAssert label != nil, "the page preview has no frame-source label"
  label.styles.getOrDefault("display", "") == "block"

suite "PSZ-M3 note 22: a renderer fallback is shown, not a stale frame":

  test "only the renderer-fell-back close code moves the state":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      let sp = newStreamingPreviewVM(initial = pbGpui, available = @[pbGpui])
      vm.streamingPreview = sp
      check not sp.rendererFellBack.val
      # A normal close, a protocol error and a detach leave the preview alone.
      sp.applyBridgeClose(1000, "")
      check not sp.rendererFellBack.val
      sp.applyBridgeClose(1002, "V packet truncated (header)")
      check not sp.rendererFellBack.val
      # The reason alone, under another code, does not count.
      sp.applyBridgeClose(1011, "renderer fell back: frame source changed after hello")
      check not sp.rendererFellBack.val
      # The fallback close does.
      sp.applyBridgeClose(rendererFellBackCode,
        "renderer fell back: frame source changed after hello")
      check sp.rendererFellBack.val
      dispose()

  test "a fallback close shows the note and hides the frame label":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(realHello)
      let before = noteState(vm)
      check not before.shown
      check before.text == rendererFellBackText
      check not labelShown(vm)
      vm.streamingPreview.applyBridgeClose(rendererFellBackCode,
        "renderer fell back: frame source changed after hello")
      let after = noteState(vm)
      check after.shown
      check after.text == "GPUI preview unavailable: renderer fell back"
      check not labelShown(vm)
      dispose()

  test "a fallen-back synthetic frame hides its label as well":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(
        """{"type":"hello","protocolVersion":1,"backend":"gpui","capabilities":""" &
        """{"frameSource":"synthetic"},"initialSize":{"width":1440,"height":900}}""")
      check labelShown(vm)
      vm.streamingPreview.applyBridgeClose(rendererFellBackCode, "")
      check not labelShown(vm)
      check noteState(vm).shown
      dispose()

  test "a new hello clears the fallback, and so does a new backend selection":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      let sp = newStreamingPreviewVM(initial = pbGpui, available = @[pbGpui])
      vm.streamingPreview = sp
      sp.applyBridgeClose(rendererFellBackCode, "")
      check sp.rendererFellBack.val
      sp.dispatchMetaPacket(realHello)
      check not sp.rendererFellBack.val
      check not noteState(vm).shown
      sp.applyBridgeClose(rendererFellBackCode, "")
      check sp.rendererFellBack.val
      sp.selectBackend(pbGpui)
      check not sp.rendererFellBack.val
      dispose()

  test "a web page never shows the note":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbWeb
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.applyBridgeClose(rendererFellBackCode, "")
      check not noteState(vm).shown
      dispose()
