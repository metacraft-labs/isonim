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
