## Functional shared colour popup tests. MockRenderer is used only to execute
## renderer-neutral signals, validation and event wiring without a DOM; browser
## geometry/focus and preview-only literal changes are tested separately by
## test_editor_popup_gui.mjs on the compiled production editor. Actual persisted
## token edits through the production consumer adapter and compiler are tested
## by test_editor_color_source.nim. The commit callback
## is an explicitly controlled acceptance decision to cover refusal without
## inventing filesystem success. No fake source/compiler result is asserted here.
import std/[tables, unittest]
import isonim/core/[signals, owner, computation]
import isonim/editor/views/widgets/color_popover
import isonim/testing/mock_dom

proc find(node: MockNode; key, value: string): MockNode =
  if node == nil: return nil
  if node.attributes.getOrDefault(key) == value: return node
  for child in node.children:
    result = find(child, key, value)
    if result != nil: return

suite "shared functional colour popup":
  test "hex normalization accepts only complete colour syntax":
    for (raw, expected) in [("#abc", "#AABBCC"), ("#abcd", "#AABBCCDD"),
                            (" #AbCdEf ", "#ABCDEF"), ("#abcdef01", "#ABCDEF01")]:
      check normalizedHexColor(raw) == expected
    for raw in ["", "#", "#12", "#12345", "#1234567", "#123456789", "#gg0000", "red", "#123456;display:none", "#123456junk"]:
      check normalizedHexColor(raw) == ""
  test "authored rgb and rgba open with their actual channels without a write":
    check normalizedSourceColor("rgb(18, 52, 86)") == "#123456"
    check normalizedSourceColor("rgba(18, 52, 86, 0.5)") == "#12345680"
    check normalizedSourceColor("rgba(18, 52, 86)") == "#123456"
    check normalizedSourceColor("hsl(120 50 50 / 50%)") == "#40BF4080"
    check normalizedSourceColor("rgb(100% 0% 0%)") == "#FF0000"
    check normalizedSourceColor("hsl(10%,50%,50%)") == ""
    # Authored CSS channels clamp according to the browser color domain;
    # individual typed picker-channel inputs keep their explicit 0..255 bounds.
    check normalizedSourceColor("rgb(999,2,3)") == "#FF0203"
    check normalizedSourceColor("rgba(1,2,3,2)") == "#010203"
    for raw in ["rgba(1,2,3,NaN)","rgb(1,2,3)junk"]:
      check normalizedSourceColor(raw) == ""
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var calls = 0
      discard mountColorPopover(r,parent,invoker,state,
        proc(): string = "rgba(18, 52, 86, 0.5)",
        proc(value: string): bool = inc calls; true)
      invoker.fireEvent("click")
      check state.draft.val == "#12345680"
      let channels = colorChannels(state.draft.val)
      check channels.red == 18
      check channels.green == 52
      check channels.blue == 86
      check channels.alpha == 128
      parent.find("data-color-popover-cancel","true").fireEvent("click")
      check calls == 0
      dispose()
  test "open, choose, apply and cancel are real control events":
    createRoot(proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var value = "#010203"
      var commits = 0
      discard mountColorPopover(r, parent, invoker, state,
        proc(): string = value,
        proc(next: string): bool = value = next; inc commits; true)
      invoker.fireEvent("click")
      check state.open.val
      check state.draft.val == value
      for color in ["#FFFFFF", "#3B82F6", "#22C55E"]:
        parent.find("data-color-popover-swatch", color).fireEvent("click")
        check state.draft.val == color
      check commits == 0
      parent.find("data-color-popover-apply", "true").fireEvent("click")
      check commits == 1
      check value == "#22C55E"
      check not state.open.val
      invoker.fireEvent("click")
      state.draft.val = "#abcdef"
      parent.find("data-color-popover-cancel", "true").fireEvent("click")
      check commits == 1
      check value == "#22C55E"
      parent.find("data-color-popover-apply", "true").fireEvent("click")
      check commits == 1 # A late Apply after dismissal cannot commit.
      dispose())
  test "invalid and refused edits remain retryable":
    createRoot(proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var calls = 0
      discard mountColorPopover(r, parent, invoker, state,
        proc(): string = "#010203",
        proc(next: string): bool = inc calls; false)
      invoker.fireEvent("click")
      state.draft.val = "#invalid"
      parent.find("data-color-popover-apply", "true").fireEvent("click")
      check calls == 0
      check state.open.val
      check state.diagnostic.val.len > 0
      state.draft.val = "#123"
      parent.find("data-color-popover-apply", "true").fireEvent("click")
      check calls == 1
      check state.open.val
      check state.diagnostic.val == "The color edit was refused."
      dispose())
  test "RGB HSV and alpha share complete channel validation":
    for raw in ["#000000", "#FFFFFF", "#FF0000", "#00FF00", "#0000FF", "#12345680"]:
      let original = colorChannels(raw)
      let hsv = colorHsv(original)
      let roundtrip = hsvChannels(hsv.hue, hsv.saturation, hsv.value, original.alpha)
      check channelsHex(roundtrip) == raw
    check channelsHex(hsvChannels(0, 1, 1)) == "#FF0000"
    check channelsHex(hsvChannels(120, 1, 1, 128)) == "#00FF0080"
    check channelsHex(hsvChannels(240, 1, 1)) == "#0000FF"

  test "typed channels and hue opacity controls update one cancelable draft":
    createRoot(proc(dispose: proc()) =
      let r = MockRenderer()
      let parent = r.createElement("div")
      let invoker = r.createElement("div")
      let state = createColorPopoverState()
      var value = "#FF0000"
      var commits = 0
      discard mountColorPopover(r, parent, invoker, state,
        proc(): string = value,
        proc(next: string): bool = value = next; inc commits; true)
      invoker.fireEvent("click")
      let red = parent.find("data-color-channel", "Red")
      r.setInputValue(red, "32")
      red.fireEvent("change")
      check state.draft.val == "#200000"
      let green = parent.find("data-color-channel", "Green")
      r.setInputValue(green, "300")
      green.fireEvent("change")
      check state.draft.val == "#200000"
      check state.diagnostic.val.len > 0
      state.draft.val = "#FF0000"
      let hue = parent.find("data-color-hue", "true")
      r.setInputValue(hue, "120")
      hue.fireEvent("input")
      check state.draft.val == "#00FF00"
      let alpha = parent.find("data-color-alpha", "true")
      r.setInputValue(alpha, "50")
      alpha.fireEvent("input")
      check state.draft.val == "#00FF0080"
      check commits == 0
      parent.find("data-color-popover-cancel", "true").fireEvent("click")
      check value == "#FF0000"
      check commits == 0
      invoker.fireEvent("click")
      r.setInputValue(parent.find("data-color-channel", "Alpha %"), "25")
      parent.find("data-color-channel", "Alpha %").fireEvent("change")
      parent.find("data-color-popover-apply", "true").fireEvent("click")
      check value == "#FF000040"
      check commits == 1
      dispose())
