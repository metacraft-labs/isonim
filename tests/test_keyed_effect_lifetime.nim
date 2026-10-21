## The shipped in-memory renderer isolates reactive ownership; real nginx /
## Chromium hydration tests separately cover DOM and pre-hydration replay.
## No scheduling/time mocks: actual signals, roots and render effects execute.
import std/[unittest, tables, sequtils]
import isonim/core/[owner, signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

suite "keyed row ownership":
  test "retained rows keep effects and removed rows dispose exactly once":
    let r = MockRenderer()
    let items = createSignal(@[1, 2, 3])
    let state = createSignal(0)
    var cleanups: seq[int]
    var renders = 0
    var parent: MockNode
    var disposeRoot: proc()
    createRoot do(dispose: proc()):
      disposeRoot = dispose
      parent = r.createElement("ul")
      forEachKeyed(r, parent, proc(): seq[int] = items.val,
        proc(item: proc(): int; index: proc(): int): MockNode =
          let id = item()
          onCleanup(proc() = cleanups.add(id))
          createRenderEffect proc() =
            discard state.val
            inc renders
          ui(r):
            button(class = $state.val): text $item())
    check parent.children.len == 3
    let first = parent.children[0]
    let second = parent.children[1]
    items.val = @[3, 2, 1]
    check parent.children[2] == first
    check parent.children[1] == second
    check cleanups.len == 0
    state.val = 1
    check renders == 6
    for child in parent.children:
      check child.attributes["class"] == "1"
    items.val = @[3, 1]
    check cleanups == @[2]
    state.val = 2
    check renders == 8
    check first.attributes["class"] == "2"
    check second.attributes["class"] == "1"
    items.val = @[2, 3, 1]
    check parent.children[0] != second
    check parent.children[0].attributes["class"] == "2"
    disposeRoot()
    check cleanups.len == 4
    check cleanups.count(1) == 1
    check cleanups.count(2) == 2
    check cleanups.count(3) == 1
    let stopped = renders
    state.val = 3
    check renders == stopped

  test "failed constructors dispose every new row and retain existing rows":
    let r = MockRenderer()
    let items = createSignal(@[1])
    let state = createSignal(0)
    var cleanups: seq[int]
    var parent: MockNode
    var disposeRoot: proc()
    createRoot do(dispose: proc()):
      disposeRoot = dispose
      parent = r.createElement("ul")
      forEachKeyed(r, parent, proc(): seq[int] = items.val,
        proc(item: proc(): int; index: proc(): int): MockNode =
          let id = item()
          onCleanup(proc() = cleanups.add(id))
          if id == 2: raise newException(ValueError, "intentional constructor failure")
          ui(r):
            button(class = $state.val): text $item())
    let retained = parent.children[0]
    expect ValueError:
      items.val = @[1, 3, 2]
    check cleanups == @[3, 2]
    check parent.children.len == 1
    check parent.children[0] == retained
    state.val = 1
    check retained.attributes["class"] == "1"
    items.val = @[1]
    disposeRoot()
    check cleanups == @[3, 2, 1]
