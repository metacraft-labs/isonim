## PSZ-M3 (Preview-Sizing-And-Zoom): the zoom state drives the streamed
## backends and the TUI cell frame.
##
## Mocks, and why each is here:
## - ``MockRenderer`` / ``MockNode`` (isonim/testing/mock_dom) stand in for the
##   DOM only, as in test_editor_preview_zoom.nim. They let the test read the
##   inline styles the page preview writes for the streamed canvas wrapper
##   (``transform``, ``width``, ``height``) and the zoom stage. Nothing is faked
##   on the editor side.
## - No launcher runs in the model half. The DOM and model assertions check the
##   layout contract the launcher's image is drawn into: the frame size, the
##   scale and the scroll stage.
## - The frame-image half (``checkCapturedFrame``, after the model half) reads
##   a capture of the real page, not a fake. The capture is made by a GuiAssert
##   driver (outside tests/, see the PSZ-M3 milestone): the editor's GPUI page
##   preview, backed by the real ``isonim-examples-gpui`` launcher built with
##   isonim-gpui's windowed shim, runs in a chromium window on GuiAssert's
##   headless sway. The driver writes the screen at Fit and at 100%, shown and
##   with the streamed canvas hidden (``PSZ_M3_GPUI_FRAMES``). The painted frame
##   is the box where the two captures differ, so the size is measured from
##   pixels and not read back from the DOM. The test fails when no capture is
##   given, and when the painted frame is not the model's size.
##   Two checks read the frame's content, and they are separate on purpose:
##   * the STRUCTURAL check (``checkFrameStructure``) runs on every source. It
##     checks the shape of the frame, not its text: enough colours, a dark page
##     header, then a title block and a body block down the middle. A uniform
##     frame (a black or unpainted canvas, or a white page with no element
##     drawn) fails it, and so does a frame with other blocks (another story,
##     such as the Task App Inbox). The synthetic raster draws those three
##     blocks, so a synthetic frame passes it.
##   * the TEXT check (``checkFrameText``) reads the words of the frame with
##     tesseract and requires "Trip Planner". It runs only when the source is
##     ``real``. On a ``synthetic`` source it is reported as SKIPPED, with the
##     reason "synthetic source, text needs RS-M14b", and the skip is counted and
##     printed. It never passes silently. Running it needs ``tesseract`` on PATH
##     (the GuiAssert dev shell provides it); a real source without it fails.
##   The capture tool is tools/psz-m3-gpui-capture/ (its README says what must be
##   running).
##   The capture records the frame source the launcher declared (the hello's
##   ``capabilities.frameSource``, read by the page into the zoom stage's
##   ``data-preview-frame-declared``), and the label state. A synthetic source must
##   show the synthetic label; a real source must not. Any other source, or none,
##   fails.
##   The area the browser measured is handed to the model in that half, so the
##   model's Fit is computed for the layout that was captured.
## - No layout engine runs, so the preview area is supplied by the test through
##   ``setPreviewArea``, the entry point the browser's ResizeObserver calls.
##   Scrolling and the centring are checked in the browser, not here.
## - ``EditorVM``, its signals, the zoom reducers and the page preview's render
##   and zoom effects are all real. The platform is set to the streamed backend
##   the story is shown on; the story is a real page story.
## - The cell column width is the 0.6 em estimate (``EditorVM.previewCellWidth``
##   at its default). A headless build has no browser font to measure, so this
##   file checks the model at that estimate: an 80x24 frame is 674x396 here. The
##   browser's measured width (677x396) is checked by
##   tests/browser/e2e_tui_cells_viewport_zoom_live.mjs, and one case below sets
##   the measured value to show that the model reads whatever the page measured.
import std/[json, math, os, osproc, sequtils, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import isonim/editor/[viewmodels, types, preview_zoom]
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

proc pageStory(): StoryRef =
  ## A page story, so the page preview takes its streamed path on a non-web
  ## backend (``useCanvas`` in page_preview.nim needs ``skPage``).
  StoryRef(group: "Destination", name: "Default", kind: skPage, index: 0)

const
  syntheticLabelText = "Synthetic preview: GPUI draws boxes only on Linux"
    ## The note the page preview shows under a synthetic frame
    ## (``renderPagePreview``, ``frameSourceLabel``).
  textSkipReason = "synthetic source, text needs RS-M14b"
    ## The reason the text check is reported as skipped on a synthetic source.
  tripPlannerWords = "trip planner"
    ## The words the text check must read on a real frame (lower case).
  desktopFrameW = 1440
    ## The Desktop preset's frame, in CSS px (``makeBuiltinViewport(pvkDesktop)``).
  desktopFrameH = 900

type
  PpmImage = object
    width, height: int
    rgb: string

proc parsePpm(path: string): PpmImage =
  ## Reads a binary PPM (P6, maxval 255) as written by the capture driver.
  let text = readFile(path)
  var pos = 0
  proc token(): string =
    while pos < text.len and text[pos] in Whitespace: inc pos
    let start = pos
    while pos < text.len and text[pos] notin Whitespace: inc pos
    result = text[start ..< pos]
  doAssert token() == "P6", "not a binary PPM: " & path
  result.width = parseInt(token())
  result.height = parseInt(token())
  doAssert token() == "255", "PPM maxval must be 255: " & path
  inc pos # the single whitespace byte that ends the header
  result.rgb = text[pos .. ^1]
  doAssert result.rgb.len == result.width * result.height * 3,
    "PPM payload does not match its header: " & path

type
  PaintedBox = object
    x, y, w, h: int
    ## The frame's box on screen, in the capture's pixels.

proc paintedBox(shownPath, hiddenPath: string): PaintedBox =
  ## The box the streamed frame paints on screen. The two captures differ only
  ## where the canvas paints, because the driver hides the canvas and nothing
  ## else; the box of the differing pixels is the frame.
  let shown = parsePpm(shownPath)
  let hidden = parsePpm(hiddenPath)
  doAssert shown.width == hidden.width and shown.height == hidden.height,
    "the shown and hidden captures are different sizes"
  var minX = high(int)
  var minY = high(int)
  var maxX = -1
  var maxY = -1
  for y in 0 ..< shown.height:
    for x in 0 ..< shown.width:
      let i = (y * shown.width + x) * 3
      var delta = 0
      for c in 0 .. 2:
        delta = max(delta, abs(ord(shown.rgb[i + c]) - ord(hidden.rgb[i + c])))
      if delta > 24:
        minX = min(minX, x)
        minY = min(minY, y)
        maxX = max(maxX, x)
        maxY = max(maxY, y)
  if maxX < 0:
    return PaintedBox()
  result = PaintedBox(x: minX, y: minY, w: maxX - minX + 1, h: maxY - minY + 1)

proc pixel(img: PpmImage; x, y: int): tuple[r, g, b: int] =
  let i = (y * img.width + x) * 3
  (ord(img.rgb[i]), ord(img.rgb[i + 1]), ord(img.rgb[i + 2]))

proc distance(a, b: tuple[r, g, b: int]): int =
  max(abs(a.r - b.r), max(abs(a.g - b.g), abs(a.b - b.b)))

type
  Block = object
    colour: tuple[r, g, b: int]
    length: int

proc columnBlocks(img: PpmImage; box: PaintedBox): seq[Block] =
  ## The runs of one colour down the middle of the frame, top to bottom. Runs
  ## shorter than 6 px are edge pixels, not elements.
  var runs: seq[Block]
  let x = box.x + box.w div 2
  for y in box.y ..< box.y + box.h:
    let c = pixel(img, x, y)
    if runs.len > 0 and distance(runs[^1].colour, c) <= 12:
      inc runs[^1].length
    else:
      runs.add Block(colour: c, length: 1)
  for run in runs:
    if run.length >= 6:
      result.add run

proc checkFrameStructure(shownPath: string; box: PaintedBox; state: string) =
  ## The STRUCTURAL check: the frame's shape, not its words. It runs on every
  ## source. The expected shape is the Trip Planner page's: a dark page header,
  ## then a title block and a body block one below the other down the middle of
  ## the frame. It passes a real frame and the synthetic raster alike, because
  ## both draw those three blocks. It fails:
  ##   * a uniform frame: a black or unpainted canvas, or a white page with no
  ##     element drawn (the note 20 captures are white with an unpainted canvas);
  ##   * a frame with other blocks (another story, such as the Task App Inbox).
  ## It does NOT read text. The words are the text check's job
  ## (``checkFrameText``), so a boxes-only frame passes this check and fails that.
  let shot = parsePpm(shownPath)
  var colours = initCountTable[int]()
  for y in box.y ..< box.y + box.h:
    for x in countup(box.x, box.x + box.w - 1, 3):
      let c = pixel(shot, x, y)
      inc colours, c.r * 65536 + c.g * 256 + c.b
  var total = 0
  var largest = 0
  for _, count in colours.pairs:
    inc total, count
    largest = max(largest, count)
  let share = largest.float / total.float
  echo "  structure ", state, ": ", colours.len, " colours in the frame, the largest ", int(share * 100), "%"
  doAssert colours.len >= 3,
    "the " & state & " frame has " & $colours.len & " colour(s): it is not a rendered page"
  doAssert share < 0.9,
    "the " & state & " frame is " & $int(share * 100) & "% one colour"
  let blocks = columnBlocks(shot, box)
  echo "  structure ", state, ": blocks down the middle ", blocks.len, " (",
    blocks.mapIt($it.length).join(", "), " px)"
  doAssert blocks.len == 3,
    "the " & state & " frame has " & $blocks.len & " element blocks, not the page's header, title and body"
  doAssert blocks[0].length <= 16,
    "the page header is " & $blocks[0].length & " px in " & state
  doAssert blocks[1].length >= 100 and blocks[2].length >= 100,
    "the title and body blocks are not both element-sized in " & state
  doAssert distance(blocks[1].colour, blocks[2].colour) > 12,
    "the title and body blocks are one colour in " & state

proc writeCrop(shot: PpmImage; box: PaintedBox; path: string) =
  ## Writes the painted box as a binary PPM: the form tesseract reads directly.
  var data = "P6\n" & $box.w & " " & $box.h & "\n255\n"
  for y in box.y ..< box.y + box.h:
    let start = (y * shot.width + box.x) * 3
    data.add shot.rgb[start ..< start + box.w * 3]
  writeFile(path, data)

proc checkFrameText(shownPath: string; box: PaintedBox; state, source,
                    outDir: string): int =
  ## The TEXT check: the title must be readable. It reads the painted frame with
  ## tesseract and requires the Trip Planner words. It runs only for a ``real``
  ## frame. For a ``synthetic`` frame the check is SKIPPED: the printed line
  ## says so and the caller counts it (the return value is 1 for a skip, 0 for a
  ## run). The synthetic raster draws boxes, so reading it proves nothing about
  ## the words; that needs the real Linux frame (RS-M14b). A real frame without
  ## tesseract on PATH fails here, it does not skip.
  if source != "real":
    echo "  SKIPPED text ", state, ": ", textSkipReason
    return 1
  let shot = parsePpm(shownPath)
  let crop = outDir / (state & "-frame-text.ppm")
  writeCrop(shot, box, crop)
  let (output, code) = execCmdEx("tesseract " & quoteShell(crop) & " stdout")
  doAssert code == 0,
    "the text check of the real " & state & " frame could not run tesseract (exit " &
    $code & "): install tesseract, the GuiAssert dev shell has it"
  let words = output.splitWhitespace().join(" ").toLowerAscii()
  echo "  text ", state, ": ", words.splitWhitespace().len, " word(s) read, Trip Planner ",
    (if tripPlannerWords in words: "found" else: "not found")
  doAssert tripPlannerWords in words,
    "the real " & state & " frame does not show the readable title '" &
    tripPlannerWords & "' (the words read: '" & words.strip() & "')"
  result = 0

proc frameSourceOf(meta: JsonNode): string =
  ## The frame source the capture declares: ``real``, ``synthetic``, or ``""``
  ## when the capture declares none.
  if meta.hasKey("frameSource") and meta["frameSource"].kind == JString:
    result = meta["frameSource"].getStr
  else:
    result = ""

proc checkSyntheticLabel(meta: JsonNode; state: string) =
  ## A synthetic frame must say so on screen: the note is present, visible,
  ## and carries the expected text. Without it the frame is shown as a real one.
  let label = meta["frameSourceLabel"]
  doAssert label["present"].getBool,
    "the synthetic frame in " & state & " has no frame-source label"
  doAssert label["visible"].getBool,
    "the synthetic frame-source label is not visible in " & state
  doAssert label["text"].getStr == syntheticLabelText,
    "the frame-source label in " & state & " reads '" & label["text"].getStr &
    "', not the synthetic note"

proc checkCapturedFrame(vm: EditorVM; dir, state: string): int =
  ## One capture state (``fit``, ``actual``, ``actual-wide``): the browser's
  ## preview area is fed to the model, and the painted frame must be the model's
  ## frame at the model's scale, as far as the scroll area shows it. The area
  ## clips a frame larger than it, so the painted box is the frame's size on
  ## each axis, or the area's size where the area is smaller. A 100% state must
  ## have a frame larger than the area on some axis: the area scrolls.
  ## Returns the number of text checks SKIPPED for this state (1 on a synthetic
  ## source, 0 on a real one). The caller sums and prints them.
  let meta = parseJson(readFile(dir / (state & ".json")))
  let source = frameSourceOf(meta)
  doAssert source in ["real", "synthetic"],
    "the " & state & " capture declares no frame source (got '" & source & "')"
  let areaW = meta["areaWidth"].getInt
  let areaH = meta["areaHeight"].getInt
  doAssert areaW > 0 and areaH > 0, "the browser measured no preview area for " & state
  vm.setPreviewArea(areaW, areaH)
  let scale = previewScale(vm.previewZoom.val, desktopFrameW, desktopFrameH,
    vm.previewArea.val)
  let frameW = int(round(desktopFrameW.float * scale))
  let frameH = int(round(desktopFrameH.float * scale))
  let want = (w: min(frameW, areaW), h: min(frameH, areaH))
  # The browser applied the same scale the model computes.
  doAssert abs(parseFloat(meta["scale"].getStr) - scale) < 0.005,
    "the browser scale of " & state & " is not the model scale " & $scale
  let box = paintedBox(dir / (state & "-shown.ppm"),
    dir / (state & "-hidden.ppm"))
  echo "  ", state, ": area ", areaW, "x", areaH, ", scale ", scale,
    ", model frame ", frameW, "x", frameH, ", visible frame ", want.w, "x",
    want.h, ", painted frame ", box.w, "x", box.h
  doAssert box.w > 0 and box.h > 0, "no painted frame in " & state
  doAssert abs(box.w - want.w) <= 1,
    "painted frame width " & $box.w & " is not " & $want.w & " in " & state
  doAssert abs(box.h - want.h) <= 1,
    "painted frame height " & $box.h & " is not " & $want.h & " in " & state
  if source == "synthetic":
    checkSyntheticLabel(meta, state)
  else:
    # A real frame must not carry the synthetic note.
    doAssert not meta["frameSourceLabel"]["visible"].getBool,
      "the real frame in " & state & " shows the synthetic note"
  # The structural check runs on both sources. It is the gate for the frame's
  # shape, not its text (the text check below is separate).
  checkFrameStructure(dir / (state & "-shown.ppm"), box, state)
  # The text check runs on a real frame and is SKIPPED (counted, printed) on a
  # synthetic one, because the synthetic raster has no words to read (RS-M14b).
  result = checkFrameText(dir / (state & "-shown.ppm"), box, state, source, dir)
  if state.startsWith("actual"):
    # At 100% the frame is larger than the area on some axis, so it scrolls.
    doAssert (desktopFrameW > areaW) or (desktopFrameH > areaH),
      "the 100% frame does not overflow the area in " & state

suite "Preview streamed and TUI zoom (PSZ-M3)":
  test "test_streamed_preview_follows_zoom_state":
    # The Desktop preset is the 1440x900 frame (D3 closed by the operator, spec commit d0816e04).
    # The GPUI story is a page story on the streamed backend. The frame image
    # is checked at the end of this test, from the capture.
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbGpui
      vm.selectedStory.val = pageStory()
      vm.changeViewport(makeBuiltinViewport(pvkDesktop))
      vm.setPreviewArea(1000, 700)

      # Fit is the default: the frame is scaled to the 1000 px wide area.
      check vm.previewZoom.val.mode == pzmFit
      let fitScale = previewScale(vm.previewZoom.val, 1440, 900,
        vm.previewArea.val)
      check percentLabel(fitScale) == "69%"
      let page = renderedPage(vm)
      let wrapper = findByAttr(page, "data-canvas-wrapper", "true")
      let stage = findByAttr(page, "data-preview-zoom-stage", "true")
      check wrapper != nil
      check stage != nil
      # The streamed frame is drawn as the device frame is: the same scale,
      # the same stage, and no CSS stretching of the launcher's pixels.
      check wrapper.styles["transform"] == "scale(" & $fitScale & ")"
      check wrapper.attributes["data-preview-zoom-scale"] == $fitScale
      check wrapper.styles["width"] == "1440px"
      check wrapper.styles["height"] == "900px"
      check pxValue(stage.styles["width"]) == 1000
      check pxValue(stage.styles["height"]) == 625
      let canvas = findByAttr(wrapper, "data-page-project-canvas", "true")
      check canvas != nil
      check canvas.styles["display"] == "block"
      check canvas.styles["image-rendering"] == "pixelated"
      # The preview area has no gutter on the streamed path either (PSZ-M3).
      check page.children[0].styles["padding"] == "0"

      # At 1440x900 and 100% the frame keeps its size and no transform is set;
      # the stage is larger than the 1000x700 area, so the area scrolls.
      vm.setPreviewZoomLevel(1.0)
      let page100 = renderedPage(vm)
      let wrapper100 = findByAttr(page100, "data-canvas-wrapper", "true")
      let stage100 = findByAttr(page100, "data-preview-zoom-stage", "true")
      check wrapper100.styles["transform"] == "none"
      check wrapper100.attributes["data-preview-zoom-scale"] == "1.0"
      check wrapper100.styles["width"] == "1440px"
      check wrapper100.styles["height"] == "900px"
      check pxValue(stage100.styles["width"]) == 1440
      check pxValue(stage100.styles["height"]) == 900
      check page100.children[0].styles["overflow"] == "auto"
      check findByAttr(page100.children[0], "data-preview-zoom-stage",
        "true") != nil

      # The frame image: the captured pixels at Fit, then at 100%. The capture
      # is required; without it this test cannot show the frame's size.
      let frames = getEnv("PSZ_M3_GPUI_FRAMES")
      doAssert frames.len > 0, "PSZ_M3_GPUI_FRAMES names no capture directory"
      vm.setPreviewZoomFit()
      var skipped = 0
      skipped += vm.checkCapturedFrame(frames, "fit")
      vm.setPreviewZoomLevel(1.0)
      skipped += vm.checkCapturedFrame(frames, "actual")
      # A second 100% capture, in a window where the area is wider than the
      # frame: the full 1440 px width is then visible, and the area scrolls
      # vertically. Together the two captures show the frame's 1440 and 900.
      skipped += vm.checkCapturedFrame(frames, "actual-wide")
      # Every skipped text check is printed and counted; none passes silently.
      echo "  text checks SKIPPED: ", skipped, " of 3 (", textSkipReason, ")"
      dispose()

  test "test_tui_cells_viewport_zoom":
    # An 80x24 terminal is a cell grid at the preview font (14 px, 0.6 em by
    # 1.18 em) plus the wrapper's 1 px border on each side. At the 0.6 em
    # headless estimate that is 674x396 px; the browser's measured column width
    # gives 677x396 (spec "Cell frame (TUI)").
    check tuiCellFrameSize(80, 24) == (width: 674, height: 396)
    check tuiCellFrameSize(120, 40) == (width: 1010, height: 661)
    check tuiCellFrameSize(80, 24, 8.4375) == (width: 677, height: 396)
    createRoot do (dispose: proc()):
      let vm = createEditorVM()
      vm.platform.val = pbTui
      vm.selectedStory.val = pageStory()
      vm.changeViewport(makeBuiltinViewport(pvkTui80x24))
      check vm.previewCellWidth.val == 0.6 * 14.0
      check previewFrameSize(vm.viewport.val, vm.previewCellWidth.val) ==
        (width: 674, height: 396)

      # In a 1000x700 area the grid fits at its real size, so Fit is 100%.
      vm.setPreviewArea(1000, 700)
      check vm.previewZoom.val.mode == pzmFit
      let wide = renderedPage(vm)
      let wideWrapper = findByAttr(wide, "data-canvas-wrapper", "true")
      check wideWrapper.styles["width"] == "674px"
      check wideWrapper.styles["height"] == "396px"
      check wideWrapper.styles["transform"] == "none"
      check wideWrapper.attributes["data-preview-zoom-scale"] == "1.0"

      # In a 500x300 area Fit scales the frame down to the area, by the
      # constraining (height-free) direction: min(500/674, 300/396).
      vm.setPreviewArea(500, 300)
      let fitScale = previewScale(vm.previewZoom.val, 674, 396,
        vm.previewArea.val)
      check fitScale < 1.0
      check percentLabel(fitScale) == "74%"
      let small = renderedPage(vm)
      let smallWrapper = findByAttr(small, "data-canvas-wrapper", "true")
      let smallStage = findByAttr(small, "data-preview-zoom-stage", "true")
      check smallWrapper.styles["transform"] == "scale(" & $fitScale & ")"
      check smallWrapper.styles["width"] == "674px"
      check pxValue(smallStage.styles["width"]) == 500
      check pxValue(smallStage.styles["height"]) == 294

      # At 100% the grid is drawn at its real size, with the area scrolling.
      vm.setPreviewZoomLevel(1.0)
      let real = renderedPage(vm)
      let realWrapper = findByAttr(real, "data-canvas-wrapper", "true")
      let realStage = findByAttr(real, "data-preview-zoom-stage", "true")
      check realWrapper.styles["transform"] == "none"
      check pxValue(realStage.styles["width"]) == 674
      check pxValue(realStage.styles["height"]) == 396

      # The browser's measured column width replaces the estimate in the one
      # value every frame size reads: the model and the page then draw 677 px.
      vm.previewCellWidth.val = 8.4375
      check previewFrameSize(vm.viewport.val, vm.previewCellWidth.val) ==
        (width: 677, height: 396)
      let measured = renderedPage(vm)
      let measuredWrapper = findByAttr(measured, "data-canvas-wrapper", "true")
      check measuredWrapper.styles["width"] == "677px"
      check measuredWrapper.styles["height"] == "396px"
      dispose()
