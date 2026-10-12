## MockRenderer substitutes only event transport; the production DSL and chip
## builders install the handlers whose invocation counts are asserted here.
import std/unittest
import isonim/core/[owner, computation]
import isonim/testing/mock_dom
import isonim/renderers/[native, terminal_demo]
import isonim/editor/views/choice_row

suite "Compact choice activation":
  test "row and overflow choose once per click or activation key":
    createRoot do (dispose: proc()):
      var calls = 0
      let choose = proc() = inc calls
      let options = @[
        CompactChoiceOption(label: "First", enabled: true, onChoose: choose),
        CompactChoiceOption(label: "Second", enabled: true, onChoose: choose),
        CompactChoiceOption(label: "Disabled", enabled: false, onChoose: choose),
        CompactChoiceOption(label: "No callback", enabled: true)]
      let row = renderCompactChoiceRow[MockRenderer, MockNode](
        MockRenderer(), "", "Choices", options, visibleLimit = 1)
      let column = renderCompactChoiceColumn[MockRenderer, MockNode](
        MockRenderer(), "Choices", options, visibleLimit = 1)
      for nodes in [row.optionNodes, column.optionNodes]:
        for i, node in nodes:
          let enabled = i < 3 # primary First, popup First, popup Second
          let before = calls
          node.fireEvent("click")
          check calls == before + int(enabled)
          for key in ["Tab", "Escape", "ArrowRight", "Enter", " "]:
            let beforeKey = calls
            let ev = MockEvent(key: key)
            node.fireEventWith("keydown", ev)
            let activated = enabled and key in ["Enter", " "]
            check calls == beforeKey + int(activated)
            check ev.defaultPrevented == activated
      dispose()

template checkRendererKeys(R, N, Event: typedesc) =
  createRoot do (dispose: proc()):
    var calls = 0
    let row = renderCompactChoiceRow[R, N](R(), "", "Choice", @[
      CompactChoiceOption(label: "One", enabled: true,
        onChoose: proc() = inc calls)])
    let chip = row.optionNodes[0]
    chip.fireEvent("click")
    check calls == 1
    chip.fireEventWith("keydown", Event(key: "Tab"))
    check calls == 1
    for key in ["Enter", " "]:
      let before = calls
      let ev = Event(key: key)
      chip.fireEventWith("keydown", ev)
      check calls == before + 1
      check ev.defaultPrevented
    dispose()

suite "Renderer keyboard payloads":
  test "native DSL click and keyboard registration":
    checkRendererKeys(NativeRenderer, NativeWidget, NativeEvent)
  test "terminal DSL click and keyboard registration":
    checkRendererKeys(TerminalRenderer, TerminalNode, TerminalEvent)
