## PSZ-M1 (Preview-Sizing-And-Zoom): Fit, 100% and zoom steps on the web preview.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only. The rendered tree is inspected for the attributes and inline
##   styles the views set (``data-preview-zoom-stage``, ``transform``,
##   ``data-preview-zoom-level``, ``aria-pressed``). Nothing else is faked.
## - No layout engine runs. The mock does not measure, so the preview area is
##   supplied by the test through ``setPreviewArea``, which is the same entry
##   point the browser's ResizeObserver calls. Layout itself (the scrollbars
##   and the centring) is checked in the browser by
##   tests/browser/e2e_preview_zoom_live.mjs, not here.
## - ``EditorVM``, its signals, the zoom reducers and the click handlers are all
##   real: the tests click the rendered controls and read the VM back.
##
## The story URL assembly lives in browser.nim, which only compiles for the JS
## target, so ``test_preview_zoom_url_roundtrip`` checks the codec the URL uses
## (``previewZoomRouteParam`` / ``previewZoomFromRouteParam``) and the VM state
## that the route sync reads and writes. The browser e2e test checks the URL
## the editor actually writes.
import std/[strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, preview_zoom]
import isonim/editor/views/shell
import isonim/editor/views/page_preview

proc findByAttr(node: MockNode; name, value: string): MockNode =
  if node.kind == mnkElement and node.attributes.hasKey(name) and
      node.attributes[name] == value:
    return node
  for child in node.children:
    let found = findByAttr(child, name, value)
    if found != nil:
      return found

proc renderedPage(vm: EditorVM): MockNode =
  ## The page preview root, as the shell mounts it.
  let r = MockRenderer()
  renderPagePreview[MockRenderer, MockNode](r, vm)

proc pxValue(text: string): int =
  ## ``"1440px"`` -> 1440. Only used on values the views write as whole px.
  parseInt(text.replace("px", ""))

