## PSZ-M3 note 20: the page preview labels a streamed frame that is the
## synthetic raster, and only that frame.
##
## The GPUI launcher on Linux streams the synthetic raster (the pinned GPUI has
## no Linux headless renderer). Its `hello` M-packet declares
## `capabilities.frameSource: "synthetic"`, and the editor shows a one-line note
## under the streamed canvas. This file checks the state that drives the note:
## the hello body -> `StreamingPreviewVM.frameSource` -> the label's display.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only, as in test_editor_preview_streamed_zoom.nim: they let the test read
##   the label's inline ``display`` and text. Nothing is faked on the editor side.
## - The hello bodies are literal JSON in the wire shape the render-serve
##   `buildHelloJson` writes (`{"type":"hello",...,"capabilities":{...}}`). No
##   launcher runs, so the wire shape is copied, not produced. The render-serve
##   test test_hello_frame_source.nim checks that the real encoder writes the
##   same field, and it is the authority for the wire shape.
## - ``EditorVM``, its signals and the page preview's render effects are real.
##
## Negative control: with the `frameSource` read removed from
## `helloFrameSource` (streaming_preview.nim) the synthetic case fails. See the
## PSZ-M3 note 20 record. The placement case (PSZ-M3 note 24) fails with the
## note 20 placement (``top: 100%``, under the stage).
import std/[json, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, streaming_preview]
import isonim/editor/views/page_preview

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and name in node.attributes and
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
  syntheticHello =
    """{"type":"hello","protocolVersion":1,"backend":"gpui","capabilities":""" &
    """{"diffRegions":true,"encoder":"raw_rgba","transports":["f/rgba"],""" &
    """"frameSource":"synthetic"},"initialSize":{"width":1440,"height":900}}"""
  unlabelledHello =
    """{"type":"hello","protocolVersion":1,"backend":"gpui","capabilities":""" &
    """{"diffRegions":true,"encoder":"raw_rgba","transports":["f/rgba"]},""" &
    """"initialSize":{"width":1440,"height":900}}"""

proc labelState(vm: EditorVM): tuple[shown: bool, text: string] =
  ## What the page preview shows for the synthetic-frame label.
  let page = renderedPage(vm)
  let label = findByAttr(page, "data-preview-frame-source", "synthetic")
  doAssert label != nil, "the page preview has no frame-source label"
  result = (shown: label.styles.getOrDefault("display", "") == "block",
            text: textOf(label).strip())

suite "PSZ-M3 note 20: synthetic frame label":

  test "helloFrameSource reads the declared frame source only from a hello":
    check helloFrameSource(syntheticHello) == "synthetic"
    check helloFrameSource(unlabelledHello) == ""
    check helloFrameSource("""{"type":"element-tree","root":{}}""") == ""
    check helloFrameSource("not json") == ""

  test "a synthetic GPUI frame shows the label":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(syntheticHello)
      check vm.streamingPreview.frameSource.val == "synthetic"
      let (shown, text) = labelState(vm)
      check shown
      check text == "Synthetic preview: GPUI draws boxes only on Linux"

  test "a GPUI frame whose launcher declares nothing does not show the label":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(unlabelledHello)
      check vm.streamingPreview.frameSource.val == ""
      check not labelState(vm).shown

  test "a web frame does not show the label, even after a synthetic hello":
    # The web preview has no bridge, so it never gets a hello. This case holds
    # the synthetic hello from a GPUI launch and switches the platform to Web:
    # the label must follow the frame being shown, not the last hello.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(syntheticHello)
      check labelState(vm).shown
      vm.platform.val = pbWeb
      check not labelState(vm).shown

  test "a later launcher without the declaration clears the label":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(syntheticHello)
      check labelState(vm).shown
      vm.streamingPreview.dispatchMetaPacket(unlabelledHello)
      check not labelState(vm).shown

  test "the synthetic badge sits at the stage's top-right corner, inside the frame":
    # PSZ-M3 note 24: the badge is a child of the zoom stage (the box the frame
    # fills), pinned to its top-right corner. It is not a child of the scaled
    # frame, so the zoom transform does not scale it, and it is not under the
    # stage any more (the old placement was ``top: 100%``).
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.streamingPreview = newStreamingPreviewVM(initial = pbGpui,
        available = @[pbGpui])
      vm.streamingPreview.dispatchMetaPacket(syntheticHello)
      let page = renderedPage(vm)
      let stage = findByAttr(page, "data-preview-zoom-stage", "true")
      check stage != nil
      let label = findByAttr(page, "data-preview-frame-source", "synthetic")
      check label != nil
      check label in stage.children
      check label.styles.getOrDefault("top", "") == "8px"
      check label.styles.getOrDefault("right", "") == "8px"
      check label.styles.getOrDefault("top", "") != "100%"
      dispose()
