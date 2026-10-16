## HSV intent and renderer-neutral picker contract. Pure state tests use real
## signals and production color math. MockRenderer substitutes only DOM mounting
## for marker/accessibility and cancel wiring; it does not invent source/compiler
## outcomes. Real native files/compiler/preview and physical browser controls are
## covered by test_editor_color_picker_gui.mjs.
import std/[unittest, math, strutils, tables]
import isonim/core/[signals, owner, computation]
import isonim/editor/views/widgets/color_popover
import isonim/testing/mock_dom

proc find(node: MockNode; key, value: string): MockNode =
  if node == nil: return nil
  if node.attributes.getOrDefault(key) == value: return node
  for child in node.children:
    result = find(child, key, value)
    if result != nil: return

suite "ColorPicker coordinates and controls":
  test "HSV projection preserves primary channels and opacity":
    check channelsHex(hsvChannels(120, 1, 1, 128)) == "#00FF0080"
    check channelsHex(hsvChannels(240, 1, 1)) == "#0000FF"
    let hsv = colorHsv(colorChannels("#FF0000"))
    check hsv.hue == 0 and hsv.saturation == 1 and hsv.value == 1
  test "black retains chosen hue and saturation through identical RGB projections":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.setColorHsv(120, 0.75, 0, 255)
      check state.draft.val == "#000000"
      state.syncColorCoordinates()
      state.setColorHsv(240, state.saturation.val, state.brightness.val, 255)
      state.syncColorCoordinates()
      check state.hue.val == 240 and state.saturation.val == 0.75
      state.setColorHsv(state.hue.val, state.saturation.val, 0.5, 255)
      check state.draft.val == "#202080"
      dispose()
  test "quantization does not displace the requested marker":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.setColorHsv(213, 0.6123, 0.0001, 255)
      check state.draft.val == "#000000"
      state.syncColorCoordinates()
      check state.saturation.val == 0.6123 and state.brightness.val == 0.0001
      dispose()
  test "typed colors resynchronize coordinates while achromatic hues stay meaningful":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.setColorHsv(240, 0.8, 0.3, 255)
      state.draft.val = "#FFFFFF"
      state.syncColorCoordinates()
      check state.hue.val == 240 and state.saturation.val == 0 and state.brightness.val == 1
      state.draft.val = "#00FF00"
      state.syncColorCoordinates()
      check state.hue.val == 120 and state.saturation.val == 1 and state.brightness.val == 1
      state.draft.val = "#unfinished"
      state.syncColorCoordinates()
      check state.hue.val == 120 and state.saturation.val == 1
      dispose()
  test "keyboard axes clamp and cannot edit closed or pending drafts":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.open.val = true
      state.setColorHsv(240, 0.5, 0.5, 128)
      check state.adjustColorPlane("ArrowRight")
      check abs(state.saturation.val - 0.51) < 1e-12
      check state.adjustColorPlane("ArrowUp")
      check abs(state.brightness.val - 0.51) < 1e-12
      check state.adjustColorPlane("ArrowLeft") and state.adjustColorPlane("ArrowDown")
      check abs(state.saturation.val - 0.5) < 1e-12
      check not state.adjustColorPlane("Tab") and not state.adjustColorPlane("Escape")
      state.setColorHsv(240, 0, 1, 128)
      check state.adjustColorPlane("ArrowLeft") and state.adjustColorPlane("ArrowUp")
      check state.saturation.val == 0 and state.brightness.val == 1
      let before = state.captureColorDraft()
      state.pending.val = true
      check not state.adjustColorPlane("ArrowRight")
      check state.captureColorDraft() == before
      state.pending.val = false; state.open.val = false
      check not state.adjustColorPlane("ArrowDown")
      check state.captureColorDraft() == before
      dispose()
  test "cancel restores latent coordinates even when the hex did not change":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.setColorHsv(240, 0.75, 0, 255)
      let before = state.captureColorDraft()
      state.setColorHsv(90, 0.25, 0, 255)
      check state.draft.val == before.draft
      state.restoreColorDraft(before)
      check state.captureColorDraft() == before
      dispose()
  test "nonfinite coordinates refuse without corrupting draft":
    createRoot proc(dispose: proc()) =
      let state = createColorPopoverState()
      state.setColorHsv(120, 1, 1, 255)
      let before = state.captureColorDraft()
      state.setColorHsv(NaN, 1, 1, 255)
      state.setColorHsv(120, Inf, 1, 255)
      state.setColorHsv(120, 1, NegInf, 255)
      check state.captureColorDraft() == before
      dispose()
  test "square marker and accessible axes reflect coordinates; Cancel restores opening state":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer(); let parent = r.createElement("div"); let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var calls = 0
      discard mountColorPopover(r,parent,invoker,state,proc(): string = "#112233",proc(value:string):bool = inc calls; false)
      invoker.fireEvent("click")
      let before = state.captureColorDraft()
      state.setColorHsv(210, 0.6, 0.8, 255)
      let plane = parent.find("data-color-plane", "true")
      let marker = parent.find("data-color-plane-marker", "true")
      check plane.styles.getOrDefault("aspect-ratio") == "1 / 1"
      check plane.attributes.getOrDefault("aria-description").contains("Left and right")
      check marker != nil and marker.styles.getOrDefault("pointer-events") == "none"
      check abs(parseFloat(marker.styles.getOrDefault("left").replace("%", ""))-60) < 1e-9
      check abs(parseFloat(marker.styles.getOrDefault("top").replace("%", ""))-20) < 1e-9
      check parent.find("data-color-alpha", "true").styles.getOrDefault("background").contains("conic-gradient")
      parent.find("data-color-popover-cancel", "true").fireEvent("click")
      check state.captureColorDraft() == before
      check not state.open.val and calls == 0
      dispose()

  test "disposal restores opening coordinates and retired controls cannot resurrect the draft":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer(); let parent = r.createElement("div"); let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var calls = 0
      discard mountColorPopover(r,parent,invoker,state,proc(): string = "#112233",proc(value:string):bool = inc calls; false)
      invoker.fireEvent("click")
      let opening = state.captureColorDraft()
      state.setColorHsv(120, 0.75, 0, 255)
      let apply = parent.find("data-color-popover-apply", "true")
      let palette = parent.find("data-color-popover-swatch", "#FFFFFF")
      let input = parent.find("data-color-popover-input", "true")
      dispose()
      check state.captureColorDraft() == opening
      check not state.open.val
      invoker.fireEvent("click"); palette.fireEvent("click")
      r.setInputValue(input,"#FF0000"); input.fireEvent("input")
      apply.fireEvent("click")
      check state.captureColorDraft() == opening
      check not state.open.val and calls == 0