suite "Preview zoom (PSZ-M1) - pure model":
  test "test_preview_zoom_fit_never_exceeds_100":
    # The frame used in the plan is 1440x900. The Desktop preset is that size
    # (makeBuiltinViewport(pvkDesktop)); the Laptop preset is 1280x800 in code.
    let desktopW = 1440
    let desktopH = 900
    let area = PreviewArea(width: 1000, height: 700)
    # Width binds: 1000 / 1440 = 0.6944..., and 700 / 900 = 0.777... is larger.
    let laptopFit = fitScale(desktopW, desktopH, area)
    check abs(laptopFit - 1000.0 / 1440.0) < 1e-9
    check laptopFit * desktopW.float <= 1000.0 + 1e-6
    check laptopFit * desktopH.float <= 700.0 + 1e-6
    check percentLabel(laptopFit) == "69%"

    # A phone frame (390x844) in a 1000x900 area is smaller than the area in
    # both directions, so Fit must stay at 100% and not enlarge it.
    check fitScale(390, 844, PreviewArea(width: 1000, height: 900)) == 1.0
    check previewFitMaxScale == 1.0

    # A frame that is taller than the area is scaled down to fit the height.
    let phoneFit = fitScale(390, 844, PreviewArea(width: 1000, height: 700))
    check abs(phoneFit - 700.0 / 844.0) < 1e-9

    # A very large area still caps Fit at 100%.
    check fitScale(desktopW, desktopH, PreviewArea(width: 4000, height: 3000)) == 1.0

    # Before the view has measured the area, Fit shows the real size.
    check fitScale(desktopW, desktopH, PreviewArea()) == 1.0

  test "test_preview_zoom_fit_never_exceeds_100 (view model)":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      check vm.previewZoom.val.mode == pzmFit
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)
      let scale = previewScale(vm.previewZoom.val,
        previewViewportWidth(vm.viewport.val),
        previewViewportHeight(vm.viewport.val), vm.previewArea.val)
      check percentLabel(scale) == "69%"
      # Recomputed when the preview area changes ...
      vm.setPreviewArea(3000, 2000)
      check previewScale(vm.previewZoom.val, 1440, 900,
        vm.previewArea.val) == 1.0
      # ... and when the viewport changes.
      vm.setPreviewArea(1000, 700)
      vm.changeViewport(makeBuiltinViewport(pvkPhone))
      check previewScale(vm.previewZoom.val,
        previewViewportWidth(vm.viewport.val),
        previewViewportHeight(vm.viewport.val), vm.previewArea.val) == 700.0 / 844.0
      dispose()

  test "test_preview_zoom_100_scrolls":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)
      vm.setPreviewZoomLevel(1.0)
      let page = renderedPage(vm)
      let stage = findByAttr(page, "data-preview-zoom-stage", "true")
      let frame = findByAttr(page, "data-preview-zoom-frame", "true")
      check stage != nil
      check frame != nil
      # The frame keeps its fixed 1440x900 size at 100%: no transform.
      check frame.styles["width"] == "1440px"
      check frame.styles["height"] == "900px"
      check frame.styles["transform"] == "none"
      check frame.attributes["data-preview-zoom-scale"] == "1.0"
      # The stage is the scroll content, so its size is the scaled frame. At
      # 100% it is larger than the 1000x700 area in both directions, so the
      # area scrolls horizontally and vertically.
      let stageW = pxValue(stage.styles["width"])
      let stageH = pxValue(stage.styles["height"])
      check stageW == 1440
      check stageH == 900
      check stageW > 1000
      check stageH > 700
      check stage.styles["flex-shrink"] == "0"
      # The scroll host is the first child of the page root and scrolls on
      # both axes (overflow auto), and it contains the stage.
      check page.children.len > 0
      check page.children[0].styles["overflow"] == "auto"
      check findByAttr(page.children[0], "data-preview-zoom-stage", "true") != nil
      dispose()

  test "test_preview_zoom_100_scrolls (zoomed out frame is centred, not scrolled)":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)
      vm.setPreviewZoomLevel(0.5)
      let page = renderedPage(vm)
      let stage = findByAttr(page, "data-preview-zoom-stage", "true")
      let frame = findByAttr(page, "data-preview-zoom-frame", "true")
      check stage.styles["width"] == "720px"
      check stage.styles["height"] == "450px"
      check stage.styles["margin"] == "auto"
      check frame.styles["transform"] == "scale(0.5)"
      check frame.styles["transform-origin"] == "0 0"
      check frame.attributes["data-preview-zoom-scale"] == "0.5"
      dispose()

  test "test_preview_zoom_steps_and_readout":
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)
      # From Fit (69%), zoom in goes to the next step above, zoom out to the
      # next step below.
      vm.stepPreviewZoomBy(1)
      check vm.previewZoom.val.mode == pzmFixed
      check vm.previewZoom.val.level == 0.75
      vm.stepPreviewZoomBy(1)
      check vm.previewZoom.val.level == 1.0
      vm.stepPreviewZoomBy(1)
      check vm.previewZoom.val.level == 1.25
      vm.stepPreviewZoomBy(-1)
      check vm.previewZoom.val.level == 1.0
      vm.stepPreviewZoomBy(-1)
      check vm.previewZoom.val.level == 0.75
      vm.stepPreviewZoomBy(-1)
      check vm.previewZoom.val.level == 0.5
      vm.stepPreviewZoomBy(-1)
      check vm.previewZoom.val.level == 0.25
      # The ends of the range hold.
      vm.stepPreviewZoomBy(-1)
      check vm.previewZoom.val.level == 0.25
      for _ in 0 ..< 20:
        vm.stepPreviewZoomBy(1)
      check vm.previewZoom.val.level == 4.0
      # Fit returns to the fitted level for the current area and viewport.
      vm.setPreviewZoomFit()
      check vm.previewZoom.val.mode == pzmFit
      check percentLabel(previewScale(vm.previewZoom.val, 1440, 900,
        vm.previewArea.val)) == "69%"
      dispose()

  test "test_preview_zoom_steps_and_readout (chrome bar)":
    createRoot do (dispose: proc()):
      let r = MockRenderer()
      let vm = createEditorVM()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)
      vm.activeView.val = evPagePreview
      let bar = renderPreviewChromeBar[MockRenderer, MockNode](r, vm)
      let readout = findByAttr(bar, "data-preview-zoom-level", "true")
      check readout != nil
      check readout.textContent == "69%"
      let zoomIn = findByAttr(bar, "aria-label", "Zoom preview in")
      let zoomOut = findByAttr(bar, "aria-label", "Zoom preview out")
      let fit = findByAttr(bar, "aria-label", "Fit preview to the area")
      let actual = findByAttr(bar, "aria-label", "Show preview at 100%")
      check zoomIn != nil and zoomOut != nil and fit != nil and actual != nil
      check fit.attributes["aria-pressed"] == "true"
      zoomIn.fireEvent("click")
      check readout.textContent == "75%"
      check fit.attributes["aria-pressed"] == "false"
      actual.fireEvent("click")
      check readout.textContent == "100%"
      check actual.attributes["aria-pressed"] == "true"
      zoomOut.fireEvent("click")
      check readout.textContent == "75%"
      fit.fireEvent("click")
      check readout.textContent == "69%"
      check fit.attributes["aria-pressed"] == "true"
      # The cluster is shown over the web page preview ...
      let cluster = findByAttr(bar, "data-preview-zoom-cluster", "true")
      check cluster != nil
      check cluster.styles["display"] == "inline-flex"
      # ... and hidden over the storyboard, which has its own zoom cluster.
      vm.activeView.val = evStoryboard
      check cluster.styles["display"] == "none"
      vm.activeView.val = evPagePreview
      check cluster.styles["display"] == "inline-flex"
      dispose()

  test "test_preview_zoom_url_roundtrip":
    # Codec: what the story URL carries.
    check previewZoomRouteParam(defaultPreviewZoom()) == "fit"
    check previewZoomRouteParam(fixedPreviewZoom(0.5)) == "50"
    check previewZoomRouteParam(fixedPreviewZoom(1.25)) == "125"
    let base = defaultPreviewZoom()
    check previewZoomFromRouteParam("fit", fixedPreviewZoom(0.5)).mode == pzmFit
    let at100 = previewZoomFromRouteParam("100", base)
    check at100.mode == pzmFixed and at100.level == 1.0
    let at50 = previewZoomFromRouteParam("50", base)
    check at50.mode == pzmFixed and at50.level == 0.5
    # Out-of-range levels clamp to the zoom range; damaged values keep the
    # zoom already shown.
    check previewZoomFromRouteParam("5", base).level == previewZoomMin
    check previewZoomFromRouteParam("9000", base).level == previewZoomMax
    check previewZoomFromRouteParam("bogus", fixedPreviewZoom(0.75)).level == 0.75
    check previewZoomFromRouteParam("", fixedPreviewZoom(0.75)).level == 0.75
    # Every state survives write then read.
    for zoom in [defaultPreviewZoom(), fixedPreviewZoom(0.25),
        fixedPreviewZoom(0.75), fixedPreviewZoom(1.0), fixedPreviewZoom(1.25),
        fixedPreviewZoom(4.0)]:
      let back = previewZoomFromRouteParam(previewZoomRouteParam(zoom),
        defaultPreviewZoom())
      check back.mode == zoom.mode
      if zoom.mode == pzmFixed:
        check back.level == zoom.level
    # The VM state the route sync reads and writes.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.previewZoom.val = previewZoomFromRouteParam("50", vm.previewZoom.val)
      check previewZoomRouteParam(vm.previewZoom.val) == "50"
      vm.setPreviewZoomFit()
      check previewZoomRouteParam(vm.previewZoom.val) == "fit"
      dispose()
