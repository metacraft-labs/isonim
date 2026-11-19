## MockRenderer substitutes only event transport; the production DSL and chip
## builders install the handlers whose invocation counts are asserted here.
import std/[tables, unittest]
import isonim/core/[owner, computation, signals]
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
          for key in ["", "Tab", "Escape", "ArrowRight", "Enter", " "]:
            let beforeKey = calls
            let ev = MockEvent(key: key)
            node.fireEventWith("keydown", ev)
            let activated = enabled and key in ["Enter", " "]
            check calls == beforeKey + int(activated)
            check ev.defaultPrevented == activated
      dispose()

  test "a choice that replaces the strip's options keeps its own callback alive":
    ## isonim-pm issue 2026-10-22-a-compact-choice-callback-can-free-its-own-
    ## environment. Choosing writes the signal the options are computed from,
    ## so the reactive strip replaces its options -- and drops the closures
    ## of the old ones -- while the chosen callback is still running; the
    ## callback then reads its own captured state. Under ARC/ORC that state
    ## must still be alive (a use-after-free otherwise, which the native
    ## AddressSanitizer run of this test reports: `just test-asan-compact-choice`).
    ## Before each choice the options are recomputed with the same labels
    ## (`refresh`): the strip keeps its chips and only takes the new
    ## options, so the chosen callback is one only the strip's latest
    ## options hold -- as a property row's are after any re-run of its
    ## scope options.
    createRoot do (dispose: proc()):
      let round = createSignal(0)
      let refresh = createSignal(0)
      var log: seq[string]
      # A row wraps its choices (a property row's `thenCommit` wraps the
      # scope's handler): the option holds the wrapper, and the wrapper alone
      # holds the inner callback.
      proc wrapped(inner: proc()): proc() =
        result = proc() = inner()
      proc optionFor(n, i: int): CompactChoiceOption =
        # Heap state of the inner callback's own, read after the choice has
        # replaced the options.
        let tag = new(string)
        tag[] = "round " & $n & " option " & $i
        let inner = proc() =
          round.val = round.val + 1
          log.add tag[]
        CompactChoiceOption(label: tag[], ariaLabel: "Option " & $i,
          enabled: true, onChoose: wrapped(inner))
      proc optionsFor(n: int): seq[CompactChoiceOption] =
        @[optionFor(n, 0), optionFor(n, 1)]
      let strip = renderCompactChoiceRow[MockRenderer, MockNode](
        MockRenderer(), "", "Choices", proc(): seq[CompactChoiceOption] =
          discard refresh.val
          optionsFor(round.val), visibleLimit = 2)
      proc chip(ariaLabel: string): MockNode =
        proc walk(node: MockNode): MockNode =
          if node.attributes.getOrDefault("aria-label") == ariaLabel: return node
          for child in node.children:
            let found = walk(child)
            if found != nil: return found
        walk(strip.root)
      for n in 0 .. 2:
        let option = chip("Option " & $(n mod 2))
        check option != nil
        refresh.val = refresh.val + 1
        check chip("Option " & $(n mod 2)) == option
        option.fireEvent("click")
        check round.val == n + 1
        check log.len == n + 1
        check log[^1] == "round " & $n & " option " & $(n mod 2)
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
